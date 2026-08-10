import {
  AES_KEY_BYTES,
  TOKEN_BYTES,
  WRAP_NONCE_BYTES,
} from "./constants";

const encoder = new TextEncoder();

export class SecretConfigurationError extends Error {
  constructor() {
    super("A required Worker secret is missing or malformed.");
    this.name = "SecretConfigurationError";
  }
}

export function encodeBase64URL(bytes: ArrayBuffer | ArrayBufferView): string {
  const view = bytes instanceof ArrayBuffer
    ? new Uint8Array(bytes)
    : new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let binary = "";
  for (let index = 0; index < view.length; index += 1) {
    binary += String.fromCharCode(view[index] ?? 0);
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

/** Strict, canonical, unpadded RFC 4648 base64url decoder. */
export function decodeBase64URL(value: string, minBytes: number, maxBytes = minBytes): Uint8Array<ArrayBuffer> | null {
  if (!/^[A-Za-z0-9_-]+$/u.test(value)) return null;
  const padded = value.replaceAll("-", "+").replaceAll("_", "/")
    + "=".repeat((4 - (value.length % 4)) % 4);
  try {
    const binary = atob(padded);
    if (binary.length < minBytes || binary.length > maxBytes) return null;
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return encodeBase64URL(bytes) === value ? bytes : null;
  } catch {
    return null;
  }
}

export function randomToken(byteCount = TOKEN_BYTES): string {
  const bytes = new Uint8Array(byteCount);
  crypto.getRandomValues(bytes);
  return encodeBase64URL(bytes);
}

/** Rejection sampling avoids modulo bias in the six-digit human code. */
export function randomSessionID(): string {
  const range = 1_000_000;
  const ceiling = Math.floor(0x1_0000_0000 / range) * range;
  const random = new Uint32Array(1);
  do {
    crypto.getRandomValues(random);
  } while ((random[0] ?? ceiling) >= ceiling);
  return String((random[0] ?? 0) % range).padStart(6, "0");
}

function decodeConfiguredSecret(value: string): Uint8Array<ArrayBuffer> {
  const secret = decodeBase64URL(value, 32, 32);
  if (!secret) throw new SecretConfigurationError();
  return secret;
}

async function importHMACSecret(value: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    decodeConfiguredSecret(value),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

/** Domain separation lets one verifier secret safely serve independent namespaces. */
export async function hmacVerifier(secret: string, domain: string, value: string): Promise<string> {
  const key = await importHMACSecret(secret);
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(`${domain}\u0000${value}`));
  return encodeBase64URL(signature);
}

async function importWrappingKey(secret: string, usage: Array<"encrypt" | "decrypt">): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    decodeConfiguredSecret(secret),
    { name: "AES-GCM" },
    false,
    usage,
  );
}

function keyWrapAAD(shareID: string): Uint8Array<ArrayBuffer> {
  return new Uint8Array(encoder.encode(`dragaway.share.keywrap.v2\u0000${shareID}`));
}

/** Encrypts a code-only content key before it is persisted in D1. */
export async function wrapContentKey(
  secret: string,
  shareID: string,
  contentKey: Uint8Array<ArrayBuffer>,
): Promise<{ wrappedKey: string; nonce: string }> {
  if (contentKey.byteLength !== AES_KEY_BYTES) throw new Error("Invalid content key length.");
  const wrappingKey = await importWrappingKey(secret, ["encrypt"]);
  const nonce = new Uint8Array(WRAP_NONCE_BYTES);
  crypto.getRandomValues(nonce);
  const wrapped = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce, additionalData: keyWrapAAD(shareID), tagLength: 128 },
    wrappingKey,
    contentKey,
  );
  return { wrappedKey: encodeBase64URL(wrapped), nonce: encodeBase64URL(nonce) };
}

/** Decrypts and authenticates the code-only key only after a valid session claim. */
export async function unwrapContentKey(
  secret: string,
  shareID: string,
  wrappedKey: string,
  encodedNonce: string,
): Promise<string> {
  const wrapped = decodeBase64URL(wrappedKey, AES_KEY_BYTES + 16, AES_KEY_BYTES + 16);
  const nonce = decodeBase64URL(encodedNonce, WRAP_NONCE_BYTES, WRAP_NONCE_BYTES);
  if (!wrapped || !nonce) throw new Error("Malformed wrapped key.");
  const wrappingKey = await importWrappingKey(secret, ["decrypt"]);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: nonce, additionalData: keyWrapAAD(shareID), tagLength: 128 },
    wrappingKey,
    wrapped,
  );
  if (plaintext.byteLength !== AES_KEY_BYTES) throw new Error("Malformed unwrapped key.");
  return encodeBase64URL(plaintext);
}

import {
  AES_KEY_BYTES,
  CIPHER,
  MAX_CLAIM_JSON_BYTES,
  MAX_KDF_SALT_BYTES,
  MAX_PAYLOAD_BYTES,
  MAX_PBKDF2_ITERATIONS,
  MIN_KDF_SALT_BYTES,
  MIN_PBKDF2_ITERATIONS,
  NO_KDF,
  PASSWORD_KDF,
  PROTOCOL_VERSION,
  SHARE_ID_BYTES,
  TOKEN_BYTES,
  isSupportedBundleVersion,
  type CreateMetadata,
} from "./constants";
import { decodeBase64URL } from "./crypto";

const SECURITY_HEADERS: Readonly<Record<string, string>> = {
  "Cache-Control": "no-store, max-age=0",
  Pragma: "no-cache",
  "X-Content-Type-Options": "nosniff",
};

export class HTTPError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly retryAfter?: number,
  ) {
    super(message);
    this.name = "HTTPError";
  }
}

export function jsonResponse(body: unknown, status = 200, extraHeaders?: HeadersInit): Response {
  const headers = new Headers(SECURITY_HEADERS);
  headers.set("Content-Type", "application/json; charset=utf-8");
  if (extraHeaders) {
    new Headers(extraHeaders).forEach((value, key) => headers.set(key, value));
  }
  return new Response(JSON.stringify(body), { status, headers });
}

export function emptyResponse(status: number): Response {
  return new Response(null, { status, headers: SECURITY_HEADERS });
}

export function errorResponse(error: HTTPError): Response {
  const headers = error.retryAfter === undefined
    ? undefined
    : { "Retry-After": String(Math.max(1, Math.ceil(error.retryAfter))) };
  return jsonResponse({ error: { code: error.code, message: error.message } }, error.status, headers);
}

export function unavailable(): HTTPError {
  return new HTTPError(404, "share_unavailable", "Session unavailable.");
}

function requiredHeader(request: Request, name: string): string {
  const value = request.headers.get(name);
  if (value === null || value.length === 0) {
    throw new HTTPError(400, "invalid_request", `Missing ${name} header.`);
  }
  if (value.length > 128 || /[\u0000-\u001F\u007F]/u.test(value)) {
    throw new HTTPError(400, "invalid_request", `Invalid ${name} header.`);
  }
  return value;
}

function parseIntegerHeader(request: Request, name: string): number {
  const raw = requiredHeader(request, name);
  if (!/^(0|[1-9]\d*)$/u.test(raw)) {
    throw new HTTPError(400, "invalid_request", `Invalid ${name} header.`);
  }
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed)) {
    throw new HTTPError(400, "invalid_request", `Invalid ${name} header.`);
  }
  return parsed;
}

function requireMediaType(request: Request, expected: string): void {
  const raw = request.headers.get("Content-Type") ?? "";
  const mediaType = raw.split(";", 1)[0]?.trim().toLowerCase();
  if (mediaType !== expected) {
    throw new HTTPError(415, "unsupported_media_type", `Content-Type must be ${expected}.`);
  }
}

function rejectContentEncoding(request: Request): void {
  const encoding = request.headers.get("Content-Encoding");
  if (encoding !== null && encoding.toLowerCase() !== "identity") {
    throw new HTTPError(415, "unsupported_content_encoding", "Compressed request bodies are not accepted.");
  }
}

function requiredContentLength(request: Request, maximum: number): number {
  const raw = request.headers.get("Content-Length");
  if (raw === null) {
    throw new HTTPError(411, "length_required", "Content-Length is required.");
  }
  if (!/^[1-9]\d*$/u.test(raw)) {
    throw new HTTPError(400, "invalid_content_length", "Content-Length is invalid.");
  }
  const length = Number(raw);
  if (!Number.isSafeInteger(length)) {
    throw new HTTPError(400, "invalid_content_length", "Content-Length is invalid.");
  }
  if (length > maximum) {
    throw new HTTPError(413, "payload_too_large", "Encrypted session payload is too large.");
  }
  return length;
}

export function parseCreateMetadata(request: Request): CreateMetadata {
  requireMediaType(request, "application/octet-stream");
  rejectContentEncoding(request);
  const payloadSize = requiredContentLength(request, MAX_PAYLOAD_BYTES);
  if (request.body === null) {
    throw new HTTPError(400, "invalid_request", "Encrypted session payload is missing.");
  }

  const shareID = requiredHeader(request, "X-Dragaway-Share-ID");
  const ownerToken = requiredHeader(request, "X-Dragaway-Owner-Token");
  if (
    !decodeBase64URL(shareID, SHARE_ID_BYTES, SHARE_ID_BYTES)
    || !decodeBase64URL(ownerToken, TOKEN_BYTES, TOKEN_BYTES)
  ) {
    throw new HTTPError(400, "invalid_share_credentials", "Invalid share credentials.");
  }

  const tier = requiredHeader(request, "X-Dragaway-Tier");
  if (tier !== "codeOnly" && tier !== "password") {
    throw new HTTPError(400, "invalid_crypto", "Unsupported sharing tier.");
  }
  const cryptoVersion = parseIntegerHeader(request, "X-Dragaway-Crypto-Version");
  const bundleVersion = parseIntegerHeader(request, "X-Dragaway-Bundle-Version");
  const cipher = requiredHeader(request, "X-Dragaway-Cipher");
  if (cryptoVersion !== PROTOCOL_VERSION
      || !isSupportedBundleVersion(bundleVersion)
      || cipher !== CIPHER) {
    throw new HTTPError(400, "invalid_crypto", "Unsupported encryption descriptor.");
  }

  if (tier === "codeOnly") {
    if (request.headers.has("X-Dragaway-Kdf-Salt") || request.headers.has("X-Dragaway-Kdf-Iterations")) {
      throw new HTTPError(400, "invalid_crypto", "Code-only shares cannot include password KDF parameters.");
    }
    const kdf = requiredHeader(request, "X-Dragaway-Kdf");
    const uploadKey = decodeBase64URL(requiredHeader(request, "X-Dragaway-Key"), AES_KEY_BYTES, AES_KEY_BYTES);
    if (kdf !== NO_KDF || !uploadKey) {
      throw new HTTPError(400, "invalid_crypto", "Invalid code-only key material.");
    }
    return {
      shareID,
      ownerToken,
      tier,
      payloadSize,
      uploadKey,
      crypto: {
        crypto_version: PROTOCOL_VERSION,
        bundle_version: bundleVersion,
        cipher: CIPHER,
        kdf: NO_KDF,
        kdf_iterations: 0,
        kdf_salt: null,
      },
    };
  }

  if (request.headers.has("X-Dragaway-Key")) {
    throw new HTTPError(400, "invalid_crypto", "Password shares cannot upload a content key.");
  }
  const kdf = requiredHeader(request, "X-Dragaway-Kdf");
  const kdfIterations = parseIntegerHeader(request, "X-Dragaway-Kdf-Iterations");
  const encodedSalt = requiredHeader(request, "X-Dragaway-Kdf-Salt");
  const salt = decodeBase64URL(encodedSalt, MIN_KDF_SALT_BYTES, MAX_KDF_SALT_BYTES);
  if (
    kdf !== PASSWORD_KDF
    || !salt
    || kdfIterations < MIN_PBKDF2_ITERATIONS
    || kdfIterations > MAX_PBKDF2_ITERATIONS
  ) {
    throw new HTTPError(400, "invalid_crypto", "Invalid password KDF parameters.");
  }
  return {
    shareID,
    ownerToken,
    tier,
    payloadSize,
    uploadKey: null,
    crypto: {
      crypto_version: PROTOCOL_VERSION,
      bundle_version: bundleVersion,
      cipher: CIPHER,
      kdf: PASSWORD_KDF,
      kdf_iterations: kdfIterations,
      kdf_salt: encodedSalt,
    },
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function parseClaimSessionID(request: Request): Promise<string> {
  requireMediaType(request, "application/json");
  rejectContentEncoding(request);
  requiredContentLength(request, MAX_CLAIM_JSON_BYTES);
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    throw new HTTPError(400, "invalid_request", "Request body is not valid JSON.");
  }
  if (!isRecord(body) || Object.keys(body).length !== 1 || !/^\d{6}$/u.test(String(body.session_id ?? ""))) {
    throw new HTTPError(400, "invalid_session_id", "Session ID must contain exactly six digits.");
  }
  return String(body.session_id);
}

export function parseBearerToken(request: Request): string {
  const authorization = request.headers.get("Authorization") ?? "";
  const match = /^Bearer ([A-Za-z0-9_-]{43})$/u.exec(authorization);
  if (!match?.[1] || !decodeBase64URL(match[1], 32, 32)) throw unavailable();
  return match[1];
}

export function routeTemplate(pathname: string): string {
  if (pathname === "/v2/shares") return "create";
  if (pathname === "/v2/claims") return "claim";
  if (/^\/v2\/shares\/[A-Za-z0-9_-]{22}\/payload$/u.test(pathname)) return "payload";
  if (/^\/v2\/shares\/[A-Za-z0-9_-]{22}$/u.test(pathname)) return "revoke";
  if (pathname === "/healthz") return "health";
  if (pathname === "/v1" || pathname.startsWith("/v1/")) return "v1_retired";
  return "not_found";
}

export function structuredLog(event: string, fields: Readonly<Record<string, string | number | boolean>>): void {
  console.log(JSON.stringify({ event, ...fields }));
}

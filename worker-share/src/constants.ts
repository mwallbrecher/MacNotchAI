/** Wire- and storage-level constants for crypto protocol v2 and bundle formats v2/v3. */
export const PROTOCOL_VERSION = 2;
export const LEGACY_BUNDLE_VERSION = 2;
export const MULTI_FILE_BUNDLE_VERSION = 3;
export const BUNDLE_VERSION = MULTI_FILE_BUNDLE_VERSION;
export const SUPPORTED_BUNDLE_VERSIONS = [LEGACY_BUNDLE_VERSION, MULTI_FILE_BUNDLE_VERSION] as const;
export const CIPHER = "aes-256-gcm-combined";
export const PASSWORD_KDF = "pbkdf2-hmac-sha256";
export const NO_KDF = "none";

export const SHARE_TTL_SECONDS = 24 * 60 * 60;
export const CLAIM_TTL_SECONDS = 10 * 60;
export const CLAIM_FETCH_RETRY_LIMIT = 3;

/**
 * The app admits 25 MiB of aggregate source-file bytes plus at most 2 MiB of metadata.
 * 28 MiB leaves room for the versioned bundle framing and AES-GCM nonce/tag while
 * remaining well below Cloudflare's smallest inbound request limit.
 */
export const MAX_PAYLOAD_BYTES = 28 * 1024 * 1024;
export const MAX_CLAIM_JSON_BYTES = 128;

export const MIN_PBKDF2_ITERATIONS = 100_000;
export const MAX_PBKDF2_ITERATIONS = 2_000_000;
export const MIN_KDF_SALT_BYTES = 16;
export const MAX_KDF_SALT_BYTES = 32;

export const SHARE_ID_BYTES = 16;
export const TOKEN_BYTES = 32;
export const AES_KEY_BYTES = 32;
export const WRAP_NONCE_BYTES = 12;

export const R2_PREFIX = "v2/payloads/";

export type ShareTier = "codeOnly" | "password";
export type KdfName = typeof NO_KDF | typeof PASSWORD_KDF;

export function isSupportedBundleVersion(version: number): boolean {
  return SUPPORTED_BUNDLE_VERSIONS.some((supported) => supported === version);
}

export interface CryptoDescriptor {
  crypto_version: typeof PROTOCOL_VERSION;
  bundle_version: number;
  cipher: typeof CIPHER;
  kdf: KdfName;
  kdf_iterations: number;
  kdf_salt: string | null;
}

export interface CreateMetadata {
  shareID: string;
  ownerToken: string;
  tier: ShareTier;
  crypto: CryptoDescriptor;
  uploadKey: Uint8Array<ArrayBuffer> | null;
  payloadSize: number;
}

export interface ShareRow {
  share_id: string;
  tier: ShareTier;
  state: "uploading" | "ready" | "revoking";
  r2_key: string;
  payload_size: number;
  crypto_version: number;
  bundle_version: number;
  cipher: string;
  kdf: string;
  kdf_iterations: number;
  kdf_salt: string | null;
  wrapped_key: string | null;
  wrapped_key_nonce: string | null;
  expires_at: number;
}

export interface CleanupRow {
  share_id: string;
  r2_key: string;
}

import {
  AES_KEY_BYTES,
  CIPHER,
  MAX_KDF_SALT_BYTES,
  MAX_PAYLOAD_BYTES,
  MAX_PBKDF2_ITERATIONS,
  MIN_KDF_SALT_BYTES,
  MIN_PBKDF2_ITERATIONS,
  NO_KDF,
  PASSWORD_KDF,
  PROTOCOL_VERSION,
  R2_PREFIX,
  SHARE_TTL_SECONDS,
  WRAP_NONCE_BYTES,
  isSupportedBundleVersion,
  type CleanupRow,
  type CreateMetadata,
  type ShareRow,
} from "./constants";
import {
  decodeBase64URL,
  hmacVerifier,
  randomSessionID,
  randomToken,
  wrapContentKey,
} from "./crypto";

interface D1ChangeResult {
  meta: { changes?: number };
}

// Ten atomic claim/delete pairs plus five two-statement auxiliary batches use
// at most 30 D1 queries, safely below the Free-plan limit of 50 per invocation.
// One hundred IDs is D1's bound-parameter ceiling and cleans up to 1,000 shares
// per hourly sweep. ON DELETE CASCADE removes their claim rows set-wise.
const CLEANUP_BATCH_SIZE = 100;
const CLEANUP_MAX_BATCHES = 10;
const AUXILIARY_CLEANUP_BATCH_SIZE = 1_000;
const AUXILIARY_CLEANUP_MAX_BATCHES = 5;

export interface ReservedShare {
  sessionID: string;
  shareID: string;
  r2Key: string;
  expiresAt: number;
}

/** A caller-generated share ID or owner capability is already reserved. */
export class ShareCredentialConflictError extends Error {
  constructor() {
    super("Caller-generated share credentials conflict with an existing share.");
    this.name = "ShareCredentialConflictError";
  }
}

export interface BudgetResult {
  allowed: boolean;
  retryAfter: number;
}

export async function ipVerifier(request: Request, env: Env): Promise<string> {
  const connectingIP = request.headers.get("CF-Connecting-IP") ?? "local-development";
  return hmacVerifier(env.VERIFIER_HMAC_SECRET, "abuse-ip", connectingIP);
}

/**
 * Exact, globally consistent fixed-window budget. The single UPSERT is atomic in D1;
 * Cloudflare's faster RateLimit binding is deliberately only the burst pre-filter.
 */
export async function consumeExactBudget(
  env: Env,
  subjectVerifier: string,
  operation: string,
  limit: number,
  windowSeconds: number,
  now: number,
): Promise<BudgetResult> {
  const windowStart = Math.floor(now / windowSeconds) * windowSeconds;
  const expiresAt = windowStart + windowSeconds * 2;
  const result = await env.DB.prepare(
    `INSERT INTO abuse_budget_v2
       (subject_verifier, operation, window_start, count, expires_at)
     VALUES (?, ?, ?, 1, ?)
     ON CONFLICT(subject_verifier, operation, window_start) DO UPDATE SET
       count = abuse_budget_v2.count + 1,
       expires_at = excluded.expires_at
     WHERE abuse_budget_v2.count < ?
     RETURNING count`,
  ).bind(subjectVerifier, operation, windowStart, expiresAt, limit).run<{ count: number }>();
  return {
    allowed: result.results.length === 1,
    retryAfter: Math.max(1, windowStart + windowSeconds - now),
  };
}

/** Atomically reserves a server-generated human code for caller-generated capabilities. */
export async function reserveShare(env: Env, metadata: CreateMetadata, now: number): Promise<ReservedShare> {
  const shareID = metadata.shareID;
  const ownerVerifier = await hmacVerifier(env.VERIFIER_HMAC_SECRET, "owner-token", metadata.ownerToken);
  const r2Key = `${R2_PREFIX}${shareID}.bin`;
  const expiresAt = now + SHARE_TTL_SECONDS;
  let wrappedKey: string | null = null;
  let wrappedKeyNonce: string | null = null;
  if (metadata.tier === "codeOnly" && metadata.uploadKey) {
    const wrapped = await wrapContentKey(env.KEY_WRAP_SECRET, shareID, metadata.uploadKey);
    wrappedKey = wrapped.wrappedKey;
    wrappedKeyNonce = wrapped.nonce;
  }

  for (let attempt = 0; attempt < 24; attempt += 1) {
    const sessionID = randomSessionID();
    const sessionVerifier = await hmacVerifier(env.VERIFIER_HMAC_SECRET, "session-id", sessionID);

    const result = await env.DB.prepare(
      `INSERT OR IGNORE INTO share_v2
       (share_id, session_verifier, owner_token_verifier, tier, state, r2_key,
        payload_size, crypto_version, bundle_version, cipher, kdf, kdf_iterations,
        kdf_salt, wrapped_key, wrapped_key_nonce, created_at, expires_at)
       VALUES (?, ?, ?, ?, 'uploading', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(
      shareID,
      sessionVerifier,
      ownerVerifier,
      metadata.tier,
      r2Key,
      metadata.payloadSize,
      metadata.crypto.crypto_version,
      metadata.crypto.bundle_version,
      metadata.crypto.cipher,
      metadata.crypto.kdf,
      metadata.crypto.kdf_iterations,
      metadata.crypto.kdf_salt,
      wrappedKey,
      wrappedKeyNonce,
      now,
      expiresAt,
    ).run() as D1ChangeResult;
    if (result.meta.changes === 1) {
      return { sessionID, shareID, r2Key, expiresAt };
    }

    // INSERT OR IGNORE also absorbs the intentionally retriable six-digit
    // collision. Check only the caller-owned identifiers before drawing a
    // generic conflict conclusion; the unique constraints remain the atomic
    // authority if concurrent creates race.
    const suppliedCredentialConflict = await env.DB.prepare(
      `SELECT 1 AS found FROM share_v2
       WHERE share_id = ? OR owner_token_verifier = ? LIMIT 1`,
    ).bind(shareID, ownerVerifier).first<{ found: number }>();
    if (suppliedCredentialConflict) {
      throw new ShareCredentialConflictError();
    }
  }
  throw new Error("Identifier reservation exhausted.");
}

export async function markShareReady(env: Env, shareID: string, etag: string, now: number): Promise<boolean> {
  const result = await env.DB.prepare(
    `UPDATE share_v2 SET state = 'ready', payload_etag = ?
     WHERE share_id = ? AND state = 'uploading' AND expires_at > ?`,
  ).bind(etag, shareID, now).run() as D1ChangeResult;
  return result.meta.changes === 1;
}

export async function deleteMetadata(env: Env, shareID: string): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM claim_v2 WHERE share_id = ?").bind(shareID),
    env.DB.prepare("DELETE FROM share_v2 WHERE share_id = ?").bind(shareID),
  ]);
}

export async function findReadyShareBySession(env: Env, sessionID: string, now: number): Promise<ShareRow | null> {
  const verifier = await hmacVerifier(env.VERIFIER_HMAC_SECRET, "session-id", sessionID);
  return env.DB.prepare(
    `SELECT share_id, tier, state, r2_key, payload_size, crypto_version, bundle_version,
            cipher, kdf, kdf_iterations, kdf_salt, wrapped_key, wrapped_key_nonce, expires_at
     FROM share_v2
     WHERE session_verifier = ? AND state = 'ready' AND expires_at > ?`,
  ).bind(verifier, now).first<ShareRow>();
}

export async function createClaim(
  env: Env,
  share: ShareRow,
  now: number,
  claimExpiresAt: number,
): Promise<string | null> {
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const token = randomToken();
    const verifier = await hmacVerifier(env.VERIFIER_HMAC_SECRET, "claim-token", token);
    try {
      const results = await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO claim_v2 (token_verifier, share_id, fetches, created_at, expires_at)
           SELECT ?, share_id, 0, ?, ? FROM share_v2
           WHERE share_id = ? AND state = 'ready' AND expires_at > ?`,
        ).bind(verifier, now, claimExpiresAt, share.share_id, now),
        env.DB.prepare(
          `UPDATE share_v2 SET claim_count = claim_count + 1
           WHERE share_id = ? AND state = 'ready' AND expires_at > ?`,
        ).bind(share.share_id, now),
      ]);
      if (results[0]?.meta.changes === 1) return token;
      return null;
    } catch (error) {
      if (attempt === 3) throw error;
    }
  }
  return null;
}

export async function consumeClaimFetch(
  env: Env,
  shareID: string,
  claimToken: string,
  now: number,
  retryLimit: number,
): Promise<boolean> {
  const verifier = await hmacVerifier(env.VERIFIER_HMAC_SECRET, "claim-token", claimToken);
  const result = await env.DB.prepare(
    `UPDATE claim_v2 SET fetches = fetches + 1, last_used_at = ?
     WHERE token_verifier = ? AND share_id = ? AND expires_at > ? AND fetches < ?
       AND EXISTS (
         SELECT 1 FROM share_v2
         WHERE share_id = ? AND state = 'ready' AND expires_at > ?
       )
     RETURNING share_id`,
  ).bind(now, verifier, shareID, now, retryLimit, shareID, now).run<{ share_id: string }>();
  return result.results.length === 1;
}

export async function notePayloadFetch(env: Env, shareID: string): Promise<void> {
  await env.DB.prepare(
    "UPDATE share_v2 SET payload_fetch_count = payload_fetch_count + 1 WHERE share_id = ?",
  ).bind(shareID).run();
}

export async function beginOwnerRevoke(
  env: Env,
  shareID: string,
  ownerToken: string,
  now: number,
): Promise<string | null> {
  const verifier = await hmacVerifier(env.VERIFIER_HMAC_SECRET, "owner-token", ownerToken);
  const result = await env.DB.prepare(
    `UPDATE share_v2 SET state = 'revoking', revoked_at = ?
     WHERE share_id = ? AND owner_token_verifier = ? AND state IN ('uploading', 'ready')
     RETURNING r2_key`,
  ).bind(now, shareID, verifier).run<{ r2_key: string }>();
  return result.results[0]?.r2_key ?? null;
}

export function isValidStoredDescriptor(share: ShareRow): boolean {
  if (
    share.crypto_version !== PROTOCOL_VERSION
    || !isSupportedBundleVersion(share.bundle_version)
    || share.cipher !== CIPHER
    || share.payload_size < 1
    || share.payload_size > MAX_PAYLOAD_BYTES
  ) return false;
  if (share.tier === "codeOnly") {
    return share.kdf === NO_KDF
      && share.kdf_iterations === 0
      && share.kdf_salt === null
      && share.wrapped_key !== null
      && decodeBase64URL(share.wrapped_key, AES_KEY_BYTES + 16, AES_KEY_BYTES + 16) !== null
      && share.wrapped_key_nonce !== null
      && decodeBase64URL(share.wrapped_key_nonce, WRAP_NONCE_BYTES, WRAP_NONCE_BYTES) !== null;
  }
  return share.tier === "password"
    && share.kdf === PASSWORD_KDF
    && share.kdf_iterations >= MIN_PBKDF2_ITERATIONS
    && share.kdf_iterations <= MAX_PBKDF2_ITERATIONS
    && share.kdf_salt !== null
    && decodeBase64URL(share.kdf_salt, MIN_KDF_SALT_BYTES, MAX_KDF_SALT_BYTES) !== null
    && share.wrapped_key === null
    && share.wrapped_key_nonce === null;
}

export async function cleanupExpiredShares(env: Env, now: number): Promise<number> {
  let cleaned = 0;
  for (let batch = 0; batch < CLEANUP_MAX_BATCHES; batch += 1) {
    // Claim eligible rows atomically before touching R2. This closes the old
    // SELECT/delete race with markShareReady(): whichever D1 update wins makes
    // the other transition ineligible, and an R2 failure remains retryable.
    const claimed = await env.DB.prepare(
      `UPDATE share_v2
       SET state = 'revoking', revoked_at = COALESCE(revoked_at, ?)
       WHERE share_id IN (
         SELECT share_id FROM share_v2
         WHERE state = 'revoking'
            OR expires_at <= ?
            OR (state = 'uploading' AND created_at <= ?)
         ORDER BY CASE state WHEN 'revoking' THEN 0 WHEN 'uploading' THEN 1 ELSE 2 END,
                  expires_at, share_id
         LIMIT ?
       )
       RETURNING share_id, r2_key`,
    ).bind(now, now, now - 15 * 60, CLEANUP_BATCH_SIZE).run<CleanupRow>();
    if (claimed.results.length === 0) break;
    await env.PAYLOADS.delete(claimed.results.map((row) => row.r2_key));
    const shareIDs = claimed.results.map((row) => row.share_id);
    const placeholders = shareIDs.map(() => "?").join(", ");
    const deleted = await env.DB.prepare(
      `DELETE FROM share_v2 WHERE state = 'revoking' AND share_id IN (${placeholders})`,
    ).bind(...shareIDs).run() as D1ChangeResult;
    cleaned += deleted.meta.changes ?? 0;
    if (claimed.results.length < CLEANUP_BATCH_SIZE) break;
  }

  for (let batch = 0; batch < AUXILIARY_CLEANUP_MAX_BATCHES; batch += 1) {
    const results = await env.DB.batch([
      env.DB.prepare(
        `DELETE FROM claim_v2 WHERE token_verifier IN (
           SELECT token_verifier FROM claim_v2
           WHERE expires_at <= ? ORDER BY expires_at LIMIT ?
         )`,
      ).bind(now, AUXILIARY_CLEANUP_BATCH_SIZE),
      env.DB.prepare(
        `DELETE FROM abuse_budget_v2 WHERE rowid IN (
           SELECT rowid FROM abuse_budget_v2
           WHERE expires_at <= ? ORDER BY expires_at LIMIT ?
         )`,
      ).bind(now, AUXILIARY_CLEANUP_BATCH_SIZE),
    ]) as D1ChangeResult[];
    const claimsDeleted = results[0]?.meta.changes ?? 0;
    const budgetsDeleted = results[1]?.meta.changes ?? 0;
    if (
      claimsDeleted < AUXILIARY_CLEANUP_BATCH_SIZE
      && budgetsDeleted < AUXILIARY_CLEANUP_BATCH_SIZE
    ) break;
  }
  return cleaned;
}

import {
  CLAIM_FETCH_RETRY_LIMIT,
  CLAIM_TTL_SECONDS,
  CIPHER,
  NO_KDF,
  PASSWORD_KDF,
  PROTOCOL_VERSION,
  R2_PREFIX,
  type CryptoDescriptor,
  type ShareRow,
} from "./constants";
import { unwrapContentKey } from "./crypto";
import {
  beginOwnerRevoke,
  cleanupExpiredShares,
  consumeClaimFetch,
  consumeExactBudget,
  createClaim,
  deleteMetadata,
  findReadyShareBySession,
  ipVerifier,
  isValidStoredDescriptor,
  markShareReady,
  notePayloadFetch,
  reserveShare,
  ShareCredentialConflictError,
  type ReservedShare,
} from "./database";
import {
  HTTPError,
  emptyResponse,
  errorResponse,
  jsonResponse,
  parseBearerToken,
  parseClaimSessionID,
  parseCreateMetadata,
  routeTemplate,
  structuredLog,
  unavailable,
} from "./http";

const EXACT_LIMITS = {
  create: { count: 50, window: 60 * 60 },
  claim: { count: 30, window: 60 * 60 },
  payload: { count: 180, window: 60 * 60 },
  revoke: { count: 30, window: 60 * 60 },
} as const;

type RateBindingName = "CREATE_BURST" | "CLAIM_BURST" | "PAYLOAD_BURST" | "OWNER_BURST";

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

async function enforceRateLimit(
  request: Request,
  env: Env,
  bindingName: RateBindingName,
  operation: keyof typeof EXACT_LIMITS,
): Promise<void> {
  const subject = await ipVerifier(request, env);
  const burst = await env[bindingName].limit({ key: subject });
  if (!burst.success) {
    throw new HTTPError(429, "rate_limited", "Too many requests. Try again later.", 60);
  }
  const limit = EXACT_LIMITS[operation];
  const exact = await consumeExactBudget(env, subject, operation, limit.count, limit.window, nowSeconds());
  if (!exact.allowed) {
    throw new HTTPError(429, "rate_limited", "Too many requests. Try again later.", exact.retryAfter);
  }
}

async function createShare(request: Request, env: Env): Promise<Response> {
  await enforceRateLimit(request, env, "CREATE_BURST", "create");
  const metadata = parseCreateMetadata(request);
  const now = nowSeconds();
  let reserved: ReservedShare;
  try {
    reserved = await reserveShare(env, metadata, now);
  } catch (error) {
    if (error instanceof ShareCredentialConflictError) {
      throw new HTTPError(409, "share_conflict", "Share credentials conflict. Generate new credentials and retry.");
    }
    throw error;
  }
  let uploadedObject = false;
  try {
    const object = await env.PAYLOADS.put(reserved.r2Key, request.body, {
      onlyIf: { etagDoesNotMatch: "*" },
      httpMetadata: { contentType: "application/octet-stream", cacheControl: "no-store" },
    });
    if (!object) {
      throw new HTTPError(409, "share_conflict", "Share credentials conflict. Generate new credentials and retry.");
    }
    uploadedObject = true;
    if (object.size !== metadata.payloadSize) {
      throw new HTTPError(400, "payload_length_mismatch", "Encrypted payload length did not match Content-Length.");
    }
    if (!await markShareReady(env, reserved.shareID, object.etag, nowSeconds())) {
      throw new Error("Reserved share could not transition to ready.");
    }
    return jsonResponse({
      session_id: reserved.sessionID,
      share_id: reserved.shareID,
      expires_at: reserved.expiresAt,
    }, 201);
  } catch (error) {
    try {
      // A failed conditional put can mean an older object already owns this
      // caller-provided key. Never delete an object unless this request received
      // the successful put result and therefore knows it created the object;
      // the conditional write never replaces an existing object.
      if (uploadedObject) await env.PAYLOADS.delete(reserved.r2Key);
      await deleteMetadata(env, reserved.shareID);
    } catch {
      structuredLog("share_cleanup_deferred", { route: "create" });
    }
    throw error;
  }
}

function cryptoDescriptor(share: ShareRow): CryptoDescriptor {
  return {
    crypto_version: PROTOCOL_VERSION,
    bundle_version: share.bundle_version,
    cipher: CIPHER,
    kdf: share.kdf === NO_KDF ? NO_KDF : PASSWORD_KDF,
    kdf_iterations: share.kdf_iterations,
    kdf_salt: share.kdf_salt,
  };
}

async function claimShare(request: Request, env: Env): Promise<Response> {
  await enforceRateLimit(request, env, "CLAIM_BURST", "claim");
  const sessionID = await parseClaimSessionID(request);
  const now = nowSeconds();
  const share = await findReadyShareBySession(env, sessionID, now);
  if (!share || !isValidStoredDescriptor(share)) throw unavailable();

  // Authenticate/unwrap stored metadata before minting a recipient capability. A
  // misconfigured wrapping secret must not leave unusable claim rows behind.
  let releasedKey: string | undefined;
  if (share.tier === "codeOnly") {
    if (!share.wrapped_key || !share.wrapped_key_nonce) throw unavailable();
    try {
      releasedKey = await unwrapContentKey(
        env.KEY_WRAP_SECRET,
        share.share_id,
        share.wrapped_key,
        share.wrapped_key_nonce,
      );
    } catch {
      structuredLog("key_unwrap_failed", { route: "claim" });
      throw new HTTPError(503, "share_unavailable", "Session temporarily unavailable.");
    }
  }

  const claimExpiresAt = Math.min(share.expires_at, now + CLAIM_TTL_SECONDS);
  const claimToken = await createClaim(env, share, now, claimExpiresAt);
  if (!claimToken) throw unavailable();

  const response: {
    share_id: string;
    claim_token: string;
    expires_at: number;
    claim_expires_at: number;
    tier: ShareRow["tier"];
    crypto: CryptoDescriptor;
    key?: string;
  } = {
    share_id: share.share_id,
    claim_token: claimToken,
    expires_at: share.expires_at,
    claim_expires_at: claimExpiresAt,
    tier: share.tier,
    crypto: cryptoDescriptor(share),
  };
  if (releasedKey !== undefined) response.key = releasedKey;
  return jsonResponse(response, 200);
}

async function getPayload(request: Request, env: Env, ctx: ExecutionContext, shareID: string): Promise<Response> {
  await enforceRateLimit(request, env, "PAYLOAD_BURST", "payload");
  const token = parseBearerToken(request);
  const now = nowSeconds();
  if (!await consumeClaimFetch(env, shareID, token, now, CLAIM_FETCH_RETRY_LIMIT)) throw unavailable();

  const object = await env.PAYLOADS.get(`${R2_PREFIX}${shareID}.bin`);
  if (!object) throw unavailable();
  ctx.waitUntil(notePayloadFetch(env, shareID).catch(() => {
    structuredLog("payload_counter_failed", { route: "payload", reason: "storage_error" });
  }));

  const headers = new Headers({
    "Content-Type": "application/octet-stream",
    "Content-Length": String(object.size),
    "Cache-Control": "no-store, max-age=0",
    Pragma: "no-cache",
    "X-Content-Type-Options": "nosniff",
    ETag: object.httpEtag,
  });
  return new Response(object.body, { status: 200, headers });
}

async function revokeShare(request: Request, env: Env, shareID: string): Promise<Response> {
  await enforceRateLimit(request, env, "OWNER_BURST", "revoke");
  const ownerToken = parseBearerToken(request);
  const r2Key = await beginOwnerRevoke(env, shareID, ownerToken, nowSeconds());
  if (!r2Key) throw unavailable();

  // The state transition above blocks every new claim/fetch immediately. If R2 is
  // temporarily unavailable, cron sees `revoking` and completes physical cleanup.
  await env.PAYLOADS.delete(r2Key);
  await deleteMetadata(env, shareID);
  return emptyResponse(204);
}

async function route(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const { pathname } = new URL(request.url);

  if (pathname === "/healthz" && request.method === "GET") {
    return jsonResponse({ status: "ok", protocol: "v2" });
  }
  if (pathname === "/v1" || pathname.startsWith("/v1/")) {
    return jsonResponse({
      error: { code: "upgrade_required", message: "Sharing protocol v1 is retired. Update Dragaway." },
    }, 410);
  }
  if (pathname === "/v2/shares") {
    if (request.method !== "POST") {
      return jsonResponse({ error: { code: "method_not_allowed", message: "Method not allowed." } }, 405, { Allow: "POST" });
    }
    return createShare(request, env);
  }
  if (pathname === "/v2/claims") {
    if (request.method !== "POST") {
      return jsonResponse({ error: { code: "method_not_allowed", message: "Method not allowed." } }, 405, { Allow: "POST" });
    }
    return claimShare(request, env);
  }

  const payloadMatch = /^\/v2\/shares\/([A-Za-z0-9_-]{22})\/payload$/u.exec(pathname);
  if (payloadMatch?.[1]) {
    if (request.method !== "GET") {
      return jsonResponse({ error: { code: "method_not_allowed", message: "Method not allowed." } }, 405, { Allow: "GET" });
    }
    return getPayload(request, env, ctx, payloadMatch[1]);
  }
  const shareMatch = /^\/v2\/shares\/([A-Za-z0-9_-]{22})$/u.exec(pathname);
  if (shareMatch?.[1]) {
    if (request.method !== "DELETE") {
      return jsonResponse({ error: { code: "method_not_allowed", message: "Method not allowed." } }, 405, { Allow: "DELETE" });
    }
    return revokeShare(request, env, shareMatch[1]);
  }
  return jsonResponse({ error: { code: "not_found", message: "Not found." } }, 404);
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const routeName = routeTemplate(new URL(request.url).pathname);
    try {
      const response = await route(request, env, ctx);
      if (response.status >= 400) {
        structuredLog("request_rejected", { route: routeName, status: response.status });
      }
      return response;
    } catch (error) {
      if (error instanceof HTTPError) {
        structuredLog("request_rejected", { route: routeName, status: error.status, reason: error.code });
        return errorResponse(error);
      }
      structuredLog("request_failed", { route: routeName, status: 500, reason: "internal_error" });
      return errorResponse(new HTTPError(500, "internal_error", "Internal server error."));
    }
  },

  async scheduled(_controller: ScheduledController, env: Env, _ctx: ExecutionContext): Promise<void> {
    try {
      const cleaned = await cleanupExpiredShares(env, nowSeconds());
      structuredLog("retention_sweep_completed", { cleaned });
    } catch {
      structuredLog("retention_sweep_failed", { reason: "storage_error" });
      throw new Error("Retention sweep failed.");
    }
  },
} satisfies ExportedHandler<Env>;

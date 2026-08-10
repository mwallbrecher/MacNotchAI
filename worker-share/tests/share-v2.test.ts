import { env } from "cloudflare:workers";
import {
  createExecutionContext,
  createScheduledController,
  waitOnExecutionContext,
} from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { MAX_PAYLOAD_BYTES, SHARE_ID_BYTES } from "../src/constants";
import { encodeBase64URL, randomToken } from "../src/crypto";
import { consumeExactBudget } from "../src/database";
import worker from "../src/index";

type JSONRecord = Record<string, unknown>;

let addressCounter = 10;

function nextIP(): string {
  addressCounter += 1;
  return `198.51.100.${addressCounter}`;
}

function asRecord(value: unknown): JSONRecord {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new TypeError("Expected a JSON object.");
  }
  return value as JSONRecord;
}

async function responseJSON(response: Response): Promise<JSONRecord> {
  return asRecord(await response.json());
}

async function dispatch(request: Request): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await worker.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

function bytes(seed: number, count = 128): Uint8Array<ArrayBuffer> {
  return new Uint8Array(count).fill(seed);
}

function clientShareID(): string {
  return randomToken(SHARE_ID_BYTES);
}

function commonCreateHeaders(
  payloadLength: number,
  tier: "codeOnly" | "password",
  ip = nextIP(),
  bundleVersion = 2,
): Headers {
  return new Headers({
    "Content-Type": "application/octet-stream",
    "Content-Length": String(payloadLength),
    "CF-Connecting-IP": ip,
    "X-Dragaway-Tier": tier,
    "X-Dragaway-Crypto-Version": "2",
    "X-Dragaway-Bundle-Version": String(bundleVersion),
    "X-Dragaway-Cipher": "aes-256-gcm-combined",
    "X-Dragaway-Share-ID": clientShareID(),
    "X-Dragaway-Owner-Token": randomToken(),
  });
}

async function createCodeOnly(payload = bytes(0xa5), ip = nextIP(), bundleVersion = 2): Promise<{
  payload: Uint8Array<ArrayBuffer>;
  key: string;
  sessionID: string;
  shareID: string;
  ownerToken: string;
  expiresAt: number;
}> {
  const key = encodeBase64URL(bytes(0x4d, 32));
  const headers = commonCreateHeaders(payload.byteLength, "codeOnly", ip, bundleVersion);
  const shareID = String(headers.get("X-Dragaway-Share-ID"));
  const ownerToken = String(headers.get("X-Dragaway-Owner-Token"));
  headers.set("X-Dragaway-Kdf", "none");
  headers.set("X-Dragaway-Key", key);
  const response = await dispatch(new Request("https://share.example/v2/shares", {
    method: "POST",
    headers,
    body: payload,
  }));
  expect(response.status).toBe(201);
  const json = await responseJSON(response);
  expect(json.session_id).toMatch(/^\d{6}$/u);
  expect(json.share_id).toBe(shareID);
  expect(Object.hasOwn(json, "owner_token")).toBe(false);
  expect(json.expires_at).toEqual(expect.any(Number));
  return {
    payload,
    key,
    sessionID: String(json.session_id),
    shareID,
    ownerToken,
    expiresAt: Number(json.expires_at),
  };
}

async function claim(sessionID: string, ip = nextIP()): Promise<{ response: Response; json: JSONRecord }> {
  const body = JSON.stringify({ session_id: sessionID });
  const response = await dispatch(new Request("https://share.example/v2/claims", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Content-Length": String(new TextEncoder().encode(body).byteLength),
      "CF-Connecting-IP": ip,
    },
    body,
  }));
  return { response, json: await responseJSON(response) };
}

async function payloadResponse(shareID: string, token: string, ip = nextIP()): Promise<Response> {
  return dispatch(new Request(`https://share.example/v2/shares/${shareID}/payload`, {
    headers: {
      Authorization: `Bearer ${token}`,
      "CF-Connecting-IP": ip,
    },
  }));
}

async function clearStorage(): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM claim_v2"),
    env.DB.prepare("DELETE FROM share_v2"),
    env.DB.prepare("DELETE FROM abuse_budget_v2"),
  ]);
  const objects = await env.PAYLOADS.list({ prefix: "v2/" });
  if (objects.objects.length > 0) {
    await env.PAYLOADS.delete(objects.objects.map((object) => object.key));
  }
}

beforeEach(async () => {
  await clearStorage();
});

describe("protocol surface", () => {
  it("retires v1 without CORS and applies no-store to errors", async () => {
    const response = await dispatch(new Request("https://share.example/v1/share/123456"));
    expect(response.status).toBe(410);
    expect(response.headers.get("Access-Control-Allow-Origin")).toBeNull();
    expect(response.headers.get("Cache-Control")).toContain("no-store");
    const json = await responseJSON(response);
    expect(asRecord(json.error).code).toBe("upgrade_required");
  });

  it("exposes only a non-sensitive health response", async () => {
    const response = await dispatch(new Request("https://share.example/healthz"));
    expect(response.status).toBe(200);
    expect(await responseJSON(response)).toEqual({ status: "ok", protocol: "v2" });
  });

  it("accepts the exact code-only client headers and rejects stray password KDF parameters", async () => {
    const payload = bytes(0x31, 48);
    const headers = commonCreateHeaders(payload.byteLength, "codeOnly");
    const shareID = String(headers.get("X-Dragaway-Share-ID"));
    const ownerToken = String(headers.get("X-Dragaway-Owner-Token"));
    headers.set("X-Dragaway-Kdf", "none");
    headers.set("X-Dragaway-Key", encodeBase64URL(bytes(0x32, 32)));
    expect(shareID).toMatch(/^[A-Za-z0-9_-]{22}$/u);
    expect(ownerToken).toMatch(/^[A-Za-z0-9_-]{43}$/u);
    expect(headers.has("X-Dragaway-Kdf-Iterations")).toBe(false);
    expect(headers.has("X-Dragaway-Kdf-Salt")).toBe(false);

    const accepted = await dispatch(new Request("https://share.example/v2/shares", {
      method: "POST",
      headers,
      body: payload,
    }));
    expect(accepted.status).toBe(201);
    const created = await responseJSON(accepted);
    expect(created.share_id).toBe(shareID);
    expect(Object.hasOwn(created, "owner_token")).toBe(false);

    const withIterations = commonCreateHeaders(payload.byteLength, "codeOnly");
    withIterations.set("X-Dragaway-Kdf", "none");
    withIterations.set("X-Dragaway-Key", encodeBase64URL(bytes(0x33, 32)));
    withIterations.set("X-Dragaway-Kdf-Iterations", "600000");
    const rejected = await dispatch(new Request("https://share.example/v2/shares", {
      method: "POST",
      headers: withIterations,
      body: payload,
    }));
    expect(rejected.status).toBe(400);
    expect(asRecord((await responseJSON(rejected)).error).code).toBe("invalid_crypto");
  });

  it("keeps legacy bundle v2 claimable and round-trips the new multi-file bundle v3 descriptor", async () => {
    const legacy = await createCodeOnly(bytes(0x41, 64), nextIP(), 2);
    const legacyClaim = await claim(legacy.sessionID);
    expect(legacyClaim.response.status).toBe(200);
    expect(asRecord(legacyClaim.json.crypto).bundle_version).toBe(2);

    const multi = await createCodeOnly(bytes(0x42, 64), nextIP(), 3);
    const multiClaim = await claim(multi.sessionID);
    expect(multiClaim.response.status).toBe(200);
    expect(asRecord(multiClaim.json.crypto).bundle_version).toBe(3);

    for (const unsupported of [1, 4]) {
      const headers = commonCreateHeaders(64, "codeOnly", nextIP(), unsupported);
      headers.set("X-Dragaway-Kdf", "none");
      headers.set("X-Dragaway-Key", encodeBase64URL(bytes(0x43, 32)));
      const response = await dispatch(new Request("https://share.example/v2/shares", {
        method: "POST",
        headers,
        body: bytes(0x44, 64),
      }));
      expect(response.status).toBe(400);
      expect(asRecord((await responseJSON(response)).error).code).toBe("invalid_crypto");
    }
  });

  it("rejects unbounded, oversized, encoded, and malformed crypto uploads before R2", async () => {
    const payload = bytes(1, 16);
    const missingOwner = commonCreateHeaders(payload.byteLength, "codeOnly");
    missingOwner.delete("X-Dragaway-Owner-Token");
    missingOwner.set("X-Dragaway-Kdf", "none");
    missingOwner.set("X-Dragaway-Key", encodeBase64URL(bytes(2, 32)));
    expect((await dispatch(new Request("https://share.example/v2/shares", {
      method: "POST", headers: missingOwner, body: payload,
    }))).status).toBe(400);

    const wrongOwnerLength = commonCreateHeaders(payload.byteLength, "codeOnly");
    wrongOwnerLength.set("X-Dragaway-Owner-Token", randomToken(31));
    wrongOwnerLength.set("X-Dragaway-Kdf", "none");
    wrongOwnerLength.set("X-Dragaway-Key", encodeBase64URL(bytes(2, 32)));
    expect((await dispatch(new Request("https://share.example/v2/shares", {
      method: "POST", headers: wrongOwnerLength, body: payload,
    }))).status).toBe(400);

    const nonCanonicalShareID = commonCreateHeaders(payload.byteLength, "codeOnly");
    nonCanonicalShareID.set("X-Dragaway-Share-ID", `${clientShareID()}==`);
    nonCanonicalShareID.set("X-Dragaway-Kdf", "none");
    nonCanonicalShareID.set("X-Dragaway-Key", encodeBase64URL(bytes(2, 32)));
    expect((await dispatch(new Request("https://share.example/v2/shares", {
      method: "POST", headers: nonCanonicalShareID, body: payload,
    }))).status).toBe(400);

    const noLength = commonCreateHeaders(payload.byteLength, "codeOnly");
    noLength.delete("Content-Length");
    noLength.set("X-Dragaway-Kdf", "none");
    noLength.set("X-Dragaway-Key", encodeBase64URL(bytes(2, 32)));
    expect((await dispatch(new Request("https://share.example/v2/shares", {
      method: "POST", headers: noLength, body: payload,
    }))).status).toBe(411);

    const oversized = commonCreateHeaders(MAX_PAYLOAD_BYTES + 1, "codeOnly");
    oversized.set("X-Dragaway-Kdf", "none");
    oversized.set("X-Dragaway-Key", encodeBase64URL(bytes(2, 32)));
    expect((await dispatch(new Request("https://share.example/v2/shares", {
      method: "POST", headers: oversized, body: payload,
    }))).status).toBe(413);

    const encoded = commonCreateHeaders(payload.byteLength, "codeOnly");
    encoded.set("Content-Encoding", "gzip");
    encoded.set("X-Dragaway-Kdf", "none");
    encoded.set("X-Dragaway-Key", encodeBase64URL(bytes(2, 32)));
    expect((await dispatch(new Request("https://share.example/v2/shares", {
      method: "POST", headers: encoded, body: payload,
    }))).status).toBe(415);

    const badKey = commonCreateHeaders(payload.byteLength, "codeOnly");
    badKey.set("X-Dragaway-Kdf", "none");
    badKey.set("X-Dragaway-Key", "not+base64");
    expect((await dispatch(new Request("https://share.example/v2/shares", {
      method: "POST", headers: badKey, body: payload,
    }))).status).toBe(400);

    expect((await env.PAYLOADS.list({ prefix: "v2/" })).objects).toHaveLength(0);
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM share_v2").first<{ n: number }>())?.n).toBe(0);
  });
});

describe("code-only tier", () => {
  it("stores raw ciphertext while keeping session ID, key, token and IP out of plaintext D1", async () => {
    const sourceIP = "203.0.113.77";
    const created = await createCodeOnly(bytes(0xbc, 257), sourceIP);
    const row = await env.DB.prepare("SELECT * FROM share_v2 WHERE share_id = ?")
      .bind(created.shareID).first<JSONRecord>();
    expect(row).not.toBeNull();
    const serialized = JSON.stringify(row);
    expect(serialized).not.toContain(created.sessionID);
    expect(serialized).not.toContain(created.key);
    expect(serialized).not.toContain(created.ownerToken);
    expect(serialized).not.toContain(sourceIP);
    expect(row?.wrapped_key).toEqual(expect.any(String));

    const object = await env.PAYLOADS.get(`v2/payloads/${created.shareID}.bin`);
    expect(object).not.toBeNull();
    expect(new Uint8Array(await object!.arrayBuffer())).toEqual(created.payload);

    const budgets = await env.DB.prepare("SELECT subject_verifier FROM abuse_budget_v2").all<{ subject_verifier: string }>();
    expect(budgets.results).toHaveLength(1);
    expect(budgets.results[0]?.subject_verifier).not.toContain(sourceIP);
  });

  it("never overwrites a caller capability collision and reports every collision generically", async () => {
    const original = await createCodeOnly(bytes(0x61, 96));

    async function conflictingCreate(shareID: string, ownerToken: string, seed: number): Promise<Response> {
      const payload = bytes(seed, 96);
      const headers = commonCreateHeaders(payload.byteLength, "codeOnly");
      headers.set("X-Dragaway-Share-ID", shareID);
      headers.set("X-Dragaway-Owner-Token", ownerToken);
      headers.set("X-Dragaway-Kdf", "none");
      headers.set("X-Dragaway-Key", encodeBase64URL(bytes(seed + 1, 32)));
      return dispatch(new Request("https://share.example/v2/shares", {
        method: "POST", headers, body: payload,
      }));
    }

    const shareIDCollision = await conflictingCreate(original.shareID, randomToken(), 0x62);
    const ownerTokenCollision = await conflictingCreate(clientShareID(), original.ownerToken, 0x63);
    const r2OnlyShareID = clientShareID();
    const r2Sentinel = bytes(0x64, 7);
    await env.PAYLOADS.put(`v2/payloads/${r2OnlyShareID}.bin`, r2Sentinel);
    const r2Collision = await conflictingCreate(r2OnlyShareID, randomToken(), 0x65);
    expect(shareIDCollision.status).toBe(409);
    expect(ownerTokenCollision.status).toBe(409);
    expect(r2Collision.status).toBe(409);
    expect(asRecord((await responseJSON(shareIDCollision)).error).code).toBe("share_conflict");
    expect(asRecord((await responseJSON(ownerTokenCollision)).error).code).toBe("share_conflict");
    expect(asRecord((await responseJSON(r2Collision)).error).code).toBe("share_conflict");

    const stored = await env.PAYLOADS.get(`v2/payloads/${original.shareID}.bin`);
    expect(new Uint8Array(await stored!.arrayBuffer())).toEqual(original.payload);
    const untouchedSentinel = await env.PAYLOADS.get(`v2/payloads/${r2OnlyShareID}.bin`);
    expect(new Uint8Array(await untouchedSentinel!.arrayBuffer())).toEqual(r2Sentinel);
    const count = await env.DB.prepare("SELECT COUNT(*) AS n FROM share_v2").first<{ n: number }>();
    expect(count?.n).toBe(1);
  });

  it("supports many concurrent independent recipients without a global cap", async () => {
    const created = await createCodeOnly();
    const tokens = new Set<string>();
    const recipientCount = 24;
    const results = await Promise.all(Array.from({ length: recipientCount }, (_, recipient) => (
      claim(created.sessionID, `192.0.2.${recipient + 1}`)
    )));
    for (const result of results) {
      expect(result.response.status).toBe(200);
      expect(result.json.share_id).toBe(created.shareID);
      expect(result.json.tier).toBe("codeOnly");
      expect(result.json.key).toBe(created.key);
      expect(result.json.expires_at).toBe(created.expiresAt);
      expect(Number(result.json.claim_expires_at)).toBeLessThanOrEqual(created.expiresAt);
      const descriptor = asRecord(result.json.crypto);
      expect(descriptor).toEqual({
        crypto_version: 2,
        bundle_version: 2,
        cipher: "aes-256-gcm-combined",
        kdf: "none",
        kdf_iterations: 0,
        kdf_salt: null,
      });
      tokens.add(String(result.json.claim_token));
    }
    expect(tokens.size).toBe(recipientCount);
    const row = await env.DB.prepare("SELECT claim_count FROM share_v2 WHERE share_id = ?")
      .bind(created.shareID).first<{ claim_count: number }>();
    expect(row?.claim_count).toBe(recipientCount);
  });

  it("limits each claim to three transfer attempts but allows a fresh claim", async () => {
    const created = await createCodeOnly();
    const first = await claim(created.sessionID);
    const token = String(first.json.claim_token);
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const response = await payloadResponse(created.shareID, token);
      expect(response.status).toBe(200);
      expect(new Uint8Array(await response.arrayBuffer())).toEqual(created.payload);
      expect(response.headers.get("Cache-Control")).toContain("no-store");
    }
    expect((await payloadResponse(created.shareID, token)).status).toBe(404);

    const second = await claim(created.sessionID);
    expect(second.response.status).toBe(200);
    expect(second.json.claim_token).not.toBe(token);
    expect((await payloadResponse(created.shareID, String(second.json.claim_token))).status).toBe(200);
  });

  it("atomically permits exactly three concurrent fetches for one claim token", async () => {
    const created = await createCodeOnly(bytes(0x71, 512));
    const claimed = await claim(created.sessionID);
    const token = String(claimed.json.claim_token);
    const attempts = await Promise.all(Array.from({ length: 12 }, (_, index) => (
      payloadResponse(created.shareID, token, `203.0.113.${index + 1}`)
    )));
    const successful = attempts.filter((response) => response.status === 200);
    const rejected = attempts.filter((response) => response.status === 404);
    expect(successful).toHaveLength(3);
    expect(rejected).toHaveLength(9);
    for (const response of successful) {
      expect(new Uint8Array(await response.arrayBuffer())).toEqual(created.payload);
    }

    const claimRow = await env.DB.prepare("SELECT fetches FROM claim_v2").first<{ fetches: number }>();
    expect(claimRow?.fetches).toBe(3);
    const shareRow = await env.DB.prepare("SELECT payload_fetch_count FROM share_v2 WHERE share_id = ?")
      .bind(created.shareID).first<{ payload_fetch_count: number }>();
    expect(shareRow?.payload_fetch_count).toBe(3);
  });

  it("keeps claim and revoke safe when both race", async () => {
    const created = await createCodeOnly(bytes(0x81, 256));
    const claimPromise = claim(created.sessionID, "198.18.0.1");
    const revokePromise = dispatch(new Request(`https://share.example/v2/shares/${created.shareID}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${created.ownerToken}`, "CF-Connecting-IP": "198.18.0.2" },
    }));
    const [claimed, revoked] = await Promise.all([claimPromise, revokePromise]);
    expect(revoked.status).toBe(204);
    expect([200, 404]).toContain(claimed.response.status);
    expect((await claim(created.sessionID, "198.18.0.3")).response.status).toBe(404);
    if (claimed.response.status === 200) {
      expect((await payloadResponse(
        created.shareID,
        String(claimed.json.claim_token),
        "198.18.0.4",
      )).status).toBe(404);
    }
    expect(await env.DB.prepare("SELECT share_id FROM share_v2 WHERE share_id = ?")
      .bind(created.shareID).first()).toBeNull();
    expect(await env.PAYLOADS.get(`v2/payloads/${created.shareID}.bin`)).toBeNull();
  });

  it("binds claim tokens to one share and reserves revoke for the owner token", async () => {
    const first = await createCodeOnly(bytes(1));
    const second = await createCodeOnly(bytes(2));
    const claimed = await claim(first.sessionID);
    const claimToken = String(claimed.json.claim_token);
    expect((await payloadResponse(second.shareID, claimToken)).status).toBe(404);

    const wrongDelete = await dispatch(new Request(`https://share.example/v2/shares/${first.shareID}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${claimToken}`, "CF-Connecting-IP": nextIP() },
    }));
    expect(wrongDelete.status).toBe(404);

    const deleted = await dispatch(new Request(`https://share.example/v2/shares/${first.shareID}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${first.ownerToken}`, "CF-Connecting-IP": nextIP() },
    }));
    expect(deleted.status).toBe(204);
    expect(await env.PAYLOADS.get(`v2/payloads/${first.shareID}.bin`)).toBeNull();
    expect((await claim(first.sessionID)).response.status).toBe(404);
    expect((await claim(second.sessionID)).response.status).toBe(200);
  });
});

describe("password tier", () => {
  it("returns the versioned PBKDF2 descriptor but never accepts or returns an AES key", async () => {
    const payload = bytes(0x91, 333);
    const salt = encodeBase64URL(bytes(0x27, 32));
    const headers = commonCreateHeaders(payload.byteLength, "password");
    headers.set("X-Dragaway-Kdf", "pbkdf2-hmac-sha256");
    headers.set("X-Dragaway-Kdf-Iterations", "600000");
    headers.set("X-Dragaway-Kdf-Salt", salt);
    const createResponse = await dispatch(new Request("https://share.example/v2/shares", {
      method: "POST", headers, body: payload,
    }));
    expect(createResponse.status).toBe(201);
    const created = await responseJSON(createResponse);
    expect(created.share_id).toBe(headers.get("X-Dragaway-Share-ID"));
    expect(Object.hasOwn(created, "owner_token")).toBe(false);

    const result = await claim(String(created.session_id));
    expect(result.response.status).toBe(200);
    expect(Object.hasOwn(result.json, "key")).toBe(false);
    expect(result.json.tier).toBe("password");
    expect(asRecord(result.json.crypto)).toEqual({
      crypto_version: 2,
      bundle_version: 2,
      cipher: "aes-256-gcm-combined",
      kdf: "pbkdf2-hmac-sha256",
      kdf_iterations: 600000,
      kdf_salt: salt,
    });
    const row = await env.DB.prepare("SELECT wrapped_key, wrapped_key_nonce FROM share_v2 WHERE share_id = ?")
      .bind(String(created.share_id)).first<{ wrapped_key: string | null; wrapped_key_nonce: string | null }>();
    expect(row).toEqual({ wrapped_key: null, wrapped_key_nonce: null });
  });

  it("rejects weak/out-of-range KDF metadata and any uploaded password-tier key", async () => {
    const payload = bytes(3, 32);
    const headers = commonCreateHeaders(payload.byteLength, "password");
    headers.set("X-Dragaway-Kdf", "pbkdf2-hmac-sha256");
    headers.set("X-Dragaway-Kdf-Iterations", "99999");
    headers.set("X-Dragaway-Kdf-Salt", encodeBase64URL(bytes(4, 32)));
    expect((await dispatch(new Request("https://share.example/v2/shares", {
      method: "POST", headers, body: payload,
    }))).status).toBe(400);

    headers.set("X-Dragaway-Kdf-Iterations", "600000");
    headers.set("X-Dragaway-Key", encodeBase64URL(bytes(5, 32)));
    expect((await dispatch(new Request("https://share.example/v2/shares", {
      method: "POST", headers, body: payload,
    }))).status).toBe(400);
  });
});

describe("abuse controls and retention", () => {
  it("enforces the exact D1 budget with a single atomic counter", async () => {
    const subject = "test-subject-verifier";
    const now = 1_800_000_000;
    expect((await consumeExactBudget(env, subject, "claim", 3, 3600, now)).allowed).toBe(true);
    expect((await consumeExactBudget(env, subject, "claim", 3, 3600, now + 1)).allowed).toBe(true);
    expect((await consumeExactBudget(env, subject, "claim", 3, 3600, now + 2)).allowed).toBe(true);
    const denied = await consumeExactBudget(env, subject, "claim", 3, 3600, now + 3);
    expect(denied.allowed).toBe(false);
    expect(denied.retryAfter).toBeGreaterThan(0);
    const row = await env.DB.prepare(
      "SELECT count FROM abuse_budget_v2 WHERE subject_verifier = ? AND operation = 'claim'",
    ).bind(subject).first<{ count: number }>();
    expect(row?.count).toBe(3);
  });

  it("denies an expired share immediately and cron physically removes it", async () => {
    const created = await createCodeOnly();
    const now = Math.floor(Date.now() / 1000);
    await env.DB.prepare("UPDATE share_v2 SET created_at = ?, expires_at = ? WHERE share_id = ?")
      .bind(now - 2, now - 1, created.shareID).run();
    expect((await claim(created.sessionID)).response.status).toBe(404);

    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController({
      scheduledTime: Date.now(),
      cron: "0 * * * *",
    }), env, ctx);
    await waitOnExecutionContext(ctx);
    expect(await env.PAYLOADS.get(`v2/payloads/${created.shareID}.bin`)).toBeNull();
    expect(await env.DB.prepare("SELECT share_id FROM share_v2 WHERE share_id = ?")
      .bind(created.shareID).first()).toBeNull();
  });

  it("cleans more than one hundred shares in bounded chunks while keeping live controls", async () => {
    const expiredCount = 205;
    const now = Math.floor(Date.now() / 1000);
    await env.DB.prepare(
      `WITH RECURSIVE sequence(n) AS (
         SELECT 0
         UNION ALL SELECT n + 1 FROM sequence WHERE n + 1 < ?
       )
       INSERT INTO share_v2
         (share_id, session_verifier, owner_token_verifier, tier, state, r2_key,
          payload_size, crypto_version, bundle_version, cipher, kdf, kdf_iterations,
          kdf_salt, wrapped_key, wrapped_key_nonce, created_at, expires_at)
       SELECT
         printf('cleanup-%04d', n),
         printf('cleanup-session-%04d', n),
         printf('cleanup-owner-%04d', n),
         'codeOnly', 'ready', printf('v2/payloads/cleanup-%04d.bin', n),
         1, 2, 2, 'aes-256-gcm-combined', 'none', 0,
         NULL, 'test-wrapped-key', 'test-wrapped-nonce', ?, ?
       FROM sequence`,
    ).bind(expiredCount, now - 100, now - 1).run();
    await env.DB.prepare(
      `INSERT INTO claim_v2 (token_verifier, share_id, fetches, created_at, expires_at)
       SELECT 'cleanup-claim-' || share_id, share_id, 0, ?, ?
       FROM share_v2 WHERE share_id LIKE 'cleanup-%'`,
    ).bind(now - 100, now - 1).run();
    await env.DB.prepare(
      `INSERT INTO share_v2
         (share_id, session_verifier, owner_token_verifier, tier, state, r2_key,
          payload_size, crypto_version, bundle_version, cipher, kdf, kdf_iterations,
          kdf_salt, wrapped_key, wrapped_key_nonce, created_at, expires_at)
       VALUES
         ('cleanup-live-ready', 'cleanup-live-session', 'cleanup-live-owner',
          'codeOnly', 'ready', 'v2/payloads/cleanup-live-ready.bin',
          1, 2, 2, 'aes-256-gcm-combined', 'none', 0,
          NULL, 'test-wrapped-key', 'test-wrapped-nonce', ?, ?),
         ('cleanup-young-upload', 'cleanup-upload-session', 'cleanup-upload-owner',
          'codeOnly', 'uploading', 'v2/payloads/cleanup-young-upload.bin',
          1, 2, 2, 'aes-256-gcm-combined', 'none', 0,
          NULL, 'test-wrapped-key', 'test-wrapped-nonce', ?, ?)`,
    ).bind(now - 10, now + 100, now - 10, now + 100).run();

    for (let offset = 0; offset < expiredCount; offset += 40) {
      await Promise.all(Array.from(
        { length: Math.min(40, expiredCount - offset) },
        (_, index) => env.PAYLOADS.put(
          `v2/payloads/cleanup-${String(offset + index).padStart(4, "0")}.bin`,
          bytes(0x91, 1),
        ),
      ));
    }
    await Promise.all([
      env.PAYLOADS.put("v2/payloads/cleanup-live-ready.bin", bytes(0x92, 1)),
      env.PAYLOADS.put("v2/payloads/cleanup-young-upload.bin", bytes(0x93, 1)),
    ]);

    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController({
      scheduledTime: Date.now(),
      cron: "0 * * * *",
    }), env, ctx);
    await waitOnExecutionContext(ctx);

    const remainingShares = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM share_v2 WHERE share_id LIKE 'cleanup-%'",
    ).first<{ n: number }>();
    const remainingClaims = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM claim_v2 WHERE token_verifier LIKE 'cleanup-claim-%'",
    ).first<{ n: number }>();
    expect(remainingShares?.n).toBe(2);
    expect(remainingClaims?.n).toBe(0);
    expect((await env.PAYLOADS.list({ prefix: "v2/payloads/cleanup-" })).objects
      .map((object) => object.key).sort()).toEqual([
        "v2/payloads/cleanup-live-ready.bin",
        "v2/payloads/cleanup-young-upload.bin",
      ]);
  });
});

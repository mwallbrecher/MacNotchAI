# Dragaway Share Protocol v2

All responses include `Cache-Control: no-store, max-age=0`, `Pragma: no-cache`, and
`X-Content-Type-Options: nosniff`. The API sends no CORS headers because its client is the native
Dragaway app; a self-host adding a browser client should allow only its explicit trusted origin.

Times are Unix seconds in JSON numbers. Binary strings are canonical, unpadded RFC 4648 base64url.
All error bodies use `{"error":{"code":"…","message":"…"}}`; internal exception text is never
returned. Unknown share IDs and invalid/expired tokens deliberately collapse to
`404 share_unavailable`.

## 1. Create a reusable session

`POST /v2/shares` with a raw AES-GCM combined payload as the request body.

Required common headers:

```text
Content-Type: application/octet-stream
Content-Length: 1..29360128
X-Dragaway-Tier: codeOnly | password
X-Dragaway-Crypto-Version: 2
X-Dragaway-Bundle-Version: 2 | 3
X-Dragaway-Cipher: aes-256-gcm-combined
X-Dragaway-Share-ID: <base64url of exactly 16 random bytes>
X-Dragaway-Owner-Token: <base64url of exactly 32 random bytes>
```

`Content-Length` is mandatory. Content encodings other than `identity` are rejected. The body is
streamed directly into private R2, then the returned object size is checked against the declared
length. No Base64 JSON copy is made.

Bundle version 2 is the legacy single-file envelope; bundle version 3 is the ordered multi-file
envelope used for two through five files. The file-byte limit remains 25 MiB in aggregate. The relay
does not parse either encrypted envelope: it accepts both declared versions, authenticates the chosen
version as part of the client's AES-GCM descriptor, stores that integer in the existing D1 row, and
returns it unchanged on every claim. Unsupported versions are rejected before R2 is written.

The Mac generates `share_id` and `owner_token` with a CSPRNG and persists both locally **before**
starting this mutating request. The Worker accepts only canonical unpadded base64url of the exact
lengths above, derives the R2 key from `share_id`, and stores only an HMAC verifier of `owner_token`.
It never generates or returns the owner capability. This means a lost Create response cannot leave
the sender without the capability needed to revoke a possibly committed upload. A collision of
either caller-generated value is never overwritten and returns the same generic `409 share_conflict`;
the client must generate a fresh pair and start a new Create.

For `codeOnly`:

```text
X-Dragaway-Kdf: none
X-Dragaway-Key: <base64url of exactly 32 random bytes>
```

The Worker AES-GCM-wraps this key under `KEY_WRAP_SECRET` with the `share_id` as authenticated
context before storing it in D1. It is unwrapped only for a valid session claim.

For `password`:

```text
X-Dragaway-Kdf: pbkdf2-hmac-sha256
X-Dragaway-Kdf-Iterations: <integer 100000..2000000>
X-Dragaway-Kdf-Salt: <base64url of 16..32 bytes; current app sends 32>
```

`X-Dragaway-Key` is forbidden. The password and derived AES key never reach the Worker.

Success: `201 Created`

```json
{
  "session_id": "123456",
  "share_id": "22-character-base64url",
  "expires_at": 1786060800
}
```

The returned `share_id` confirms the caller-provided value. Only `session_id` is shared with
colleagues. The six digits remain server-generated with CSPRNG rejection sampling and are atomically
reserved via a unique HMAC verifier in D1; a collision draws another six-digit ID without changing
the locally persisted owner capability.

## 2. Claim the snapshot

`POST /v2/claims`

```http
Content-Type: application/json
Content-Length: <required, max 128>

{"session_id":"123456"}
```

Success: `200 OK`

```json
{
  "share_id": "22-character-base64url",
  "claim_token": "43-character-base64url",
  "expires_at": 1786060800,
  "claim_expires_at": 1785975000,
  "tier": "password",
  "crypto": {
    "crypto_version": 2,
    "bundle_version": 2,
    "cipher": "aes-256-gcm-combined",
    "kdf": "pbkdf2-hmac-sha256",
    "kdf_iterations": 600000,
    "kdf_salt": "base64url"
  }
}
```

`bundle_version` is `2` for legacy single-file snapshots and `3` for multi-file snapshots. Migration
`0002_bundle_v3.sql` rebuilds the D1 parent table with `CHECK(bundle_version IN (2, 3))` and copies
existing rows verbatim. Existing v2 rows and their claim rows remain claimable after deployment.

For `codeOnly`, `crypto.kdf` is `none`, iterations are `0`, salt is `null`, and the response also
contains `"key":"<32-byte base64url>"`.

Each successful call creates a new independent 256-bit claim token. It expires after ten minutes or
at the share's 24-hour expiry, whichever comes first. Claiming does not consume, delete, or globally
limit a session; any number of colleagues may claim it sequentially or concurrently.

## 3. Download ciphertext

`GET /v2/shares/{share_id}/payload`

```http
Authorization: Bearer <claim_token>
```

Success: `200 OK`, raw `application/octet-stream`, streamed from R2. Each claim token permits at most
three transfer attempts so a dropped connection can retry without making the token an open-ended
capability. The recipient can obtain another token by claiming the still-live session again.

There is no ACK endpoint and a download never deletes the shared snapshot.

## 4. Owner revoke

`DELETE /v2/shares/{share_id}`

```http
Authorization: Bearer <owner_token>
```

Success: `204 No Content`. Only the owner token can revoke; a session ID or claim token cannot. D1 is
first atomically changed to `revoking`, immediately denying new claims and payload authorisations,
before physical R2 and metadata cleanup. A transfer already authorised concurrently may finish; no
network service can recall plaintext already delivered. Cron completes cleanup if storage deletion
is temporarily unavailable.

## 5. Retirement and health

- Every `/v1` path returns `410 Gone` with `upgrade_required`.
- `GET /healthz` returns protocol status only and does not query D1/R2.

## Rate limiting

Every sensitive route is protected twice:

1. Cloudflare's location-local RateLimit binding absorbs short bursts cheaply.
2. One atomic D1 UPSERT enforces an exact global fixed-window budget.

The budget subject is `HMAC(VERIFIER_HMAC_SECRET, CF-Connecting-IP)`. No plaintext IP, spoofable
device ID, session ID, or token enters the budget table. `CF-Connecting-IP` is set by Cloudflare, not
accepted from an app-specific identity header.

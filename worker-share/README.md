# Dragaway Share Worker

The small, self-hostable relay behind Dragaway's **Expose Session** feature. Protocol v2 keeps the
product's deliberate low-friction baseline: a colleague enters only the reusable six-digit session
ID for ordinary files, or the same ID plus a password for confidential files.

The service never receives a file name, conversation text, device identifier, or plaintext file.
It stores a bounded AES-GCM ciphertext in private R2 and opaque coordination metadata in D1.

The HTTP/crypto protocol remains v2. It accepts the legacy single-file bundle v2 and the ordered
2–5-file bundle v3; both retain the same 28 MiB transport cap and 25 MiB aggregate file-byte limit.

Read these before operating it:

- [`PROTOCOL_V2.md`](./PROTOCOL_V2.md) — exact HTTP contract and state transitions.
- [`SECURITY.md`](./SECURITY.md) — threat model, honest limits, and why each control exists.

## What changed from v1, and why

Protocol v1 used the six digits as locator, download authorisation, acknowledgement, and revoke
credential. It also stored the code-only AES key openly beside metadata, trusted a caller-provided
device header for rate limiting, buffered double-Base64 JSON, and deleted a session after one import.
Those properties made enumeration, deletion, races, and size-limit failures possible.

Protocol v2 preserves the visible six-digit workflow while separating internal capabilities:

| Value | Visible to | Purpose |
|---|---|---|
| six-digit `session_id` | sender and recipients | reusable human lookup until revoke/24 h |
| random 128-bit `share_id` | sender app before create; recipients after claim | non-guessable R2/API locator |
| random 256-bit `claim_token` | one recipient | ten-minute payload access, max three transfer attempts |
| random 256-bit `owner_token` | sender app before create | revoke only; never accepted as a claim token |

Every recipient gets an independent claim token for the same snapshot. There is deliberately no
recipient count or global fetch cap. The session remains available until the owner revokes it or the
24-hour server expiry passes.

The sender persists `share_id` and `owner_token` before upload, then supplies both as strict request
headers. The relay stores only the owner's HMAC verifier and never echoes the bearer token. Thus even
if the upload commits but its HTTP response is lost, the Mac retains the capability needed to retry
revoke. Caller-generated capability collisions are rejected generically and never overwrite data.

## Local verification

Requires Node.js 20+.

```bash
npm install
cp .dev.vars.example .dev.vars
# Replace both placeholders with independent 32-byte base64url secrets.
npm run types
npm run check
```

Tests run inside the Workers runtime with local D1 and R2 bindings. `npm run check` also validates
the generated binding types, runs strict TypeScript, and performs a Wrangler dry-run bundle. It does
not deploy or access production data.

## Self-host deployment

The checked-in `wrangler.jsonc` contains no Dragaway production resource IDs. Wrangler 4 can
automatically provision the named D1 database and R2 bucket on a new account; alternatively create
them explicitly and add the resulting `database_id` to your private deployment config.

1. Install dependencies and authenticate:

   ```bash
   npm install
   npx wrangler login
   ```

2. Generate two independent 32-byte secrets in unpadded base64url form and place them in a local
   ignored `.env.production` file:

   ```bash
   openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
   openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
   ```

   ```dotenv
   VERIFIER_HMAC_SECRET="FIRST_VALUE"
   KEY_WRAP_SECRET="SECOND_VALUE"
   ```

3. Create the stores. Paste the D1 command's `database_id` into a private deployment copy of
   `wrangler.jsonc`; the checked-in self-host example deliberately has no account identifier:

   ```bash
   npx wrangler d1 create dragaway-share
   npx wrangler r2 bucket create dragaway-share-payloads
   ```

4. Apply the D1 migration. **This intentionally invalidates any still-live v1 invitations.** The v1
   endpoint returns HTTP 410; old KV values remain inaccessible and expire under their existing TTL.

   ```bash
   npx wrangler d1 migrations apply dragaway-share --remote
   ```

5. Install the R2 lifecycle backstop and deploy both encrypted secrets with the same version. Using
   `--secrets-file` avoids the partially configured deployment that two sequential `secret put`
   commands could create:

   ```bash
   npx wrangler r2 bucket lifecycle set dragaway-share-payloads --file r2-lifecycle.json
   npx wrangler deploy --secrets-file .env.production
   ```

   A Worker already running protocol v2 must first apply `0002_bundle_v3.sql` with the migration
   command from step 4, then deploy this code. The migration preserves existing share rows and only
   widens the bundle-version check; the R2 bucket, lifecycle rule, and secrets remain unchanged.
   Deploy both pieces before releasing a Mac client that creates multi-file shares.

6. Verify the non-sensitive health endpoint:

   ```bash
   curl -i https://YOUR-WORKER.workers.dev/healthz
   ```

   Expected body: `{"status":"ok","protocol":"v2"}`.

No deployment is performed by this repository change. Resource creation, secret installation,
migration, lifecycle configuration, and deployment are explicit operator actions.

## Retention and deletion semantics

- Every claim and payload lookup requires `expires_at > now`, so a share becomes inaccessible at
  24 hours even if cleanup has not run yet.
- Owner revoke first atomically transitions D1 to `revoking`, immediately blocking new claims and
  payload authorisations, then deletes R2 and D1 data. An already authorised in-flight transfer may
  finish; plaintext already received cannot be recalled.
- Hourly cron atomically marks expired, revoked, or abandoned-upload rows as `revoking`, removes R2,
  then deletes D1 metadata in bounded set-based chunks. This closes upload-finalisation races and
  remains below the D1 Free per-invocation query limit.
- The two-day R2 lifecycle is a disaster-recovery backstop, not the primary 24-hour timer. Cloudflare
  lifecycle deletion can occur after its nominal time, so documentation must say “inaccessible after
  24 hours, physically cleaned afterward,” not promise destruction at an exact second.

## Secret rotation

`VERIFIER_HMAC_SECRET` protects lookup/token/IP verifiers; `KEY_WRAP_SECRET` protects code-only
content keys. Rotating either immediately invalidates affected live shares. Because shares live at
most 24 hours, the simple safe procedure is to stop creating shares, wait 24 hours, rotate both
secrets, then resume. A future key-version column can support overlapping rotations if zero downtime
becomes necessary.

## Licence

MIT — see [`LICENSE`](./LICENSE).

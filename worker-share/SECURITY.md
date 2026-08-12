# Security and privacy rationale

This document records both what the relay guarantees and what it intentionally does not. That
distinction matters because Dragaway supports a convenient six-digit baseline as a product decision.

## Trust tiers

### Code only — convenient baseline for ordinary files

The six-digit session ID is a human access credential, not a cryptographic key. A correct guess
during the 24-hour lifetime grants the snapshot. Rate limiting makes automated guessing expensive,
but no public six-digit space can be made cryptographically unguessable, especially against a large
distributed botnet.

The AES key is encrypted under a Worker secret before D1 storage, so an R2-only or D1-only data leak
does not immediately expose plaintext. The service operator, or an attacker controlling the Worker
and its secret, can still decrypt this tier. It must never be described as end-to-end encrypted.

### Code plus password — confidential files

The app derives the AES key locally with versioned native PBKDF2-HMAC-SHA256 parameters. Only salt,
iteration count, and ciphertext are uploaded. The password and derived key never leave either Mac,
so the Worker cannot decrypt a strong-password share. Captured ciphertext still permits offline
password guessing; password strength and the app's minimum policy remain essential.

## Why the internal capabilities exist

- A 128-bit random `share_id`, generated and persisted by the sender before Create, keeps object
  paths out of the six-digit enumeration space.
- A 256-bit recipient `claim_token` authorises only a short download window and three transport
  attempts. It cannot revoke.
- A separate 256-bit `owner_token` is generated and persisted by the sender before Create and
  authorises only revoke. The Worker never generates or returns it and stores it in D1 only as an
  HMAC verifier, so a database read does not yield the bearer token.
- Multiple recipients receive different claim tokens for the same immutable snapshot. There is no
  first-reader deletion and no product-level recipient cap.

This is capability separation: compromise or accidental disclosure of one value does not silently
grant every operation.

## Stored data

R2 contains only the raw AES-GCM combined ciphertext under an opaque path. D1 contains:

- HMAC verifier of the six-digit session ID (not the ID);
- random share ID and opaque R2 path;
- HMAC verifiers of owner and claim tokens (not bearer tokens);
- versioned cipher/KDF descriptor and public password salt;
- code-only key encrypted with AES-GCM under a Worker secret, or no key for password shares;
- expiry/state and aggregate operational counters;
- exact abuse counters keyed by an HMAC of `CF-Connecting-IP`.

It does **not** contain file names, file contents, transcript text, passwords, app device IDs,
plaintext IP addresses, or AI-provider credentials.

## Input and storage safety

- Create bodies require an explicit length and are capped at exactly 28 MiB before streaming.
- Header grammar, versions, key/salt lengths, KDF range, media type, and encoding are validated
  before R2 receives a byte.
- Caller-generated share IDs and owner tokens must be canonical fixed-length base64url. Unique D1
  constraints prevent overwrites; every supplied-capability collision has the same generic response.
- R2's resulting object size must equal `Content-Length`; mismatches are deleted.
- D1 CHECK constraints repeat the important tier/crypto invariants even if a future handler regresses.
- Session ID reservation uses `INSERT OR IGNORE` against a unique HMAC verifier, avoiding the v1
  select-then-insert collision race.
- Claim retries and revoke transitions are single conditional SQL updates, so concurrent requests
  cannot exceed the per-token limit or resurrect a revoked share.
- Cross-service R2/D1 operations use explicit intermediate states. Failed uploads are compensated;
  stale `uploading` and `revoking` rows are recovered by cron and the R2 lifecycle backstop. Cron
  first atomically changes eligible rows to `revoking`, closing the race with upload finalisation,
  then deletes R2 and D1 in bounded set-based chunks within D1 Free invocation limits.

## Network and logging safety

- Native clients use HTTPS; payload/key-bearing responses are `no-store`.
- Session IDs are sent in a POST body, not a URL that appears in ordinary access logs.
- The API emits no wildcard CORS policy.
- Application logs contain route templates, result classes, and status only—never IDs, tokens, IPs,
  ciphertext, headers, or exception text. Cloudflare may retain platform-level invocation metadata
  according to the operator's Cloudflare plan and policy; self-hosters must evaluate that separately.

## Rate-limit trade-off

Cloudflare's binding is deliberately only a fast burst guard because it is location-local and
eventually consistent. D1 is the exact global budget. Both use an HMACed connecting IP rather than a
caller-controlled device header.

IP limits can affect many legitimate users behind one corporate NAT. Current limits favour stopping
six-digit enumeration; operators with authenticated enterprise gateways can replace the subject with
a stable tenant/user identity. Removing or substantially increasing the exact claim budget weakens
the code-only tier and must be treated as a security decision.

Set-based retention stays below D1 Free's per-invocation query ceiling; it does not remove the
separate daily rows-written allowance. A relay approaching that traffic level needs usage monitoring
and an appropriate paid D1 plan rather than weaker retention.

## Expiry language

At `expires_at`, every D1 lookup rejects the share immediately. Cron then deletes R2 and D1 data. The
R2 two-day lifecycle is a final backstop and may physically execute after its nominal time. The
accurate promise is therefore:

> A share becomes inaccessible no later than 24 hours after creation and is physically cleaned up
> afterward; the sender can make it inaccessible earlier by revoking it.

Do not promise that every storage copy is physically erased at the exact 24-hour second.

## Residual risks

- Guessing a live unpassworded six-digit ID remains possible by design; use the password tier for
  confidential material.
- A malicious/compromised service operator can decrypt code-only shares and can deny service to any
  tier. It cannot decrypt a strong-password share from protocol data alone.
- A recipient who already downloaded plaintext cannot be made to forget it by revoke, and an
  already-authorised transfer racing with revoke may finish.
- Rate limiting cannot fully stop a sufficiently distributed attack without accounts, attestation,
  or a higher-entropy user credential.
- Secret rotation invalidates live shares unless an overlap/key-version migration is added.

These are product boundaries, not hidden implementation defects.

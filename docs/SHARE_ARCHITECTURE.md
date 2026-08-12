# Session Sharing v2 — Architecture and Security Model

**Status:** v2 is the only supported protocol · **Branch:** `main` (product work)

**Goal:** User A explicitly exposes the current Dragaway session. Any number of colleagues can
enter the same six-digit **Session ID** during its lifetime and receive the same immutable snapshot
as a new local session. Every recipient then works with their own AI provider and API key.

> Nothing is uploaded until the user deliberately chooses **Expose Session**. Sharing is a separate
> network path from AI-provider requests. It does not send the user's BYOK credential to the share
> service and it does not change where normal AI requests go.

This document is the source of truth for the product semantics, protocol, security claims, and
retention language. The standalone wire specification and relay-specific rationale live in
[`worker-share/PROTOCOL_V2.md`](../worker-share/PROTOCOL_V2.md) and
[`worker-share/SECURITY.md`](../worker-share/SECURITY.md).

---

## 1. Non-negotiable product semantics

1. **The Session ID remains reusable.** It is a six-digit, low-assurance bearer credential that
   remains valid until the sender revokes the share or its 24-hour lifetime ends.
2. **There is no share-wide recipient or download cap.** Colleagues may join sequentially or
   concurrently. Service-wide/per-IP abuse budgets still apply.
3. **Every recipient gets a fork, not a synced workspace.** The exposed artifact and existing AI
   turns form one immutable snapshot. Import creates a new local session; later work never flows
   back to the sender or to other recipients.
4. **A password is an optional second layer.** Code-only sharing is the convenient baseline for
   ordinary files. Code plus password is the end-to-end-encrypted tier for confidential files.
5. **The visible UX stays simple.** The sender shares a Session ID and, if enabled, a password. The
   recipient enters those values. Internal `share_id`, claim tokens, and owner tokens are never
   shown or copied as part of the normal flow.
6. **A recipient does not consume a share.** There is no ACK endpoint, first-reader deletion,
   one-time code rotation, or global fetch counter that disables later colleagues.

The internal random `share_id` does **not** replace the Session ID after the first join. It is only
an unguessable storage/routing identifier. Every successful redemption of the same Session ID maps
to that same immutable snapshot and receives a fresh, independent download capability.

---

## 2. Snapshot contents and bounds

A normal `SessionRecord` contains local file paths, which are meaningless on another Mac. The
encrypted share bundle therefore carries the value needed to reconstruct a local fork:

| Part | Contents | Purpose |
|---|---|---|
| Artifacts | one to five ordered filenames and their exact file bytes | gives the recipient local copies with the same primary/additional ordering |
| Insights | up to 100 existing turns: action, prompt title, result text, date | preserves the work already done |
| Snapshot metadata | bundle version and exposure time | provides a bounded, versioned import format |

The product supports **one to five regular files** per share. Folders, symbolic links, empty
sessions, and sessions with six or more files cannot be exposed. The **25 MiB** file-byte ceiling is
aggregate across the whole snapshot, not per file. Transcript metadata is capped at **2 MiB**;
individual fields are bounded before encoding or allocation. The encrypted transport cap remains
**28 MiB**, leaving room for the bundle frame and AES-GCM nonce/tag.

Before upload, the Expose panel lists every staged filename and highlights that all of them will be
shared. There is deliberately no second selection state in that dialog: the snapshot is the ordered
file set shown by the session. The user removes unintended files from the session before exposing it.

The transcript source is the exact active history identity, never the first record with a matching
path. **New conversation** arms a fresh lazy identity on the same file, so the old invisible record
cannot be exposed accidentally. A successful or failed **Go deeper / Regenerate** replaces that
record's final answer in place; if a stream fails after partial text, the partial response and warning
are finalized as one byte-identical UI/History result. Reopen and later sharing therefore see what the
sender sees.

`ShareBundle` uses binary envelopes rather than Base64-in-JSON. Single-file shares continue to emit
the original v2 format so new app versions remain compatible with existing recipients and active
shares. Only multi-file shares use v3:

```text
DRAGSHR2 | UInt32BE(metadata length) | canonical bounded JSON metadata | raw file bytes
DRAGSHR3 | UInt32BE(metadata length) | canonical ordered filename/length metadata | concatenated raw file bytes
```

The decoder checks the magic, authenticated bundle version, every length, aggregate size, file count,
unique/safe filenames, canonical metadata representation, turn count, and exact trailing byte count
before it copies variable-sized sections. This prevents partial imports, length bombs, ambiguous JSON,
and accidental unbounded allocation. Recipients accept both bundle v2 and v3; old clients reject v3
cleanly and never import only the first file.

The relay does not receive the filename, transcript, or file contents as separate metadata. They
exist only inside the encrypted bundle. It can still observe transport metadata such as time,
source IP, payload size, selected security tier, and versioned cipher/KDF parameters.

---

## 3. Capabilities and why they are separated

The user-visible credential and the internal capabilities have different jobs:

| Value | Entropy/lifetime | Who receives it | Authorises |
|---|---|---|---|
| Session ID | six decimal digits; share lifetime | sender and intended colleagues | request a fresh recipient claim |
| `share_id` | random 128 bits; share lifetime | sender app and relay internally | names an opaque snapshot; grants nothing by itself |
| claim token | random 256 bits; at most 10 minutes | one recipient | up to three transfer attempts for one snapshot |
| owner token | random 256 bits; share lifetime | sender only | revoke that snapshot |

This is capability separation, not a change to the sharing interaction:

```text
Colleague A enters 123456 ──→ claim A ──→ same immutable snapshot
Colleague B enters 123456 ──→ claim B ──→ same immutable snapshot
Colleague C enters 123456 ──→ claim C ──→ same immutable snapshot
Sender's owner token       ──→ revoke   ──→ blocks all future claims/downloads
```

A short-lived claim limits the damage of a leaked download credential and gives an interrupted
transfer a small retry budget. It is not a recipient count: after a claim expires or uses its three
attempts, the same still-live Session ID can obtain another claim. The owner token cannot download,
and a claim token cannot revoke.

The sender app generates `share_id` and owner token with `SecRandom` and durably retains them before
Create. The Worker generates Session IDs and claim tokens with Web Crypto. The relay stores HMAC
verifiers of Session IDs, claim tokens, and owner tokens rather than their plaintext values; unique
D1 constraints reserve the six-digit code atomically and avoid sequential codes/collision races.

---

## 4. Two honest security tiers

A six-digit code has only about 20 bits of entropy. It cannot safely become a cryptographic key:
applying a KDF to a million possible inputs makes the guesses slower but does not create entropy.
The protocol therefore has two deliberately different tiers.

| | Code only (default) | Code + password (optional) |
|---|---|---|
| User enters | Session ID | Session ID and password |
| Payload encryption | AES-256-GCM | AES-256-GCM |
| Content key | random 256-bit key generated on sender's Mac | derived locally from password |
| What the relay receives | ciphertext and content key | ciphertext, salt, and KDF parameters; no key/password |
| Relay readability | operator can technically decrypt | operator cannot decrypt from protocol data alone |
| Appropriate for | ordinary, non-confidential material | confidential material with a strong password |
| Honest label | encrypted, low-assurance access | end-to-end encrypted |

### 4.1 Code-only tier

The sender generates a random AES key locally and encrypts the bundle before upload. The relay wraps
that key with AES-GCM under its `KEY_WRAP_SECRET`, using the opaque `share_id` as authenticated
context, before storing it in D1. A valid Session ID claim causes the Worker to unwrap and return the
content key alongside the recipient's crypto descriptor.

This protects an isolated R2 payload leak and an isolated D1 read from immediately exposing the
file. It does **not** protect against the share-service operator, a compromised Worker with its
secrets, or somebody who successfully guesses/obtains the Session ID. Code-only sharing must never
be described as end-to-end encrypted or suitable for confidential files.

### 4.2 Password tier

The password and derived key never leave the sender's or recipient's Mac. v2 derives a 256-bit key
with:

```text
PBKDF2-HMAC-SHA256(password, random 32-byte salt, 600,000 iterations)
```

Passwords are bounded to 12–256 UTF-8 bytes. The current app accepts exactly the v2 work factor and
salt size on import rather than executing attacker-selected KDF costs. The relay accepts a bounded
parameter range for forward-compatible clients, but the Dragaway v2 client emits and accepts
600,000 iterations and a 32-byte salt.

The cipher/KDF descriptor is canonicalised and passed as AES-GCM additional authenticated data.
Changing the tier, bundle version, KDF, iteration count, or salt therefore makes authentication fail
instead of silently downgrading security.

### 4.3 Why PBKDF2 instead of Argon2id

Argon2id is memory-hard and is the preferred direction for a future password-envelope version.
However, it is not supplied by the Apple frameworks used by Dragaway. Adding it now would add a
native binary/dependency, its update and audit surface, signing/notarisation risk, and another
supply-chain boundary to an otherwise pure-Apple app.

PBKDF2-HMAC-SHA256 is provided by Apple's CommonCrypto (`CCKeyDerivationPBKDF`), is mature and
interoperable, and can be implemented without another dependency. The fixed 600,000-iteration work
factor is a deliberate baseline rather than relying on a fast hash. This is the right v2 trade-off
for the project's native-dependency policy, but it does not make weak passwords safe. The versioned
crypto descriptor leaves room for an Argon2id-based v3 migration without guessing parameters.

### 4.4 Offline password guessing remains possible

Anyone who knows or successfully guesses the six-digit Session ID can obtain the password-tier
ciphertext and public salt. They can then test password candidates offline without further relay
rate limits. PBKDF2 makes every guess more expensive; only a strong password provides the remaining
entropy. The UI must not imply that the Session ID or KDF eliminates this risk.

---

## 5. Protocol v2

All sensitive responses are `no-store`; errors avoid reflecting secrets. Session IDs travel in a
POST body rather than a URL. Opaque capabilities travel in `Authorization: Bearer` headers and are
never query parameters.

### 5.1 Create

```http
POST /v2/shares
Content-Type: application/octet-stream
Content-Length: <required; maximum 28 MiB>
X-Dragaway-Tier: codeOnly | password
X-Dragaway-Crypto-Version: 2
X-Dragaway-Bundle-Version: 2 | 3
X-Dragaway-Cipher: aes-256-gcm-combined
X-Dragaway-Share-ID: <base64url of exactly 16 sender-generated random bytes>
X-Dragaway-Owner-Token: <base64url of exactly 32 sender-generated random bytes>
```

The request body is the raw AES-GCM combined payload. Code-only requests also send `Kdf: none` and
the random 32-byte content key; password requests send `pbkdf2-hmac-sha256`, salt, and iteration
count and are forbidden from sending a key. The relay streams the body into R2 and verifies the
stored object size against `Content-Length`.

Bundle v2 means the legacy single-file `DRAGSHR2` envelope. Bundle v3 means the ordered 2–5-file
`DRAGSHR3` envelope. The Worker treats both as opaque ciphertext and stores the authenticated version
in the existing integer column. Migration `0002_bundle_v3.sql` widens that column's SQLite check from
`= 2` to `IN (2, 3)` while copying every existing share row; R2 objects and claim semantics are
unchanged. Apply the migration and deploy the dual-version Worker before distributing an app that
can create v3 shares.

Success returns:

```json
{
  "session_id": "123456",
  "share_id": "<opaque internal id>",
  "expires_at": 1786060800
}
```

The returned `share_id` must equal the sender-provided value. Only `session_id` is intended for
colleagues; the Worker never generates or returns the raw owner capability.

### 5.2 Claim

```http
POST /v2/claims
Content-Type: application/json

{"session_id":"123456"}
```

Each successful call returns the same internal snapshot identity plus a newly generated claim token,
share/claim expiry, and the authenticated crypto descriptor. Code-only responses also include the
unwrapped content key; password responses never do. Claiming does not mutate or consume the share.

### 5.3 Fetch

```http
GET /v2/shares/{share_id}/payload
Authorization: Bearer <claim_token>
```

The relay streams raw ciphertext from R2. One claim permits at most three transfer attempts during
its maximum ten-minute lifetime. There is intentionally no lifetime fetch or recipient cap on the
share.

### 5.4 Revoke

```http
DELETE /v2/shares/{share_id}
Authorization: Bearer <owner_token>
```

Revocation first atomically changes the D1 state to `revoking`, so new claims and payload requests
stop immediately. R2 and D1 cleanup follows; the scheduled sweep completes it if storage deletion
temporarily fails.

### 5.5 No ACK and no v1 downgrade

There is no ACK route. A successful import does not delete or alter the remote snapshot. This is
required for multiple colleagues and also avoids losing a session because the first recipient's
connection or app failed at the wrong moment.

Every `/v1` path returns `410 Gone`. The client does not fall back to v1 because its one-time/ACK and
conflated-capability semantics contradict the confirmed product model and its import path lacks the
v2 validation boundary.

---

## 6. Relay storage and abuse controls

The share service is deliberately separate from the AI metering proxy. It is an open-source,
self-hostable Cloudflare Worker under `worker-share/`.

### 6.1 R2 and D1 responsibilities

| Store | Data |
|---|---|
| R2 | raw AES-GCM ciphertext under `v2/payloads/{share_id}.bin` |
| D1 `share_v2` | opaque ID/path, HMAC credential verifiers, tier/crypto descriptor, wrapped code-only key or password salt, state, expiry, aggregate counters |
| D1 `claim_v2` | HMAC claim-token verifier, related share, expiry, retry count |
| D1 `abuse_budget_v2` | operation/window/count keyed by an HMAC of the connecting IP |

D1 never stores plaintext Session IDs, owner tokens, claim tokens, passwords, filenames,
transcripts, file contents, app device IDs, or AI-provider keys. The code-only key is present only in
wrapped form, although the service controls the wrapping secret and can therefore decrypt it.

Create, claim, claim-use, and revoke transitions use conditional/atomic D1 writes. R2/D1 operations
use explicit `uploading`, `ready`, and `revoking` states, cleanup compensation, and cron recovery so
partial cross-service failures do not publish incomplete shares or resurrect revoked ones.

### 6.2 Rate limits

The six-digit baseline relies on online abuse controls, but those controls must not turn into a
share-wide recipient limit:

1. Cloudflare Rate Limit bindings are cheap, location-local burst brakes.
2. D1 performs the authoritative global fixed-window count with one atomic UPSERT.

The budget subject is `HMAC(VERIFIER_HMAC_SECRET, CF-Connecting-IP)`, never a caller-supplied device
ID or plaintext IP in D1. Current exact D1 defaults per source IP are 50 creates, 30 claims, 180
payload attempts, and 30 revokes per hour. Current burst defaults are respectively 10, 8, 30, and
10 per minute.

These are service/abuse limits, not per-share recipient limits. Many users behind one corporate NAT
can affect each other, and a distributed attacker can spread guesses across IPs. A public six-digit
credential can be mitigated but never made cryptographically strong; password protection is the
correct control for confidential data.

---

## 7. Retention and accurate deletion language

**Availability TTL: 24 hours.** The sender can revoke earlier.

| Layer | Behaviour |
|---|---|
| D1 query/state | expired or revoked shares stop producing claims and payloads immediately |
| hourly Worker cron | removes expired, stuck-uploading, and revoking rows and their live R2 objects |
| R2 lifecycle | two-day object-age backstop removes ciphertext even if Worker cleanup fails |
| local cleanup | expired active-share metadata and its Keychain owner token are pruned from the sender's Mac |

R2 lifecycle execution is asynchronous and day-granular. Cloudflare may also retain infrastructure
backups, D1 Time Travel data, or platform metadata according to the operator's plan and retention
policy. Therefore the product must **not** promise physical erasure at the exact 24-hour second or
claim that every storage remnant is immediately destroyed.

Accurate language:

> The share can no longer be retrieved after 24 hours, or sooner if you revoke it. Dragaway then
> removes the live encrypted payload and metadata automatically; infrastructure retention and
> backups may make physical removal non-instant.

Revocation cannot erase plaintext that a recipient already imported, screenshots, forwarded files,
or copies made outside Dragaway.

---

## 8. Recipient import is a hostile-input boundary

The native client treats the relay response and every sender-controlled bundle field as untrusted:

1. `ShareClient` uses an ephemeral `URLSession` with no response cache or cookies, refuses redirects,
   validates MIME/status/typed JSON, rejects an oversized declared response before transfer, and
   cancels streamed data at the exact per-route byte limit.
2. `ShareCrypto` validates the exact descriptor and verifies the AES-GCM tag before parsing any
   plaintext bundle.
3. `ShareBundle` decodes canonical, bounded v2/v3 envelopes and rejects unknown versions, malformed
   metadata, oversized fields, invalid file counts, duplicate/unsafe names, aggregate overflow, and
   inconsistent per-file/trailing lengths.
4. `ShareImportPolicy` accepts only a documented extension allowlist. Executables, application
   bundles, installers, archives, disk images, unknown types, path separators, absolute/traversal
   names, hidden names, and control characters fail closed.
5. The destination must be Dragaway's real private Drops directory, not a final-component symlink.
   Import creates a mode-`0600`, no-follow, exclusive temporary file, flushes it, then uses
   `renameatx_np(..., RENAME_EXCL)` in the same directory. Existing files are never overwritten;
   safe collision names are allocated atomically.
6. Before detached persistence starts, Drops reserves every declared file's bytes/count, exact final
   collision name, and reservation-specific temp name. Every retention pass protects all paths across
   actor re-entry; `RENAME_EXCL` collision fails rather than falling through to an unreserved target.
7. `SessionHistoryStore` durably writes one fresh local record with the ordered primary/additional
   files and imported turns (including a valid zero-turn snapshot) before publishing its in-memory
   identity. Only that confirmed write releases the entire batch; any failure removes only this
   batch's uncommitted files and never leaves a partial session.
8. Shared imports enforce a 50-entry / 512 MiB private-folder budget. Cleanup protects saved, current,
   pending-add, imported-in-flight, and promised-file handoff paths. Safari/Photos/Mail promises hold
   a bounded delivery lease because those source apps write outside Dragaway's actor; cleanup resumes
   only after the paths reach the ViewModel (or the bounded receiver/recovery horizon ends). A generic
   receiver completing after its 30-second abandonment boundary is never handed off to a session,
   because its path may already have become eligible for cleanup. An import
   is refused rather than deleting a reopenable or in-flight session file. Existing ordinary
   text/link/image materialisation remains best-effort and may exceed the target when every older item
   is referenced; moving those producers onto preflight reservations is tracked separately.

There is no server ACK after import. Password retries reuse the already downloaded ciphertext and
derive/decrypt locally; a wrong password does not create another network request or consume another
claim attempt.

The extension allowlist and non-executable file mode reduce the attack surface but do not prove that
arbitrary document/media bytes are harmless. Downstream parsers and apps remain part of the local
trust boundary.

---

## 9. Sender-side local state

`ActiveShareStore` keeps the non-secret metadata needed to show and revoke still-live shares:
opaque `share_id`, optional Session ID, create state, filename, original endpoint, and timestamps.
It writes a bounded, versioned JSON envelope atomically in Application Support.

Before the mutating Create starts, the Mac generates the 128-bit `share_id` plus 256-bit owner token,
stores the token in Keychain, and persists a `.creating` metadata record. A lost HTTP response can
therefore leave at worst a visible **unconfirmed cleanup** record—not an unaddressable/unrevokable
remote share. A successful response promotes that same record to `.active`; the 100-record local
bound is checked before upload, and an unexpired owner capability is never evicted to make room.

The Keychain service identity is a hash of **original endpoint + share_id**, and the credential also
contains those routing coordinates. A malicious custom endpoint returning the same `share_id` as a
hosted share cannot replace its credential or trick Dragaway into sending a hosted bearer token to
the custom server. Neither the token nor credential JSON is written to UserDefaults/Application
Support.

Every active record retains the endpoint that created it. Changing the global sharing server later
does not send an existing owner capability to a different host: revoke always goes to the original
validated endpoint. A generic revoke `404` is not treated as deletion proof because v2 deliberately
hides unknown objects and wrong owner tokens behind the same response; Dragaway retains the local
capability until a confirmed `204` or local expiry. Closing the Expose panel only clears UI/controller
state; it does not revoke a displayed share or lose its Keychain credential.

---

## 10. User experience and disclosure

### Sender

The Expose panel names the exact file and existing AI results that will leave the Mac. Before upload
the user chooses one of two clear modes:

- **Session ID only:** encrypted, convenient, reusable for ordinary files; anybody with a valid ID
  can open it during the remaining lifetime, and the service can technically read it.
- **Session ID + password:** end-to-end encrypted; the password never leaves the Macs; use a strong
  password and share it through a different channel.

After a successful upload the panel displays only the formatted six-digit Session ID, whether a
password is also required, expiration, and revoke controls. An Active Exposed Sessions surface lets
the sender revoke later using the Keychain-held owner capability.

### Recipient

Join Session first asks for the Session ID. A password field appears only if the claimed snapshot is
password protected. After safe import, Dragaway opens the newly created local history record. The
recipient uses their own provider/model/API key for all new actions.

The UI never exposes the internal `share_id`, claim token, or owner token. It must say **Session ID**,
not PIN, because the value is a reusable access credential rather than a second-factor or one-time
secret.

---

## 11. Self-hosting and transport trust

Organisations can deploy `worker-share/` with their own D1 database, private R2 bucket, independent
HMAC/key-wrap secrets, rate-limit bindings, cron, and lifecycle policy. The app's Session Sharing
settings accept:

- HTTPS endpoints for any valid host;
- HTTP only for loopback development (`localhost`, `127.0.0.1`, or `::1`);
- no embedded credentials, query string, or URL fragment.

`BackendConfig.shareBaseURL` selects the hosted default or a validated UserDefaults override. This
setting affects only Session Sharing; BYOK AI calls continue directly to the selected AI provider.

The native client uses normal macOS TLS certificate validation. It deliberately does **not** pin a
certificate, because enterprise/self-hosted endpoints and ordinary certificate rotation must work.
Accordingly, do not claim that traffic is impossible to intercept. TLS protects against ordinary
network observers under the system trust model; a compromised trusted CA, endpoint, client Mac, or
server remains relevant. Password-tier payload encryption is an independent confidentiality layer,
while code-only key escrow still trusts the configured service.

Changing to a self-hosted endpoint changes the organisation operating the relay and its Cloudflare
account/policies; it does not remove the need to review that operator's logging, backup, access, and
secret-management practices.

---

## 12. Threat model and residual risks

| Adversary/event | Code only | Password tier |
|---|---|---|
| isolated R2 leak | ciphertext without key | ciphertext without key |
| isolated D1 read | wrapped key; no Session ID/token plaintext | salt/KDF metadata; no key/password |
| valid/guessed Session ID | grants a claim and plaintext access | grants ciphertext/salt; strong password still required |
| malicious relay/operator | can decrypt and deny service | can deny service and enable offline guesses, but cannot decrypt a strong-password payload from protocol data alone |
| passive network observer | protected by standard TLS | protected by TLS and application-layer encryption |
| compromised system trust/endpoint | code-only key and payload may be exposed | ciphertext/salt may be exposed; offline password guessing remains |
| authorised recipient | can keep, copy, or forward plaintext | same |
| sender/recipient Mac compromise | plaintext may be read before encryption or after import | same |

Additional boundaries:

- The six-digit tier is intentionally low assurance. CSPRNG generation, uniqueness, short TTL, and
  exact IP budgets reduce online guessing but do not remove it, particularly against distributed
  attackers.
- The relay sees source IP and traffic metadata at request time even though D1 stores only an HMACed
  IP verifier. Cloudflare platform logs/observability may retain additional invocation metadata.
- There are no accounts, recipient identities, ACLs, read receipts, or guarantees about who entered
  a Session ID.
- Availability is not guaranteed. The relay can refuse, delete, corrupt, or withhold ciphertext;
  authenticated encryption makes undetected modification fail but cannot force delivery.
- Secret rotation requires overlap/key versioning or invalidates still-live code-only shares.
- Revocation prevents future relay retrieval; it cannot recall an existing local fork.

### Claims we may and may not make

| Accurate | Inaccurate |
|---|---|
| nothing leaves the Mac before explicit Expose | sharing is entirely local |
| bundle construction and encryption happen locally | the service never sees a key in code-only mode |
| password and password-derived key never reach the relay | a password prevents all offline guessing |
| password mode is E2EE under the stated endpoint/client assumptions | Session ID alone is E2EE or high security |
| Session ID can serve multiple colleagues until revoke/24 h | the first recipient deletes or consumes the share |
| imported sessions are independent local forks | recipients enter a live synchronised workspace |
| the share becomes unavailable at expiry/revoke | every physical storage copy is erased at exactly 24 h |
| TLS uses the macOS trust store without pinning | API traffic is impossible to intercept |

---

## 13. Implementation map

### macOS app

| Path | Responsibility |
|---|---|
| `MacNotchAI/AppDelegate.swift` | Expose/Join hotkeys and windows, active-share menu/revoke entry points, opening imported history |
| `MacNotchAI/Share/ExposeSessionView.swift` | explicit consent, tier disclosure, Session ID and revoke UI |
| `MacNotchAI/Share/JoinSessionView.swift` | Session ID entry, conditional local password retry, import progress |
| `MacNotchAI/Share/ShareController.swift` | off-main bundle/crypto work, protocol orchestration, safe import, active-share persistence |
| `MacNotchAI/Share/ShareInvitation.swift` | strict parsing/formatting of the six-digit Session ID |
| `MacNotchAI/Share/ShareBundle.swift` | bounded canonical v2 snapshot envelope |
| `MacNotchAI/Share/ShareCrypto.swift` | AES-GCM, authenticated descriptor, CommonCrypto PBKDF2, secure randomness |
| `MacNotchAI/Share/ShareClient.swift` | typed v2 requests, ephemeral/no-redirect transport, response bounds |
| `MacNotchAI/Share/ShareImportPolicy.swift` | filename/type allowlist and atomic no-overwrite persistence |
| `MacNotchAI/Share/ActiveShareStore.swift` | active metadata plus Keychain-separated owner capability |
| `MacNotchAI/Models/SessionHistoryStore.swift` | exact imported local session/fork creation |
| `MacNotchAI/Core/BackendConfig.swift` | hosted/self-host endpoint validation and selection |
| `MacNotchAI/UI/SettingsView.swift` | Session Sharing endpoint settings and disclosure |

### relay

| Path | Responsibility |
|---|---|
| `worker-share/src/index.ts` | v2 routes, R2 streaming, state transitions, scheduled cleanup |
| `worker-share/src/http.ts` | strict headers/bodies/capabilities, errors, safe structured logs |
| `worker-share/src/crypto.ts` | CSPRNG identifiers, HMAC verifiers, code-only key wrapping |
| `worker-share/src/database.ts` | atomic D1 reservation, claims, exact budgets, revoke and cleanup |
| `worker-share/src/constants.ts` | protocol versions, TTLs, retry and payload/KDF bounds |
| `worker-share/schema.sql`, `worker-share/migrations/` | D1 invariants and deployable schema |
| `worker-share/wrangler.jsonc` | D1/R2/rate-limit/cron bindings and required secrets |
| `worker-share/r2-lifecycle.json` | encrypted-payload cleanup backstop |

---

## 14. Why v1 was retired

The old design coupled access directly to the six-digit code, proposed ACK/first-recipient cleanup,
and used global attempt/fetch limits. Those choices were incompatible with a reusable collaboration
snapshot: one colleague could consume or lock out everyone else, a failed first import could destroy
the only remote copy, and the same credential implicitly covered unrelated operations. It also lacked
the complete hostile-import and bounded-binary boundary now required by the client.

v2 fixes the model without changing the simple visible flow:

- reusable Session ID for the full share lifetime;
- independent short-lived recipient claims;
- separate sender-only revoke capability;
- no ACK, first-fetch deletion, or share-wide recipient/fetch cap;
- D1 atomic state and exact abuse budgets plus R2 streaming/storage;
- versioned authenticated crypto and bounded safe import;
- honest distinction between server-readable code-only sharing and password E2EE.

---

## 15. Deliberately out of scope

- folders, sessions with more than five files, or payloads above the current aggregate limits;
- live/synchronised co-editing, presence, comments, or conflict resolution;
- recipient identity, accounts, ACLs, read receipts, or remote deletion of local forks;
- high-entropy share links with URL-fragment keys;
- PAKE/live pairing, which would require both parties online simultaneously;
- Argon2id until a reviewed dependency and migration strategy justify the added native boundary;
- scanning end-to-end-encrypted payloads for abuse.

These are separate product/security decisions. They must not be silently approximated by weakening
the v2 invariants above.

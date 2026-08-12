-- Share protocol v2. Applying this migration intentionally retires every live v1
-- locator. The old KV ciphertext is already self-expiring and is no longer bound or
-- routable; dropping its D1 lookup table makes it immediately unreachable.
DROP TABLE IF EXISTS create_usage;
DROP TABLE IF EXISTS shares;

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS share_v2 (
  share_id                TEXT PRIMARY KEY,
  session_verifier        TEXT NOT NULL UNIQUE,
  owner_token_verifier    TEXT NOT NULL UNIQUE,
  tier                    TEXT NOT NULL CHECK (tier IN ('codeOnly', 'password')),
  state                   TEXT NOT NULL CHECK (state IN ('uploading', 'ready', 'revoking')),
  r2_key                  TEXT NOT NULL UNIQUE,
  payload_size            INTEGER NOT NULL CHECK (payload_size BETWEEN 1 AND 29360128),
  payload_etag            TEXT,
  crypto_version          INTEGER NOT NULL CHECK (crypto_version = 2),
  bundle_version          INTEGER NOT NULL CHECK (bundle_version = 2),
  cipher                  TEXT NOT NULL CHECK (cipher = 'aes-256-gcm-combined'),
  kdf                     TEXT NOT NULL CHECK (kdf IN ('none', 'pbkdf2-hmac-sha256')),
  kdf_iterations          INTEGER NOT NULL,
  kdf_salt                TEXT,
  wrapped_key             TEXT,
  wrapped_key_nonce       TEXT,
  claim_count             INTEGER NOT NULL DEFAULT 0 CHECK (claim_count >= 0),
  payload_fetch_count     INTEGER NOT NULL DEFAULT 0 CHECK (payload_fetch_count >= 0),
  created_at              INTEGER NOT NULL,
  expires_at              INTEGER NOT NULL,
  revoked_at              INTEGER,
  CHECK (expires_at > created_at),
  CHECK (
    (tier = 'codeOnly'
      AND kdf = 'none' AND kdf_iterations = 0 AND kdf_salt IS NULL
      AND wrapped_key IS NOT NULL AND wrapped_key_nonce IS NOT NULL)
    OR
    (tier = 'password'
      AND kdf = 'pbkdf2-hmac-sha256'
      AND kdf_iterations BETWEEN 100000 AND 2000000
      AND kdf_salt IS NOT NULL
      AND wrapped_key IS NULL AND wrapped_key_nonce IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_share_v2_expiry_state
  ON share_v2 (expires_at, state);
CREATE INDEX IF NOT EXISTS idx_share_v2_state_created
  ON share_v2 (state, created_at);

CREATE TABLE IF NOT EXISTS claim_v2 (
  token_verifier   TEXT PRIMARY KEY,
  share_id         TEXT NOT NULL REFERENCES share_v2(share_id) ON DELETE CASCADE,
  fetches          INTEGER NOT NULL DEFAULT 0 CHECK (fetches BETWEEN 0 AND 3),
  created_at       INTEGER NOT NULL,
  expires_at       INTEGER NOT NULL,
  last_used_at     INTEGER,
  CHECK (expires_at > created_at)
);

CREATE INDEX IF NOT EXISTS idx_claim_v2_share
  ON claim_v2 (share_id);
CREATE INDEX IF NOT EXISTS idx_claim_v2_expiry
  ON claim_v2 (expires_at);

-- `subject_verifier` is HMAC(secret, CF-Connecting-IP), never the IP itself.
-- The UPSERT in the Worker is one atomic statement, making this the exact global
-- budget; Cloudflare's RateLimit binding is only an additional fast burst brake.
CREATE TABLE IF NOT EXISTS abuse_budget_v2 (
  subject_verifier TEXT NOT NULL,
  operation        TEXT NOT NULL CHECK (operation IN ('create', 'claim', 'payload', 'revoke')),
  window_start     INTEGER NOT NULL,
  count            INTEGER NOT NULL CHECK (count >= 0),
  expires_at       INTEGER NOT NULL,
  PRIMARY KEY (subject_verifier, operation, window_start)
);

CREATE INDEX IF NOT EXISTS idx_abuse_budget_v2_expiry
  ON abuse_budget_v2 (expires_at);

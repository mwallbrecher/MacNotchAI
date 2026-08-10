-- Preserve every protocol-v2 row while widening only the authenticated bundle-format check.
-- SQLite cannot alter a CHECK constraint in place, so the parent table is rebuilt with identical
-- columns/constraints and bundle_version IN (2, 3). Existing claim_v2 rows continue to reference
-- the recreated share_v2 table by name.
PRAGMA foreign_keys = OFF;

CREATE TABLE share_v2_bundle_v3 (
  share_id                TEXT PRIMARY KEY,
  session_verifier        TEXT NOT NULL UNIQUE,
  owner_token_verifier    TEXT NOT NULL UNIQUE,
  tier                    TEXT NOT NULL CHECK (tier IN ('codeOnly', 'password')),
  state                   TEXT NOT NULL CHECK (state IN ('uploading', 'ready', 'revoking')),
  r2_key                  TEXT NOT NULL UNIQUE,
  payload_size            INTEGER NOT NULL CHECK (payload_size BETWEEN 1 AND 29360128),
  payload_etag            TEXT,
  crypto_version          INTEGER NOT NULL CHECK (crypto_version = 2),
  bundle_version          INTEGER NOT NULL CHECK (bundle_version IN (2, 3)),
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

INSERT INTO share_v2_bundle_v3 (
  share_id, session_verifier, owner_token_verifier, tier, state, r2_key,
  payload_size, payload_etag, crypto_version, bundle_version, cipher, kdf,
  kdf_iterations, kdf_salt, wrapped_key, wrapped_key_nonce, claim_count,
  payload_fetch_count, created_at, expires_at, revoked_at
)
SELECT
  share_id, session_verifier, owner_token_verifier, tier, state, r2_key,
  payload_size, payload_etag, crypto_version, bundle_version, cipher, kdf,
  kdf_iterations, kdf_salt, wrapped_key, wrapped_key_nonce, claim_count,
  payload_fetch_count, created_at, expires_at, revoked_at
FROM share_v2;

DROP TABLE share_v2;
ALTER TABLE share_v2_bundle_v3 RENAME TO share_v2;

CREATE INDEX idx_share_v2_expiry_state ON share_v2 (expires_at, state);
CREATE INDEX idx_share_v2_state_created ON share_v2 (state, created_at);

PRAGMA foreign_keys = ON;

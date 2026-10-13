-- Legacy opaque sessions cannot authenticate JWT requests after the upgrade.
DELETE FROM sessions;
CREATE TABLE IF NOT EXISTS refresh_tokens (
    token_hash TEXT PRIMARY KEY,
    session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
    consumed INTEGER NOT NULL DEFAULT 0 CHECK(consumed IN (0,1))
);
CREATE INDEX IF NOT EXISTS idx_refresh_session ON refresh_tokens(session_hash);

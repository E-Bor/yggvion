CREATE TABLE IF NOT EXISTS records (
 id TEXT PRIMARY KEY, kind TEXT NOT NULL, version INTEGER NOT NULL,
 deleted INTEGER NOT NULL DEFAULT 0, data TEXT NOT NULL, seq INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS changes (
 seq INTEGER PRIMARY KEY AUTOINCREMENT, record TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS operations (
 id TEXT PRIMARY KEY, device_id TEXT NOT NULL, request_hash TEXT NOT NULL, result TEXT NOT NULL,
 created INTEGER NOT NULL, payload_bytes INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT UNIQUE NOT NULL, revoked INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS attachments (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, size INTEGER NOT NULL, media_type TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS server_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS invitations (
 token_hash TEXT PRIMARY KEY, expires INTEGER NOT NULL, issuer TEXT NOT NULL
);
CREATE INDEX records_kind ON records(kind,deleted);
CREATE INDEX records_seq ON records(seq);
CREATE INDEX operations_created ON operations(created);
CREATE INDEX invitations_expires ON invitations(expires);
CREATE TABLE calendar_shares (
 id TEXT PRIMARY KEY, token_hash TEXT UNIQUE NOT NULL, issuer TEXT NOT NULL,
 expires INTEGER NOT NULL, start TEXT NOT NULL, end TEXT NOT NULL, timezone TEXT NOT NULL
);
CREATE INDEX calendar_shares_expires ON calendar_shares(expires);
CREATE TABLE calendar_proposals (
 share_id TEXT NOT NULL REFERENCES calendar_shares(id) ON DELETE CASCADE,
 nonce TEXT NOT NULL, fingerprint TEXT NOT NULL, task_id TEXT NOT NULL,
 PRIMARY KEY(share_id,nonce)
);
CREATE TABLE encrypted_uploads (id TEXT PRIMARY KEY, key_id TEXT NOT NULL);
CREATE TABLE guest_inbox (id TEXT PRIMARY KEY, data TEXT NOT NULL, created INTEGER NOT NULL);
CREATE TABLE calendar_availability (
 share_id TEXT PRIMARY KEY REFERENCES calendar_shares(id) ON DELETE CASCADE, busy TEXT NOT NULL
);
PRAGMA user_version = 8;

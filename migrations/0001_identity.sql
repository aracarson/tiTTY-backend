-- MARK: - Task list
-- [x] Enforce identiTTY, AccountID and public-key uniqueness in SQLite
-- [x] Cascade challenges when an account is removed

CREATE TABLE IF NOT EXISTS accounts (
    account_id TEXT PRIMARY KEY NOT NULL,
    identitty TEXT NOT NULL COLLATE NOCASE UNIQUE,
    public_key BLOB NOT NULL UNIQUE,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS authentication_challenges (
    challenge_id TEXT PRIMARY KEY NOT NULL,
    account_id TEXT NOT NULL,
    challenge BLOB NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_authentication_challenges_account
ON authentication_challenges(account_id);

CREATE INDEX IF NOT EXISTS idx_authentication_challenges_expiry
ON authentication_challenges(expires_at);

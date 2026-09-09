-- Persistent block relationships and short-lived direct-chat rendezvous.
CREATE TABLE IF NOT EXISTS blocked_accounts (
    blocker_account_id TEXT NOT NULL,
    blocked_account_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (blocker_account_id, blocked_account_id),
    FOREIGN KEY (blocker_account_id) REFERENCES accounts(account_id) ON DELETE CASCADE,
    FOREIGN KEY (blocked_account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS live_chat_requests (
    request_id TEXT PRIMARY KEY NOT NULL,
    lease_id TEXT NOT NULL UNIQUE,
    client_request_id TEXT NOT NULL,
    sender_account_id TEXT NOT NULL,
    recipient_account_id TEXT NOT NULL,
    sender_public_key BLOB NOT NULL,
    encrypted_payload BLOB NOT NULL,
    created_at TEXT NOT NULL,
    lease_expires_at TEXT NOT NULL,
    hard_expires_at TEXT NOT NULL,
    FOREIGN KEY (sender_account_id) REFERENCES accounts(account_id) ON DELETE CASCADE,
    FOREIGN KEY (recipient_account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_live_chat_requests_recipient_expiry
ON live_chat_requests(recipient_account_id, lease_expires_at, hard_expires_at);

CREATE INDEX IF NOT EXISTS idx_live_chat_requests_sender_expiry
ON live_chat_requests(sender_account_id, lease_expires_at, hard_expires_at);

CREATE UNIQUE INDEX IF NOT EXISTS idx_live_chat_requests_sender_client_request
ON live_chat_requests(sender_account_id, client_request_id);

CREATE INDEX IF NOT EXISTS idx_blocked_accounts_blocked
ON blocked_accounts(blocked_account_id, blocker_account_id);

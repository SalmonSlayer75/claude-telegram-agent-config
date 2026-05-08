-- Inter-agent messaging schema (SQLite)
-- Used by interbot-send-v3 for real-time bot-to-bot communication.

CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    sender TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'direct',
    subject TEXT,
    body_json TEXT NOT NULL,
    thread_id TEXT,
    reply_to_id INTEGER REFERENCES messages(id),
    dedupe_key TEXT
);

-- Dedupe: prevents the same sender from inserting duplicate messages
CREATE UNIQUE INDEX IF NOT EXISTS idx_dedupe
    ON messages(sender, dedupe_key) WHERE dedupe_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS recipients (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id INTEGER NOT NULL REFERENCES messages(id),
    recipient TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    delivery_state TEXT NOT NULL DEFAULT 'pending',
    delivered_at TEXT
);

-- Fast lookup for pending deliveries per recipient
CREATE INDEX IF NOT EXISTS idx_pending
    ON recipients(recipient, delivery_state) WHERE delivery_state = 'pending';

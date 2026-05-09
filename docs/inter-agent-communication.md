# Inter-Agent Communication

When you run multiple bots, they need a way to coordinate. A task that starts with the CTO may require action from a VP Engineering bot. A DevOps bot may need to notify all bots about infrastructure changes.

This guide covers the file-based inbox system we use to coordinate a fleet of 6 bots.

## The Problem

Multiple bots run in isolated tmux sessions with separate context windows. They can't message each other through Telegram (that's for human-to-bot communication). They need an async coordination channel that:

- Works even if the recipient bot is mid-conversation or restarting
- Has priority levels so urgent requests get handled first
- Is discoverable — bots check for messages automatically
- Is simple — just markdown files, no external dependencies

## The Solution: Inbox Files

Each bot has an `inbox.md` file in its working directory. To send a message to another bot, you write to their inbox file. A hook checks the inbox before every Telegram reply, so messages get picked up automatically.

### Inbox File Format

```markdown
# Bot-Name Inbox
<!-- Inter-agent messages. Check for Status: new messages and handle them. -->
<!-- After handling, change Status from "new" to "done". -->
<!-- Periodically delete done messages older than 3 days. -->

## MSG-2026-04-01-1430
- **From:** devops
- **To:** vpe-project-a
- **Priority:** P1
- **Type:** request
- **Status:** new

Hooks updated fleet-wide. You need a restart to pick up the new mandatory state-save gates.
Please restart at your next natural break point.

## MSG-2026-04-01-0900
- **From:** cto
- **To:** vpe-project-a
- **Priority:** P1
- **Type:** request
- **Re:** MSG-2026-03-31-1800
- **Status:** done

Architecture review complete. See ~/CTO/reference/review-notes.md for findings.
```

### Message Fields

| Field | Required | Values |
|-------|----------|--------|
| **From** | Yes | Sender bot name |
| **To** | Yes | Recipient bot name |
| **Priority** | Yes | `P0` (blocker/outage), `P1` (action needed), `P2` (FYI/info) |
| **Type** | Yes | `request`, `response`, `info` |
| **Re** | No | Original MSG-ID if responding to a message |
| **Status** | Yes | `new` (unread), `done` (handled) |

### Bot Directory

Map bot names to inbox paths. Customize this for your fleet:

| Bot | Inbox Path |
|-----|------------|
| cos | ~/COS/inbox.md |
| cto | ~/CTO/inbox.md |
| vpe-project-a | ~/ProjectA/inbox.md |
| vpe-project-b | ~/ProjectB/inbox.md |
| devops | ~/DevOps/inbox.md |

## Setup

### 1. Create Inbox Files

Create an `inbox.md` in each bot's working directory:

```markdown
# Bot-Name Inbox
<!-- Inter-agent messages. Check for Status: new messages and handle them. -->
<!-- After handling, change Status from "new" to "done". -->
<!-- Periodically delete done messages older than 3 days. -->
```

### 2. Install the Inbox Check Script

Copy [examples/inter-agent/inbox-check](../examples/inter-agent/inbox-check) to `~/bin/` and `chmod +x` it. Edit the `INBOX_PATH` array to match your bot directory layout.

### 3. Add Hook Integration

The inbox check is already included in the [hooks config](../examples/hooks/settings.local.json) as a PreToolUse hook on the Telegram reply tool:

```json
{
  "matcher": "mcp__plugin_telegram_telegram__reply",
  "hooks": [
    {
      "type": "command",
      "command": "~/bin/inbox-check mybot 2>/dev/null || true"
    }
  ]
}
```

This runs before every Telegram reply. If there are new messages, the bot sees a prompt to read its inbox. If not, the hook exits silently.

### 4. Add CLAUDE.md Instructions

Add these instructions to each bot's CLAUDE.md:

```markdown
## Inter-Agent Communication

You can send messages to other bots and receive messages from them via the inbox system.

### Checking Your Inbox
Your inbox is checked automatically before every Telegram reply. If you have new messages,
you'll be prompted to read your inbox file. After handling a message, change its
**Status:** from `new` to `done`.

### Sending Messages
To send a message to another bot, append it to their inbox file using the format in
your inbox template. Always set **Status: new** when sending.

### Guidelines
- Use **P0** only for blockers or outages. **P1** for action needed. **P2** for FYI/info.
- Keep messages concise — the recipient reads this at the start of their interaction.
- Prune `done` messages older than 3 days.
- Do not send messages for things you can resolve yourself.
```

## Guidelines

- **P0 = blockers only.** A bot is down, data is being lost, or a user-facing service is broken.
- **P1 = action needed.** The recipient needs to do something, but it's not an emergency.
- **P2 = FYI.** Informational — the recipient should be aware but doesn't need to act.
- **Don't over-communicate.** Only send messages when the task genuinely requires another bot's domain. If you can resolve it yourself, do it.
- **Prune regularly.** Delete `done` messages older than 3 days to keep inbox files small.
- **Set Status: new when sending.** The recipient changes it to `done` after handling.
- **Include Re: when responding.** Reference the original MSG-ID so context is traceable.

---

## v3: SQLite-Based Real-Time Messaging

The file-based inbox works for 2-3 bots but has limitations as the fleet grows:

- **Race conditions**: two bots appending to the same `inbox.md` simultaneously can corrupt the file
- **No threading**: matching replies to original messages requires manual MSG-ID tracking
- **No delivery confirmation**: the sender doesn't know if the recipient read the message
- **Polling overhead**: every bot greps every inbox before every Telegram reply

### The Upgrade

v3 replaces markdown files with a shared SQLite database. SQLite handles concurrent writes atomically — no corruption risk.

### Schema

```sql
CREATE TABLE messages (
  id INTEGER PRIMARY KEY,
  from_bot TEXT NOT NULL,
  subject TEXT,
  body TEXT NOT NULL,
  thread_id TEXT,
  reply_to INTEGER REFERENCES messages(id),
  created_at TEXT DEFAULT (datetime('now')),
  dedupe_key TEXT UNIQUE
);

CREATE TABLE recipients (
  message_id INTEGER REFERENCES messages(id),
  to_bot TEXT NOT NULL,
  delivered INTEGER DEFAULT 0,
  delivered_at TEXT,
  PRIMARY KEY (message_id, to_bot)
);

CREATE UNIQUE INDEX idx_dedupe ON messages(dedupe_key) WHERE dedupe_key IS NOT NULL;
```

### Sending a Message

Use the `interbot-send-v3` script:

```bash
# Simple message
interbot-send-v3 --to cto --subject "Hook update ready" --body "Fleet hooks regenerated. Need your review."

# Reply to a previous message (threading)
interbot-send-v3 --to cto --reply-to 42 --body "Done. Configs deployed."

# With dedupe key (safe to retry after crash)
interbot-send-v3 --to vpe-project-a --dedupe-key "deploy-hooks-2026-05-08" --body "..."
```

### Receiving Messages

v3 uses **wake-file notifications** instead of polling. When a message is sent, the sender touches a file at `~/.claude/interbot-wake/<bot-name>`. The recipient's channel plugin detects the file change and delivers the message in real-time — no hook-based polling needed.

For bots still using the hook-based approach, a check script queries the SQLite database for undelivered messages addressed to that bot.

### Key Improvements Over v1

| Feature | v1 (file-based) | v3 (SQLite) |
|---------|-----------------|-------------|
| Concurrent writes | Risk of corruption | Atomic (SQLite WAL mode) |
| Threading | Manual MSG-ID matching | `reply_to` + `thread_id` fields |
| Delivery tracking | None | `recipients.delivered` flag |
| Crash recovery | Lost messages possible | `dedupe_key` prevents duplicates |
| Notification | Polling via hook | Wake-file push notification |
| Scalability | Degrades with message volume | SQLite handles thousands of messages |

### When to Use Which

- **v1 (file-based)**: Simple setups with 2-3 bots and infrequent coordination. No external dependencies beyond the filesystem.
- **v3 (SQLite)**: Fleets of 4+ bots, high message volume, or when delivery reliability matters. Requires SQLite3 (pre-installed on most Linux systems).

### Migration

v1 and v3 can coexist. The inbox.md files still work for bots that haven't been upgraded. Migrate one bot at a time by:

1. Install the `interbot-send-v3` script and `schema.sql`
2. Initialize the database: `sqlite3 ~/.claude/interbot.db < schema.sql`
3. Update the bot's hooks to check SQLite instead of inbox.md
4. Other bots can still send to this bot via either system

See [examples/inter-agent/](../examples/inter-agent/) for the schema and sender script.

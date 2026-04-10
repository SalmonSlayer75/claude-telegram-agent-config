# Bot Gate — Hard State-Save Enforcement

The bot gate replaces soft "please save your state" reminders with a **hard gate** that blocks substantive tool calls unless the bot is keeping its state file up to date.

## The Problem

Reminder-based hooks ("hey, you should save") get ignored under pressure. The bot keeps working, forgets to save, hits context limits, and loses everything since the last save. This happened repeatedly in production.

## The Solution

Two invariants enforced by a PreToolUse hook:

1. **ACK invariant**: When a new Telegram message arrives, the bot must update `## Active Conversation` in its state file before any substantive work. This ensures the bot acknowledges what was asked before diving into implementation.

2. **Counter invariant**: After 10 substantive tool calls without updating `## Active Conversation`, the gate blocks. This catches long-running tasks where the bot forgets to checkpoint.

## How It Works

```
New message arrives
  → UserPromptSubmit hook runs bot-gate.py --arm
  → Arms a marker with hash of current ## Active Conversation

Bot tries to call Edit, Bash, WebSearch, etc.
  → PreToolUse hook runs bot-gate.py --check
  → If marker is armed and ## Active Conversation hash hasn't changed → DENY
  → If counter >= 10 since last hash change → DENY
  → If tool is exempt (Read, Grep, etc.) → ALLOW always
  → If tool is editing the state file itself → ALLOW always (escape hatch)

Session ends
  → Stop hook runs bot-gate.py --stop-warn
  → Warns if marker is still live (bot never acknowledged the message)
```

## Files

- **bot-gate.py** — The gate script (Python). Handles all three modes.
- **gate-lists.sh** — Tool classification lists. Single source of truth for which tools are substantive vs exempt.

## Setup

1. Copy both files to `~/bin/` and `chmod +x`
2. Edit `BOT_WORKDIRS` and `STATE_FILENAMES` in `bot-gate.py` for your bots
3. Edit `gate-lists.sh` to add your MCP tool prefixes
4. Add hooks to your bot's `.claude/settings.local.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "command": "$HOME/bin/bot-gate.py mybot --arm",
        "timeout": 5000
      }
    ],
    "PreToolUse": [
      {
        "command": "$HOME/bin/bot-gate.py mybot --check",
        "timeout": 5000
      }
    ],
    "Stop": [
      {
        "command": "$HOME/bin/bot-gate.py mybot --stop-warn",
        "timeout": 5000
      }
    ]
  }
}
```

## Design Decisions

- **Fail-open on internal errors** — if the hash helper breaks or flock times out, the gate allows the tool call rather than deadlocking the bot
- **Fail-closed on unclassified tools** — unknown tools are blocked with a clear message to update gate-lists.sh
- **flock serialization** — prevents race conditions between arm and check running in parallel hooks
- **Atomic file writes** — marker and counter files use write-to-tmp-then-rename to prevent corruption
- **Sentinel logging** — unusual events are logged for watchdog monitoring

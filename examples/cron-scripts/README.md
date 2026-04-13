# Cron Scripts — Scheduled One-Shot Tasks

Run `claude -p` tasks on a schedule without breaking your bot's state management.

## The Problem

If your bot uses a "bot-gate" hook that requires an `## Active Conversation` section before allowing tool calls, cron one-shots (`claude -p`) will fail on their first tool call because no AC section exists yet.

Additionally, when `claude -p` finishes, the Stop hook fires `death-rattle.sh`, which sends a "session ended" notification — even though the session ending is completely expected for a cron task.

## The Solution

### cron-ac-preseed.sh

A sourceable shell library that:
1. **Pre-seeds** a minimal `## Active Conversation` section in the state file before `claude -p` runs
2. **Sets `CLAUDE_CRON=1`** so `death-rattle.sh` suppresses the "session ended" notification
3. **Marks complete** after the task finishes, so the interactive bot doesn't see stale AC state
4. Uses **flock + atomic rename** to avoid races with the interactive bot

### Usage

```bash
#!/usr/bin/env bash
source ~/bin/cron-ac-preseed.sh

STATE_FILE="$HOME/MyProject/mybot-state.md"

# Pre-seed AC section and set CLAUDE_CRON=1
cron_ac_preseed "$STATE_FILE" "Daily briefing"

# Run the one-shot task
RESULT=$(claude -p "Generate the daily briefing for today")

# Send results somewhere (e.g., Telegram)
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${RESULT}"

# Mark the AC section as completed
cron_ac_complete "$STATE_FILE"
```

### scheduled-task-template.sh

A complete template for cron scripts with locking (`flock`), logging, and error handling.

## Design Decisions

- **Best-effort** — preseed/complete failures are logged but never abort the cron job
- **Race-safe** — flock prevents concurrent writes if the interactive bot and cron run simultaneously
- **Atomic writes** — temp file + rename prevents partial state file corruption
- **Cron signal** — `CLAUDE_CRON=1` env var is the handshake between cron-ac-preseed and death-rattle

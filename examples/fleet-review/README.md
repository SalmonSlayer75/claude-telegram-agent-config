# Fleet Review — Automated Daily Health Report

Automated daily health review that gathers logs, errors, and health data from all bots in the fleet, feeds it to Claude for analysis, and sends a prioritized Telegram report.

## What It Checks

| Data Source | What It Captures |
|---|---|
| Watchdog log | Bot restarts (baked, stale connection, crash) |
| Bot-gate sentinel logs | Blocked tool calls, AC malformed errors |
| Tmux session status | Which bots are up/down right now |
| State file freshness | How recently each bot updated its state |
| Cron error scan | Failures across all cron job log files |
| Heartbeat file ages | Per-bot heartbeat freshness |

## Output Format

The report is structured as:

1. **Fleet Status** — one line per bot (up/down, last restart reason)
2. **Issues Found** — ranked by severity (P0/P1/P2)
3. **Patterns** — recurring problems across the fleet
4. **Recommendations** — specific, actionable improvements

## Configuration

Edit the `BOTS` array in the script to match your fleet:

```bash
BOTS=(
    "name:tmux-socket:tmux-session:state-file-path"
    ...
)
```

Also configure `LOG_DIRS`, `WATCHDOG_LOG`, `BOTGATE_PATTERN`, and `HEARTBEAT_DIR` at the top of the script.

## Installation

```bash
# Copy to your bin directory
cp fleet-review.sh ~/bin/
chmod +x ~/bin/fleet-review.sh

# Add to crontab (daily at 5:30am)
crontab -e
# 30 5 * * * ~/bin/fleet-review.sh >> ~/.claude/channels/fleet-review.log 2>&1
```

## Design Notes

- **`set -uo pipefail` without `-e`**: `grep` returns exit code 1 when it finds no matches. With `set -e`, this kills the script silently. We use `|| true` on individual grep calls instead.
- **Runs `claude -p` from `/tmp`**: Avoids triggering project-specific hooks (like bot-gate) that would interfere with the one-shot analysis.
- **Uses `flock`** to prevent overlapping runs if the previous invocation is still analyzing.
- **Cron AC preseed**: Pre-seeds the Active Conversation section in the operator's state file so bot-gate doesn't block the one-shot session.
- **Model choice**: Uses Sonnet with max-turns 5 — the analysis is straightforward text summarization, doesn't need Opus or many turns.

## Dependencies

- `cron-ac-preseed.sh` (see `../cron-scripts/`)
- `bot-credentials.env` with Telegram bot token and chat ID
- `claude` CLI with `-p` (pipe/prompt) mode
- Bots running in tmux sessions with per-bot sockets (see `../watchdog/`)

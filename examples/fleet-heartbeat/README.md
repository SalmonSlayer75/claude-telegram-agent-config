# Fleet Heartbeat — Dead-Man's-Switch Monitor

Watches the watcher. Verifies the watchdog is running and all bot tmux sessions are alive. Fires Telegram alerts with per-failure suppression to avoid spam.

## How It Works

1. **Watchdog check** — Verifies the watchdog's tick file (touched every run) was updated within 15 minutes
2. **Per-bot check** — Verifies each bot's tmux session exists, with a 60-second grace period for restarts
3. **Alert suppression** — Same failure key won't re-alert for 30 minutes
4. **Recovery clearing** — When a condition recovers, its suppression file is removed

## Setup

Run via cron every 5 minutes:
```cron
*/5 * * * * $HOME/bin/fleet-heartbeat-check.sh >> /dev/null 2>&1
```

Configure the `BOTS`, `BOT_SOCKET`, and `BOT_SESSION` arrays for your fleet.

Requires `lib/page-telegram.sh` for validated Telegram sending.

# Death Rattle — Session Death Notification

Sends a Telegram message when a bot's session is about to die, so the user knows immediately instead of discovering it minutes later.

## The Problem

When a bot hits context limits, the session silently ends. The user messages the bot, gets no reply, and only discovers the problem after checking manually. Meanwhile, work is interrupted and the user has no idea what the bot was working on.

## The Solution

PreCompact and Stop hooks that send a Telegram notification with what the bot was working on.

### What the user sees

**On context compaction:**
```
Warning: MYBOT — context compacting, may lose thread
Working on: deploying new API endpoint, running integration tests...
```

**On session end:**
```
MYBOT session ended
Was working on: deploying new API endpoint, running integration tests...
State saved — will resume on restart.
```

## Noise Suppression

Stop-mode notifications have two suppression layers to avoid spam:

1. **Idle bots** — If the `## Active Conversation` status isn't `in-progress`, the notification is skipped. Most sessions end naturally when no work is happening, and the user doesn't need to know about those.

2. **Cron one-shots** — If `CLAUDE_CRON=1` is set in the environment (by `cron-ac-preseed.sh`), the notification is skipped. Cron jobs run `claude -p` for short tasks, and the session ending afterwards is expected behavior, not a crash.

## How It Works

The script reads the bot's state file (specifically the `## Active Conversation` section) and extracts a summary of what was being worked on. Then it sends a Telegram message via the bot's token.

- **PreCompact mode**: Fires when context is about to be compacted. The session may survive, but the thread might be lost.
- **Stop mode**: Fires when the session is ending. The bot is going down. Suppressed for idle bots and cron one-shots.

## Setup

1. Copy `death-rattle.sh` to `~/bin/` and `chmod +x`
2. Edit the `BOT_TOKENS` and `BOT_STATES` maps for your fleet
3. Add hooks to your bot's `.claude/settings.local.json`:

```json
{
  "hooks": {
    "PreCompact": [
      {
        "matcher": ".*",
        "hooks": [{
          "type": "command",
          "command": "$HOME/bin/death-rattle.sh mybot compact"
        }]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "$HOME/bin/death-rattle.sh mybot stop"
        }]
      }
    ]
  }
}
```

## Design Decisions

- **Zero context cost** — runs in shell hooks, completely outside the conversation
- **Best effort** — curl failures are silently ignored (never blocks the session)
- **First 200 chars only** — avoids Telegram message length issues
- **Works with any state file** — just needs a `## Active Conversation` section
- **Two-layer suppression** — prevents notification spam from idle sessions and cron jobs

# Follow-Up Gate — Background Task Reminder

Prevents bots from forgetting to report results of background tasks they kicked off.

## The Problem

Bots say "I'll report back in ~15 minutes" then never do. Even when the session is alive and the background task finishes, the bot gets distracted by the next message and forgets to check. The user has to manually follow up.

## The Solution

Two parts working together:

### 1. CLAUDE.md Instructions
Tell bots to register follow-ups when they kick off background tasks:

```markdown
## Long-Running Tasks — MANDATORY
Commands over 60 seconds MUST run in background:
\`\`\`bash
nohup npm run test:e2e > /tmp/test-output.txt 2>&1 &
\`\`\`

Register a follow-up so you don't forget:
\`\`\`bash
echo "## task-$(date +%s)
- **Output:** /tmp/test-output.txt
- **Status:** pending" >> ~/MyProject/pending-followups.md
\`\`\`
After reporting results, delete the entry from `pending-followups.md`.
```

### 2. PreToolUse Hook
Before every Telegram reply, the hook checks `pending-followups.md`. If any registered output files now have content (meaning the background task finished), it injects a reminder:

```
[FOLLOWUP REMINDER] You have 1 background task(s) with results ready.
Check the output files and report results to the user BEFORE doing other work:
- Background task output ready: /tmp/test-output.txt
```

## How It Works

```
Bot kicks off background task
  → Writes entry to pending-followups.md with output file path
  → Background task runs, writes output to file

Next Telegram reply
  → PreToolUse hook runs followup-gate.sh
  → Checks each pending entry: does the output file exist and have content?
  → If yes: injects reminder into context
  → Bot reads the output file and reports results

Bot reports results
  → Deletes entry from pending-followups.md
```

## Setup

1. Copy `followup-gate.sh` to `~/bin/` and `chmod +x`
2. Edit `BOT_WORKDIRS` for your fleet
3. Add the CLAUDE.md instructions above to your bot's persona
4. Add the hook to `.claude/settings.local.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "mcp__telegram__reply",
        "hooks": [{
          "type": "command",
          "command": "$HOME/bin/followup-gate.sh mybot"
        }]
      }
    ]
  }
}
```

## Design Decisions

- **Advisory, not blocking** — injects a reminder but doesn't hard-deny the reply. The bot should report results, but blocking it from replying at all would be worse.
- **File-based detection** — checks if the output file exists and has content, rather than timing out on a clock. This means the reminder only fires when results are actually ready.
- **Bot registers explicitly** — rather than trying to parse natural language promises, the bot writes a structured entry. This is reliable and simple.
- **Zero overhead when no follow-ups** — if `pending-followups.md` doesn't exist, the hook exits immediately.

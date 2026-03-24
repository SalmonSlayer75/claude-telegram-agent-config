# Extensions to the Claude Code Telegram Agent Setup

> **Context**: Peter's original guide gets you a working 24/7 Telegram agent. This doc covers what we added on top of that to solve real problems we hit running two bots (COS + VPE) in production for several weeks. These are battle-tested additions — each one exists because something broke without it.

---

## Problem #1: The Bot Forgets Everything After Restart

### What happens

Claude Code channel sessions have a finite context window. When the conversation fills up, the session ends ("bakes") and the bot goes idle. When it restarts (manually or via systemd), it's a completely fresh conversation. Anything discussed in the previous session — action items, decisions, pending tasks, context from the user — is gone.

The original guide mentions CLAUDE.md for personality/instructions, but CLAUDE.md is static. It doesn't capture the dynamic state of "what were we just working on?"

### What we tried first (didn't work reliably)

Added instructions to CLAUDE.md telling the bot to save context to a `conversation-log.md` file "at the end of each meaningful interaction." Problem: the bot often hits context limit unexpectedly and the session dies before it gets a chance to write. The instruction was too passive — it relied on the bot remembering to do something before an event it can't predict.

### What we do now: Structured State File + Hooks

#### 1. State file (the bot's working memory)

Each bot gets a structured state file that serves as persistent working memory across session restarts. This replaces freeform conversation logs.

**COS example** (`~/ChiefOfStaff/cos-state.md`):
```markdown
# COS State
<!-- Auto-updated by COS after every substantive interaction. Read this at conversation start. -->
<!-- Last updated: 2026-03-24T09:00Z -->

## Open Threads
<!-- Active conversations or tasks in progress. Remove when resolved. -->

## Pending Action Items
<!-- Format: - [ ] [item] | owner: [who] | due: [date] | source: [where it came from] -->

## Recent Decisions (last 7 days)
<!-- Format: - [decision] (YYYY-MM-DD) -->

## Waiting On Human
<!-- Things the bot needs human input on before proceeding -->

## Context Carry-Forward
<!-- Important context from recent conversations that would be lost on restart -->
```

**VPE example** (`~/Projects/vpe-state.md`) — same structure but with engineering-specific sections:
```markdown
## Pending Reviews
<!-- PRs or plans awaiting VPE review -->

## Active Issues
<!-- High-priority issues being tracked -->
```

The sections are designed so the bot can quickly scan "what's hot" at conversation start, and update incrementally after each interaction.

#### 2. CLAUDE.md instructions (aggressive, not passive)

The original approach said "save context at the end of each interaction." We changed this to be much more urgent:

```markdown
- **CRITICAL — Maintain state across restarts:** Your conversation WILL end unexpectedly
  (context limit, crash, restart). You WILL lose everything in your conversation history.
  The ONLY thing that survives is what you write to disk. To compensate:
  - **Read `~/ChiefOfStaff/cos-state.md` at the START of every conversation**
  - **Update it IMMEDIATELY after every substantive interaction** — do NOT wait until
    session end, because session end may never come
  - After every Telegram exchange where something was decided, requested, or committed to:
    update the state file RIGHT THEN
  - Prune "Recent Decisions" older than 7 days; prune "Context Carry-Forward" older than 3 days
```

Key differences from the original:
- **"WILL end unexpectedly"** not "may lose memory" — urgency matters for LLM instruction-following
- **"IMMEDIATELY after"** not "at the end of" — the bot writes state after each exchange, not at session end
- **Explicit pruning rules** — prevents the file from growing unbounded

#### 3. Hooks (the automated nudge)

Instructions alone aren't enough — the bot can still forget. We use Claude Code hooks to inject reminders at the system level, outside the bot's conversation flow.

In each project's `.claude/settings.local.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "mcp__plugin_telegram_telegram__reply",
        "hooks": [
          {
            "type": "command",
            "command": "if [ ! -f /tmp/cos-state-loaded ]; then echo '[STARTUP] Read ~/ChiefOfStaff/cos-state.md FIRST to restore your working memory before replying.'; touch /tmp/cos-state-loaded; fi"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "mcp__plugin_telegram_telegram__reply",
        "hooks": [
          {
            "type": "command",
            "command": "echo '[STATE REMINDER] You just sent a Telegram reply. If this interaction involved any decisions, action items, commitments, or important context — update ~/ChiefOfStaff/cos-state.md NOW before doing anything else.'"
          }
        ]
      }
    ]
  }
}
```

**How this works:**
- **PreToolUse** fires before the bot sends a Telegram reply. On the first reply of a new session (detected via `/tmp/` flag file), it tells the bot to read its state file first. This catches the "new session, blank slate" moment.
- **PostToolUse** fires after every Telegram reply. It reminds the bot to update state. Every. Single. Time. This is the key insight borrowed from OpenClaw's approach — don't rely on the bot to remember, remind it mechanically.

The `/tmp/cos-state-loaded` flag file resets on reboot (since `/tmp` is cleared), so the startup reminder fires again after each restart.

---

## Problem #2: Cron Jobs (Scheduled One-Shot Tasks)

### What the original guide doesn't cover

The original guide sets up an always-on channel bot. But we also needed the bots to do things on a schedule — morning briefings, email checks, weekly research sweeps — without the human asking.

### What we do: Cron scripts that run separate Claude one-shots

Each scheduled task is a bash script that:
1. Runs `claude -p` (one-shot prompt mode, not channel mode) with the relevant MCP config
2. Sends results to Telegram via the Bot API directly (curl, not through the channel)
3. Logs output to a dedicated log file

**Example** (`~/bin/cos-check-email.sh`):
```bash
#!/usr/bin/env bash
export PATH="..."
export HOME="/home/youruser"

BOT_TOKEN="<token>"
CHAT_ID="<user-id>"

send_telegram() {
  local text="$1"
  if [ ${#text} -gt 4000 ]; then
    text="${text:0:3997}..."
  fi
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d text="${text}" \
    -d parse_mode="Markdown" \
    > /dev/null 2>&1
}

# Run Claude one-shot with the task prompt
RESULT=$(cd ~/ChiefOfStaff && claude -p \
  --mcp-config .mcp.json \
  --permission-mode dontAsk \
  "Check email and calendar. Summarize anything new." 2>&1)

# Send result to Telegram
if [ -n "$RESULT" ]; then
  send_telegram "$RESULT"
fi
```

**Crontab** (`crontab -e`):
```cron
# COS Morning Brief — daily 7am
0 7 * * * ~/bin/cos-morning-brief.sh >> ~/.claude/channels/cos-morning.log 2>&1

# COS Email Check — every 15 min, 7am-10pm
*/15 7-22 * * * ~/bin/cos-check-email.sh >> ~/.claude/channels/cos-check.log 2>&1

# VPE Daily Status — daily 8am
0 8 * * * ~/bin/vpe-daily-status.sh >> ~/.claude/channels/vpe-daily.log 2>&1

# VPE PR Watcher — every 30 min, 8am-10pm
*/30 8-22 * * * ~/bin/vpe-pr-watch.sh >> ~/.claude/channels/vpe-pr-watch.log 2>&1
```

**Important**: Cron scripts use `claude -p` (one-shot), NOT the channel bot. They're completely independent processes. The channel bot stays running for interactive messages; cron scripts fire and exit. They share the same bot token for sending Telegram messages, but they don't interfere with each other.

**Gotcha**: Don't use `--channels` in cron scripts — that would try to start another channel listener and steal messages from the main bot.

---

## Problem #3: Multi-Directory Access

### What the original guide mentions briefly

The guide mentions `--add-dir` as a footnote in troubleshooting. For us it's essential.

### What we do

The VPE bot needs to see multiple codebases. Its start script uses `--add-dir` to grant access beyond the working directory:

```bash
cd ~/Projects
exec claude --channels plugin:telegram@claude-plugins-official \
  --add-dir ~/AnnasPath \
  --add-dir "~/other-project"
```

This lets VPE review code across both projects from a single bot. The working directory (`~/Projects`) contains the VPE's CLAUDE.md and state file, while `--add-dir` grants read/write access to the actual codebases.

COS also uses `--add-dir` for cross-referencing project status when briefing the human:

```bash
cd ~/ChiefOfStaff
exec claude --channels plugin:telegram@claude-plugins-official \
  --add-dir ~/Projects \
  --add-dir ~/AnnasPath
```

**Rule of thumb**: The working directory is where the bot's identity lives (CLAUDE.md, state file, settings). `--add-dir` is for everything else it needs to read or write.

---

## Problem #4: Role Isolation Between Bots

### What the original guide suggests

The guide treats multiple bots as "work vs personal" — different contexts but no interaction.

### What we needed

Two bots with distinct professional roles (COS = Chief of Staff, VPE = VP Engineering) that need to stay in their lanes but occasionally reference each other's work.

### What we do

Each bot's CLAUDE.md explicitly defines:
- **What it owns** — COS owns email/calendar/research/admin; VPE owns code/PRs/architecture/CI
- **What it must NOT do** — COS must not generate engineering reports; VPE must not manage email
- **How to redirect** — "That's VPE's area — check with @your_engineering_bot"
- **How they coordinate** — Through written artifacts (Notion, files, GitHub Issues), not shared memory

```markdown
## Other Bots
- **VPE Bot** (@your_engineering_bot) — handles technical decisions, code review, architecture
- You and VPE do NOT share memory or context. Coordinate through written documentation.

**IMPORTANT — Stay in your lane:**
- DO NOT generate engineering status reports — that is VPE's job
- When you see engineering emails, note them as "Engineering — VPE tracking" and move on
- If the human asks an engineering question: "That's VPE's area — check with @your_engineering_bot"
```

This prevents the bots from producing conflicting or duplicate information.

---

## Problem #5: Bot Reports "RUNNING" But Is Actually Dead

### What happens

The management script (`claude-bot status`) checks if the tmux session exists. But after a bot "bakes" (hits context limit), the tmux session is still alive — claude is sitting at an empty prompt, not listening for messages. `status` says RUNNING, but the bot is deaf.

This is exactly the failure mode we hit: COS showed as RUNNING, but the human's messages went unanswered for hours.

### What we do: Watchdog cron job with pane inspection

A script (`~/bin/claude-bot-watchdog.sh`) runs every 5 minutes and checks what's actually on screen in each bot's tmux pane:

- If it sees **"Listening for channel messages"** → bot is healthy, do nothing
- If it sees **"Baked for"** → conversation ended, restart the bot
- If the **tmux session doesn't exist** → bot crashed entirely, start it fresh
- If **neither pattern matches** → bot is mid-conversation processing a message, leave it alone

```bash
#!/usr/bin/env bash
set -euo pipefail

# ...setup...

check_and_restart() {
    local name="$1"
    # ...variable setup...

    # Check if tmux session exists at all
    if ! tmux -L "$socket" has-session -t "$session" 2>/dev/null; then
        log "[$name] tmux session not found — starting bot"
        tmux -L "$socket" new-session -d -s "$session" "$script"
        send_telegram "$token" "🔄 *${name^^} bot was down* — watchdog restarted it."
        return
    fi

    # Capture the tmux pane and check for active listening
    local pane_content
    pane_content=$(tmux -L "$socket" capture-pane -t "$session" -p -S -50 2>&1)

    if echo "$pane_content" | grep -q "Listening for channel messages"; then
        return 0  # Healthy
    fi

    if echo "$pane_content" | grep -q "Baked for"; then
        log "[$name] conversation baked — restarting"
        tmux -L "$socket" send-keys -t "$session" C-c
        sleep 2
        tmux -L "$socket" kill-session -t "$session" 2>/dev/null || true
        sleep 1
        rm -f "/tmp/${name}-state-loaded"  # Reset PreToolUse hook flag
        tmux -L "$socket" new-session -d -s "$session" "$script"
        send_telegram "$token" "🔄 *${name^^} bot hit context limit* — watchdog restarted it. State file preserved."
        return
    fi

    # Neither pattern = bot is mid-conversation, leave it alone
}
```

**Cron entry** (every 5 minutes, 24/7):
```cron
*/5 * * * * ~/bin/claude-bot-watchdog.sh all >> ~/.claude/channels/watchdog.log 2>&1
```

**Key details:**
- The watchdog sends a Telegram notification when it restarts a bot, so you know it happened
- It clears the `/tmp/${name}-state-loaded` flag, which triggers the PreToolUse hook to remind the new session to read its state file
- It logs all actions to `~/.claude/channels/watchdog.log`
- The 5-minute interval means worst case, a baked bot is unresponsive for 5 minutes before auto-recovery
- It's safe to run — if the bot is healthy or mid-conversation, the watchdog does nothing

This is the single biggest improvement for reliability. Before the watchdog, a baked bot could sit dead for hours until someone noticed.

---

## Problem #6: WSL-Specific Issues

### What the original guide assumes

Native Linux with systemd. Clean boot sequence.

### What we deal with

WSL2 on Windows. systemd works but WSL doesn't "boot" in the traditional sense — it starts when you open a WSL terminal or when Windows triggers it.

### What we do

- **systemd services** for the bots (same as the original guide)
- **Windows Scheduled Task** that runs on Windows login to ensure WSL starts and the bots come up
- **`loginctl enable-linger`** to keep services running after terminal close (same as original guide, but even more critical in WSL where sessions are more transient)

---

## Summary of Additions

| Addition | What it solves | Files involved |
|----------|---------------|----------------|
| Structured state file | Bot loses context across restarts | `cos-state.md`, `vpe-state.md` |
| Aggressive CLAUDE.md instructions | Bot doesn't save state reliably | `CLAUDE.md` (both projects) |
| PreToolUse hook | Bot doesn't read state on new session | `.claude/settings.local.json` |
| PostToolUse hook | Bot forgets to update state after interactions | `.claude/settings.local.json` |
| Watchdog cron | Bot appears "RUNNING" but is actually dead | `~/bin/claude-bot-watchdog.sh`, crontab |
| Cron one-shot scripts | Scheduled tasks (briefings, email checks, PR monitoring) | `~/bin/cos-*.sh`, `~/bin/vpe-*.sh` |
| `--add-dir` for multi-codebase | Bot needs access beyond working directory | Start scripts (both bots) |
| Role isolation in CLAUDE.md | Two bots producing conflicting information | `CLAUDE.md` (both projects) |
| WSL auto-start | Bots don't survive Windows reboot | Windows Scheduled Task |

---

## Recommendation for Peter

### Priority 1: Watchdog (5 min to set up, biggest reliability win)

If you do nothing else, add the watchdog. Without it, a baked bot sits dead until you manually notice and restart it. With it, max downtime is 5 minutes. The watchdog inspects the tmux pane for "Listening for channel messages" vs "Baked for" and auto-restarts when needed, with a Telegram notification so you know it happened.

### Priority 2: State file + hooks (OpenClaw-style memory)

If your bots run long enough to hit context limits (and they will), they lose everything from the prior session. The state file + hook pattern gives you OpenClaw-style memory persistence without needing OpenClaw. It's three files:

1. A structured markdown state file (the bot's working memory)
2. A CLAUDE.md section telling the bot to read/write it aggressively
3. Hook config in `settings.local.json` that nudges the bot after every Telegram reply

### Priority 3: Cron one-shots (proactive behavior)

If you want the bot to do things on a schedule (morning briefings, email checks, monitoring) without waiting for a message, cron scripts running `claude -p` (one-shot mode) are the way. They're completely independent of the channel bot — separate processes that fire and exit.

### Priority 4: `--add-dir` and role isolation

These matter once you have multiple bots or a bot that needs access to files outside its working directory. Not critical for a single-bot setup, but essential as complexity grows.

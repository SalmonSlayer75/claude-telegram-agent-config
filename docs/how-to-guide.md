# How to Build Your Own AI Agent Team

A step-by-step guide for non-engineers who want to run a team of Claude Code bots on Telegram. This guide explains not just *what* to do, but *why* each piece exists — so you can make smart decisions about what to customize for your setup.

**Who this is for**: Product managers, founders, operators — anyone who's comfortable with a terminal but doesn't write code for a living. If you can copy-paste commands and edit text files, you can do this.

**What you'll build**: Two bots that run 24/7 on a Linux machine (or WSL on Windows), reachable from your phone via Telegram. A **Chief of Staff** that handles email, calendar, research, and admin. And a **Product Marketing** agent that handles market research, content, and thought leadership. They'll remember what they're working on across restarts, do things proactively on a schedule, and coordinate with each other.

**Time estimate**: 2-3 hours for the full setup. The first bot takes longest; the second one goes faster because you're repeating the pattern.

---

## Table of Contents

**Part 1: Core Fleet (COS + Marketing)**
1. [How It Works (The Big Picture)](#1-how-it-works-the-big-picture)
2. [Prerequisites](#2-prerequisites)
3. [Create Your Telegram Bots](#3-create-your-telegram-bots)
4. [Set Up Your Server](#4-set-up-your-server)
5. [Build Your First Bot: Chief of Staff](#5-build-your-first-bot-chief-of-staff)
6. [Make It Remember Things (State + Hooks)](#6-make-it-remember-things-state--hooks)
7. [Keep It Alive (Watchdog + Auto-Start)](#7-keep-it-alive-watchdog--auto-start)
8. [Give It a Schedule (Cron Jobs)](#8-give-it-a-schedule-cron-jobs)
9. [Add Long-Term Memory (Memory Search)](#9-add-long-term-memory-memory-search)
10. [Build Your Second Bot: Product Marketing](#10-build-your-second-bot-product-marketing)
11. [Connect the Bots (Inter-Agent Inbox)](#11-connect-the-bots-inter-agent-inbox)
12. [Add the Management CLI](#12-add-the-management-cli)

**Part 2: Engineering Appendix**
- [A. Add a CTO Bot](#a-add-a-cto-bot)
- [B. Add VP Engineering Bots](#b-add-vp-engineering-bots)
- [C. Agent Skills (Slash Commands)](#c-agent-skills-slash-commands)
- [D. Fleet Hook Automation](#d-fleet-hook-automation)

**Part 3: Platform Appendix**
- [E. Running on a Mac Mini](#e-running-on-a-mac-mini)

---

# Part 1: Core Fleet

## 1. How It Works (The Big Picture)

Here's the mental model:

**Each bot is a separate Claude Code session** running in the background on your machine. It listens for Telegram messages, processes them with full access to files and tools, and replies. That's it.

The complexity comes from making this *reliable*:

- **The bot forgets everything when it restarts.** Claude Code has a context window. When it fills up, the session ends. Solution: a state file that the bot reads on startup and writes to after every interaction.

- **The bot doesn't know it should do things on a schedule.** The channel bot just listens for messages. Solution: separate cron scripts that run Claude as a one-shot command and send results to Telegram.

- **The bot can silently die.** The tmux session stays open but Claude is idle. Solution: a watchdog that checks every 5 minutes and restarts dead bots.

- **Multiple bots will step on each other's toes.** If both bots can see your email, both will try to manage it. Solution: explicit role boundaries in each bot's CLAUDE.md file.

### Why separate bots instead of one super-bot?

We tried one bot first. It broke down because:

1. **Context limits**: One bot doing everything fills its context window faster and forgets things sooner.
2. **Role confusion**: When one bot handles email AND research AND code review, it gets confused about priorities and drops tasks.
3. **Blast radius**: When one bot crashes, everything is down. With separate bots, COS going down doesn't affect your marketing research.
4. **Specialization**: Each bot's CLAUDE.md can be tuned for its specific role. A marketing bot gets different instructions than an admin bot.

Start with two bots. You can always add more later.

---

## 2. Prerequisites

You need:

- **A Linux machine that stays on** — this could be a cloud VPS ($5-20/month on DigitalOcean, Hetzner, etc.), a spare computer at home, or WSL2 on a Windows machine that stays powered on. The bots need to be running 24/7 to receive your messages.

- **Claude Code CLI** installed and authenticated. Run `claude` in a terminal to verify. If you don't have it, see [claude.ai/code](https://claude.ai/code).

- **Claude Max or Team subscription** — the bots use your account's API quota. This is NOT the API (pay-per-token) — it uses your subscription.

- **Telegram** on your phone — this is how you'll talk to the bots. It's free.

- **tmux** — a terminal multiplexer that keeps processes running after you close your terminal. Install with `sudo apt install tmux`.

### What integrations do you want?

Before starting, think about what you want your COS bot to access:

| Integration | What it gives you | How to set up |
|-------------|-------------------|---------------|
| **Google Workspace** (Gmail, Calendar, Drive) | Email management, calendar scheduling, file storage | Google Workspace MCP server (recommended) or Google APIs |
| **Notion** | Task tracking, knowledge base, meeting notes | Notion MCP server |
| **Google Docs** | Alternative to Notion for docs and task tracking | Included with Google Workspace MCP |
| **Linear / Jira** | Issue tracking (if you use it) | Linear or Jira MCP server |
| **Slack** | Team communication | Slack MCP server |
| **Web search** | Research, fact-checking | Built into Claude Code |

**You don't need all of these on day one.** Start with the basics (Telegram + web search) and add integrations later. Each one is just an MCP config entry.

> **Notion vs Google Docs**: Both work. Notion is better for structured data (databases, kanban boards, linked references). Google Docs is better if your team already lives in Google Workspace and you want fewer tools. We use Notion for task tracking and Google Docs for long-form content, but pick what your team already uses.

---

## 3. Create Your Telegram Bots

This is the only step you do on your phone.

**For each bot** (you'll need two — COS and Marketing):

1. Open Telegram, search for `@BotFather`, start a chat
2. Send `/newbot`
3. Pick a display name (e.g., "My Chief of Staff" and "My Marketing Bot")
4. Pick a username (must end in `bot`, e.g., `myname_cos_bot` and `myname_mktg_bot`)
5. **Save the token** BotFather gives you — it looks like `1234567890:AAxx-xxxxxxxxxxxxxxxxxxxxxxxxxxxxx`

Also, get your Telegram user ID:
1. Message `@userinfobot` on Telegram
2. It replies with your numeric ID (e.g., `1234567890`)
3. Save this — it's your allowlist identifier

> **Why allowlists matter**: Without access control, anyone who guesses your bot's username can send it commands. The allowlist ensures only your Telegram account can talk to your bots. This is a security boundary, not a convenience feature.

---

## 4. Set Up Your Server

### Install dependencies

```bash
# tmux for background sessions
sudo apt install tmux

# Bun (required by the Telegram plugin)
curl -fsSL https://bun.sh/install | bash
```

### Enable the Telegram plugin

Edit `~/.claude/settings.json` (create it if it doesn't exist):

```json
{
  "enabledPlugins": {
    "telegram@claude-plugins-official": true
  }
}
```

If the file already has content, just add the `enabledPlugins` key — don't overwrite.

### Create the directory structure

```bash
# Working directories for each bot
mkdir -p ~/COS          # Chief of Staff
mkdir -p ~/Marketing    # Product Marketing

# Shared utilities
mkdir -p ~/bin

# Telegram state directories (one per bot — this is how they get separate identities)
mkdir -p ~/.claude/channels/telegram-cos
mkdir -p ~/.claude/channels/telegram-marketing
```

> **Why separate directories?** Each bot needs its own working directory because that's where Claude reads its `CLAUDE.md` instructions, state file, and hooks. The working directory IS the bot's identity — change it and you change the bot's personality and capabilities.

### Save bot tokens

Using the tokens from Step 3:

```bash
# COS bot token
echo 'TELEGRAM_BOT_TOKEN=<paste-your-cos-token>' > ~/.claude/channels/telegram-cos/.env
chmod 600 ~/.claude/channels/telegram-cos/.env

# Marketing bot token
echo 'TELEGRAM_BOT_TOKEN=<paste-your-marketing-token>' > ~/.claude/channels/telegram-marketing/.env
chmod 600 ~/.claude/channels/telegram-marketing/.env
```

> **Why `chmod 600`?** This makes the file readable only by your user account. Bot tokens are like passwords — if someone gets yours, they can impersonate your bot.

### Set up access control

Using your Telegram user ID from Step 3:

```bash
# COS access control
cat > ~/.claude/channels/telegram-cos/access.json << 'EOF'
{
  "dmPolicy": "allowlist",
  "allowFrom": ["<your-telegram-user-id>"],
  "groups": {},
  "pending": {}
}
EOF

# Marketing access control (same content, separate file)
cp ~/.claude/channels/telegram-cos/access.json ~/.claude/channels/telegram-marketing/access.json
```

Replace `<your-telegram-user-id>` with the actual number from `@userinfobot`.

---

## 5. Build Your First Bot: Chief of Staff

Each bot needs four things: a **persona** (CLAUDE.md), a **state file**, **hooks** (automated behaviors), and a **start script**.

### 5a. Write the persona (CLAUDE.md)

This is the most important file. It tells Claude who it is, what it owns, and how to behave. Create `~/COS/CLAUDE.md`:

```markdown
# Chief of Staff

You are my Chief of Staff — a senior executive assistant who manages my admin, communications, and schedule. You're proactive, concise, and organized.

## Your Role
- Manage email triage and drafting (flag urgent items, draft responses, summarize threads)
- Manage calendar (schedule meetings, flag conflicts, prep briefs)
- Research topics when asked (market analysis, competitor research, fact-checking)
- Track action items and follow-ups
- Maintain my task list and remind me of deadlines

## How to Communicate
- Lead with what I need to know, not how you found it
- Flag items by urgency: P0 (needs attention now), P1 (today), P2 (this week)
- Keep Telegram messages short — save detail for docs/notes
- If you're unsure about something, ask rather than guess

## What You Don't Do
- You do NOT write code, review PRs, or manage engineering tasks
- You do NOT create marketing content or run campaigns
- If I ask about engineering: "That's outside my area — you may want to check with your engineering team"
- If I ask about marketing strategy: "That's outside my area — you may want to check with your marketing team"

## State Management — CRITICAL
Your conversation WILL end unexpectedly. The ONLY thing that survives is what you write to disk.
- Read `~/COS/cos-state.md` at the START of every conversation
- Update it IMMEDIATELY after every substantive interaction — do NOT wait
- If it's not in your state file, it doesn't exist after a restart
```

> **Why the role boundaries?** Without them, the bot will try to do everything. When you add more bots later, clear boundaries prevent them from giving you conflicting answers about the same topic. The COS doesn't need to know about code; the marketing bot doesn't need to manage your calendar.

> **Customize this for your needs.** If you don't use Notion, remove Notion references. If you want the COS to handle Slack messages, add that to its role. This is YOUR assistant — make it match how you work.

### 5b. Add integrations (MCP config)

If you're using Google Workspace, Notion, or other MCP tools, create `~/COS/.mcp.json`:

```json
{
  "mcpServers": {
    "google-workspace": {
      "command": "npx",
      "args": ["-y", "@anthropic/google-workspace-mcp"]
    }
  }
}
```

> **Options for integrations:**
> - **Google Workspace MCP** gives you Gmail, Calendar, Drive, Docs, Sheets in one integration
> - **Notion MCP** gives you database queries, page creation, and search
> - **You can use both**, or neither — the bot works with just Telegram and web search
> - Add integrations later by editing this file — no need to get it perfect now

If you're not using any MCP integrations yet, skip this file. You can always add it later.

### 5c. Create the start script

Create `~/bin/claude-cos-bot-start.sh`:

```bash
#!/usr/bin/env bash

# PATH must include claude and bun locations.
# These are the most common locations — adjust if yours differ.
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
export HOME="/home/yourusername"    # <-- CHANGE THIS to your actual username

# This tells the Telegram plugin which token and allowlist to use.
# Each bot points to a different state directory = separate identity.
export TELEGRAM_STATE_DIR="$HOME/.claude/channels/telegram-cos"

# Kill any zombie Telegram pollers from crashed sessions.
# Without this, two processes might fight over the same bot token
# and you'd get split messages (some going to the old session, some to the new one).
TOKEN_PREFIX=$(head -c 10 "$TELEGRAM_STATE_DIR/.env" | grep -oP '\d+' | head -1)
if [ -n "$TOKEN_PREFIX" ]; then
    pkill -f "telegram.*${TOKEN_PREFIX}" 2>/dev/null || true
    sleep 1
fi

# The working directory determines which CLAUDE.md and hooks the bot reads.
cd ~/COS

exec claude --channels plugin:telegram@claude-plugins-official
```

Make it executable:
```bash
chmod +x ~/bin/claude-cos-bot-start.sh
```

> **Why kill zombie pollers?** When a bot crashes, the Telegram polling process sometimes keeps running. If you start a new bot session without killing the old poller, both processes receive messages from Telegram. You get broken conversations where some messages go to the dead session and others go to the new one. The `pkill` line prevents this.

### 5d. Test it

Before adding all the reliability layers, make sure the basic bot works:

```bash
# Run it in the foreground so you can see errors
~/bin/claude-cos-bot-start.sh
```

Open Telegram on your phone, message your COS bot, and verify you get a response. If it works, press `Ctrl+C` to stop it.

**Common issues:**
- `bun: not found` — Run `which bun` and add that directory to the PATH in the start script
- `claude: not found` — Same, run `which claude`
- No response on Telegram — Check the `.env` token and `access.json` user ID
- "Not authorized" — Your Telegram user ID in `access.json` might be wrong

---

## 6. Make It Remember Things (State + Hooks)

This is the biggest reliability win. Without this, the bot forgets everything every time its context window fills up (which happens every few hours of active use).

### 6a. Create the state file

Create `~/COS/cos-state.md`:

```markdown
# COS State
*Last updated: (will be auto-filled)*

## Active Action Items
- (bot will fill this in as you work together)

## Pending Follow-Ups
- (things the bot is waiting on)

## Recent Decisions
- (key decisions from recent conversations)

## Context Carry-Forward
- (important context that should survive restarts)
```

> **Why a markdown file?** Because Claude can read and write it natively. No database, no API, no special tooling. It's a file on disk that the bot edits with every interaction. When the bot restarts, it reads this file and picks up where it left off.

### 6b. Create the user profile

Create `~/COS/user-profile.md`:

```markdown
# User Profile
<!-- The bot updates this as it learns about you -->

## Basics
- Name: [your name]
- Role: [your role/title]
- Location: [your city/timezone]

## Preferences
- (bot will learn these over time — communication style, scheduling preferences, etc.)

## Key Relationships
- (people you work with frequently — the bot will learn names, roles, context)
```

> **Why a user profile?** Over weeks, the bot accumulates knowledge about you — your meeting preferences, your team members, your communication style. Without a persistent profile, it re-learns this every session. With it, the bot gets smarter over time.

### 6c. Set up hooks

Hooks are the mechanism that makes persistence actually work. They inject system-level messages that fire at specific points in the bot's lifecycle.

Create `~/COS/.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(*)"
    ],
    "deny": [
      "Bash(git push --force*)",
      "Bash(git reset --hard*)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~*)"
    ],
    "defaultMode": "dontAsk"
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "mcp__plugin_telegram_telegram__reply",
        "hooks": [
          {
            "type": "command",
            "command": "if [ ! -f /tmp/cos-state-loaded ]; then echo '[STARTUP] Read these files FIRST to restore your working memory: (1) ~/COS/cos-state.md (2) ~/COS/user-profile.md'; touch /tmp/cos-state-loaded; fi"
          }
        ]
      },
      {
        "matcher": "mcp__plugin_telegram_telegram__reply",
        "hooks": [
          {
            "type": "command",
            "command": "echo '[MANDATORY STATE SAVE] BEFORE sending this reply: Do you have ANY unsaved action items, decisions, or context from this conversation that are NOT yet in ~/COS/cos-state.md? If YES: STOP. Write them to your state file FIRST, THEN send this reply. Your conversation can end at any moment — if it is not in your state file, it is LOST. This is not optional.'"
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
            "command": "echo '[MANDATORY] You just sent a Telegram reply. Update ~/COS/cos-state.md NOW with any decisions, action items, or context from this exchange. Do NOT skip this — your conversation can reset at any moment and anything not in the state file will be permanently lost. Also update ~/COS/user-profile.md if you learned anything new about the user.'"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "echo '[PRE-COMPACTION] Context is about to be compacted. IMMEDIATELY: (1) Save all unsaved state to ~/COS/cos-state.md (2) Update ~/COS/user-profile.md with any new learnings. This is your LAST CHANCE to persist context.'"
          }
        ]
      }
    ],
    "PostCompact": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "echo '[POST-COMPACTION] Context was just compacted. Re-read: (1) ~/COS/cos-state.md (2) ~/COS/user-profile.md to restore your working memory.'"
          }
        ]
      }
    ]
  }
}
```

**Here's what each hook does and why:**

| Hook | When it fires | What it does | Why it matters |
|------|--------------|-------------|----------------|
| **PreToolUse (startup)** | Before the first Telegram reply of a new session | Tells the bot to read its state file | Without this, the bot starts fresh after every restart and has no idea what happened before |
| **PreToolUse (mandatory save)** | Before EVERY Telegram reply | Forces the bot to save state before it can respond | This is the critical one. We originally used gentle post-reply reminders, but bots ignored them under pressure. Gating the reply behind a save made persistence reliable. |
| **PostToolUse** | After EVERY Telegram reply | Tells the bot to save any new context from that exchange | Belt-and-suspenders with the pre-save. Catches anything the bot missed. |
| **PreCompact** | Right before Claude compacts its context window | Emergency "save everything NOW" signal | When context fills up, Claude compresses old messages. This hook gives the bot one last chance to persist important information. |
| **PostCompact** | Right after context compaction | Tells the bot to reload its state files | After compaction, the bot may have lost context. Reloading from state files restores its working memory. |

> **Why "mandatory" instead of "reminder"?** This is a lesson we learned the hard way. For weeks we used PostToolUse hooks that said "please update your state file." The bots would do it... sometimes. When conversations got complex, they'd skip the save, then crash, and lose everything. Changing from "please save" to "you MUST save before you can reply" was the single biggest reliability improvement we made.

> **Why `dontAsk` mode?** This prevents Claude from asking you for permission every time it runs a command. The bot runs 24/7 — you're not always watching. The deny list prevents dangerous operations (force-push, rm -rf) while allowing everything else.

---

## 7. Keep It Alive (Watchdog + Auto-Start)

### 7a. Set up the watchdog

The watchdog solves a subtle problem: the bot's tmux session is "running" but Claude has actually stopped responding. This happens when the context window fills up completely — Claude goes idle at the prompt, and the tmux session stays open looking healthy.

Copy [examples/watchdog/claude-bot-watchdog.sh](../examples/watchdog/claude-bot-watchdog.sh) to `~/bin/` and customize it for your bots. Then add it to crontab:

```bash
crontab -e
# Add this line:
*/5 * * * * ~/bin/claude-bot-watchdog.sh all >> ~/.claude/channels/watchdog.log 2>&1
```

> **How the watchdog works**: Every 5 minutes, it captures the last few lines of text visible in each bot's tmux window. If it sees "Baked for" or a long idle time, it kills and restarts the bot. If the bot is mid-conversation, the watchdog leaves it alone.

### 7b. Set up systemd auto-start

Without systemd, the bots die when your machine reboots and you have to start them manually.

```bash
mkdir -p ~/.config/systemd/user
```

Create `~/.config/systemd/user/claude-cos-bot.service`:

```ini
[Unit]
Description=Claude Code Telegram Bot - COS
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=forking
ExecStart=/usr/bin/tmux -L claude-cos new-session -d -s claude-cos-bot %h/bin/claude-cos-bot-start.sh
ExecStop=/usr/bin/tmux -L claude-cos kill-session -t claude-cos-bot
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

Enable it:

```bash
systemctl --user daemon-reload
systemctl --user enable claude-cos-bot.service
systemctl --user start claude-cos-bot.service

# CRITICAL: Without this, systemd kills your bots when you log out
loginctl enable-linger $USER
```

> **Why `Type=forking`?** The tmux command creates a background process and exits. Without `forking`, systemd thinks the service crashed immediately because the original process exited.

> **Why `enable-linger`?** By default, Linux kills all your background processes when you log out. `enable-linger` tells it to keep them running. Forget this and your bots die every time you close your SSH session.

---

## 8. Give It a Schedule (Cron Jobs)

The channel bot only responds to messages. For proactive behavior (morning briefings, email checks), you use separate cron scripts.

### How cron scripts work

Each cron script is independent from the channel bot:
1. It runs `claude -p` (one-shot mode) with a specific prompt
2. Claude executes the task (check email, generate a briefing, etc.)
3. The script sends the result to Telegram via curl
4. The script exits

This means the channel bot stays alive for interactive messages while cron scripts handle scheduled tasks.

### Example: Scheduled briefing

Create `~/bin/cos-briefing.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Prevent overlapping runs (if previous briefing is still running, skip this one)
exec 200>/tmp/cos-briefing.lock
flock -n 200 || { echo "Previous briefing still running, skipping"; exit 0; }

source ~/.claude/bot-credentials.env

# Run Claude one-shot with the briefing prompt
RESULT=$(cd ~/COS && claude -p \
    --max-turns 3 \
    --permission-mode dontAsk \
    "Generate a briefing for me. Check my email for anything urgent, review my calendar for today, and list any pending action items from cos-state.md. Be concise — this goes to Telegram." 2>&1 | tail -c 4000)

# Send to Telegram
if [ -n "$RESULT" ]; then
    curl -s -X POST "https://api.telegram.org/bot${COS_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${RESULT}" \
        -d parse_mode="Markdown" > /dev/null
fi
```

Set up credentials first:

```bash
cat > ~/.claude/bot-credentials.env << 'EOF'
COS_BOT_TOKEN="<your-cos-bot-token>"
MARKETING_BOT_TOKEN="<your-marketing-bot-token>"
TELEGRAM_CHAT_ID="<your-telegram-user-id>"
EOF
chmod 600 ~/.claude/bot-credentials.env
```

Add to crontab:

```bash
crontab -e
# Add:
0 7 * * 1-5 ~/bin/cos-briefing.sh >> ~/.claude/channels/briefing.log 2>&1
```

> **Why separate one-shots instead of telling the channel bot to "do X at 7am"?** Because the channel bot might be mid-conversation, or its context might be full, or it might be restarting. Cron one-shots are independent — they fire reliably regardless of the channel bot's state. And they don't pollute the channel bot's context window with scheduled task output.

> **Why `flock`?** If a cron job takes longer than the interval (e.g., a 15-minute email check takes 20 minutes), you'd get two copies running at once. `flock` prevents this by skipping the run if the previous one is still going.

### Suggested schedules for a COS bot

| Task | Frequency | Example cron |
|------|-----------|-------------|
| Morning briefing | Daily, weekdays | `0 7 * * 1-5` |
| Email check | Every 30 min, business hours | `*/30 7-18 * * 1-5` |
| EOD summary | Daily, weekdays | `0 18 * * 1-5` |
| Weekly review | Friday afternoon | `0 16 * * 5` |

> **Alternative: Timezone-aware scheduling.** If you travel, hardcoded cron times break. We built a timezone-aware briefing script that reads your timezone from a file and adjusts automatically. The concept: cron runs frequently (every 30 min), but the script itself decides whether it's time for a full briefing based on your local time. See the production setup section for details.

---

## 9. Add Long-Term Memory (Memory Search)

After a few weeks, the state file captures your current context, but the bot can't recall decisions from two weeks ago. Memory search gives it a searchable index across all its files.

Copy the [memory search scripts](../examples/memory-search/) to `~/bin/`:

```bash
cp examples/memory-search/memory-search ~/bin/
cp examples/memory-search/memory-daily-init ~/bin/
cp examples/memory-search/memory-log-conversation ~/bin/
chmod +x ~/bin/memory-search ~/bin/memory-daily-init ~/bin/memory-log-conversation
```

Edit `~/bin/memory-search` and configure the `AGENT_SOURCES` / `AGENT_DIRS` dictionaries to match your directory layout.

Create the daily notes directory:

```bash
mkdir -p ~/COS/daily
```

The hooks from Step 6 already reference memory search in the startup and post-compaction hooks. Once the scripts are installed, the bot will automatically index its files and be able to search its own history.

> **How it works**: `memory-search` builds a SQLite FTS5 (full-text search) index across all the bot's markdown files — state, profile, daily notes, Claude's own memory files. The bot can then search this index to recall past decisions, conversations, and context.

---

## 10. Build Your Second Bot: Product Marketing

Now that you've done it once, the second bot follows the same pattern. The key differences are the persona and the scheduled tasks.

### 10a. Create the persona

Create `~/Marketing/CLAUDE.md`:

```markdown
# Product Marketing

You are my VP of Product Marketing — a senior strategist who handles market research, competitive intelligence, content creation, and thought leadership.

## Your Role
- Market research and competitive analysis
- Content creation (blog posts, white papers, social media)
- Thought leadership and industry trend monitoring
- Product positioning and messaging
- Audience research and persona development

## How to Communicate
- Lead with insights, not process
- Always cite sources for research claims
- Flag opportunities by impact: high/medium/low
- When presenting research, include "so what" — what should we do with this information?

## What You Don't Do
- You do NOT manage email, calendar, or admin tasks — that's the COS bot's area
- You do NOT write code or review technical architecture
- If I ask about scheduling: "That's outside my area — check with your Chief of Staff bot"

## State Management — CRITICAL
Your conversation WILL end unexpectedly. The ONLY thing that survives is what you write to disk.
- Read `~/Marketing/marketing-state.md` at the START of every conversation
- Update it IMMEDIATELY after every substantive interaction
```

### 10b. Create supporting files

```bash
# State file
cat > ~/Marketing/marketing-state.md << 'EOF'
# Marketing State
*Last updated: (will be auto-filled)*

## Active Research
## Content Pipeline
## Recent Findings
## Context Carry-Forward
EOF

# User profile (copy from COS and let the bot customize)
cp ~/COS/user-profile.md ~/Marketing/user-profile.md

# Daily notes directory
mkdir -p ~/Marketing/daily
```

### 10c. Create hooks

Create `~/Marketing/.claude/settings.local.json` — same structure as COS, but with paths changed to `~/Marketing/`:

Copy the COS hooks file and find-replace `~/COS/cos-state.md` with `~/Marketing/marketing-state.md`, `/tmp/cos-` with `/tmp/marketing-`, and similar path references.

> **This is where the fleet hook automation script (Part 2, Section D) helps.** Instead of manually maintaining hook files for each bot, you define your fleet once and generate all the configs. Consider this if you're adding more than two bots.

### 10d. Create the start script, systemd service, and watchdog entry

Follow the same pattern as COS:
- Create `~/bin/claude-marketing-bot-start.sh` (change paths and token references)
- Create `~/.config/systemd/user/claude-marketing-bot.service`
- Add the marketing bot to the watchdog script

### 10e. Add marketing-specific cron jobs

```bash
crontab -e
# Add:
# Weekly market research — Monday morning
0 6 * * 1 ~/bin/marketing-research.sh >> ~/.claude/channels/marketing.log 2>&1

# Weekly use case analysis — Tuesday morning
0 6 * * 2 ~/bin/marketing-usecases.sh >> ~/.claude/channels/marketing.log 2>&1
```

> **Alternative schedules**: If weekly is too frequent, start with biweekly or monthly. The point is that the bot does proactive research without you having to remember to ask.

---

## 11. Connect the Bots (Inter-Agent Inbox)

With two bots running, they'll occasionally need to coordinate. The COS might discover something during email triage that the marketing bot should know about. The marketing bot might need the COS to schedule a meeting based on research findings.

### How it works

Each bot has an `inbox.md` file. To send a message to another bot, it writes to their inbox. A hook checks the inbox before every reply, so messages get picked up automatically.

### Set it up

Create inbox files:

```bash
cat > ~/COS/inbox.md << 'EOF'
# COS Inbox
<!-- Inter-agent messages. Check for Status: new messages and handle them. -->
<!-- After handling, change Status from "new" to "done". -->
EOF

cat > ~/Marketing/inbox.md << 'EOF'
# Marketing Inbox
<!-- Inter-agent messages. Check for Status: new messages and handle them. -->
<!-- After handling, change Status from "new" to "done". -->
EOF
```

Copy the inbox-check script:

```bash
cp examples/inter-agent/inbox-check ~/bin/
chmod +x ~/bin/inbox-check
```

Edit `~/bin/inbox-check` and update the `INBOX_PATH` array:

```bash
INBOX_PATH[cos]="$HOME/COS/inbox.md"
INBOX_PATH[marketing]="$HOME/Marketing/inbox.md"
```

Add the inbox check to each bot's hooks (in `settings.local.json`, add this to the PreToolUse array):

```json
{
  "matcher": "mcp__plugin_telegram_telegram__reply",
  "hooks": [
    {
      "type": "command",
      "command": "~/bin/inbox-check cos 2>/dev/null || true"
    }
  ]
}
```

(Use `inbox-check marketing` for the marketing bot.)

Add inbox instructions to each bot's CLAUDE.md:

```markdown
## Inter-Agent Communication
You can send messages to other bots by writing to their inbox file.

### Bot Directory
| Bot | Inbox Path |
|-----|------------|
| COS | ~/COS/inbox.md |
| Marketing | ~/Marketing/inbox.md |

### Sending a Message
Append to the target bot's inbox.md:
- **From:** cos (or marketing)
- **Priority:** P0 (blocker), P1 (action needed), P2 (FYI)
- **Status:** new
```

See [Inter-Agent Communication](inter-agent-communication.md) for the full message format and guidelines.

> **Why file-based instead of a database or message queue?** Because it's the simplest thing that works. The bots can already read and write files — no new dependencies, no new failure modes. A markdown file in the working directory is something Claude natively understands.

> **Scaling up?** If you grow beyond 3 bots or need delivery confirmation and threading, see the [v3 SQLite-based messaging](inter-agent-communication.md#v3-sqlite-based-real-time-messaging) upgrade in the inter-agent communication docs. It replaces inbox.md files with a shared SQLite database — atomic writes, no corruption risk, real-time push notifications.

---

## 12. Add the Management CLI

Copy [examples/management/claude-bot](../examples/management/claude-bot) to `~/bin/`:

```bash
cp examples/management/claude-bot ~/bin/
chmod +x ~/bin/claude-bot
```

Edit the bot definitions at the top to match your fleet. Now you can manage both bots with:

```bash
claude-bot status              # Check all bots
claude-bot start cos           # Start COS only
claude-bot restart marketing   # Restart marketing
claude-bot logs cos            # Attach to COS's live session
claude-bot stop all            # Stop everything
```

> **When to use `logs`**: If a bot is behaving oddly, attach to its tmux session with `claude-bot logs cos` to see what it's actually doing. Press `Ctrl+B` then `D` to detach without stopping the bot.

---

## You're Done (Core Fleet)

At this point you have:
- Two bots (COS + Marketing) running 24/7 on Telegram
- Persistent memory that survives restarts
- A watchdog that auto-restarts crashed bots
- Scheduled tasks running on cron
- Inter-agent coordination via inbox
- A management CLI for controlling the fleet

**What to do next:**
- Use the bots for a week before changing anything — let them build up state and learn your patterns
- Check the state files periodically to see what the bots are capturing
- Add integrations (Google Workspace, Notion) as you identify needs
- Read Part 2 if you want to add engineering bots

### Going Further (Advanced Fleet Capabilities)

Once your fleet is stable and you want more reliability or capability, see [extensions.md](extensions.md) for detailed writeups of:

- **Auto-Resume** (Problem #20) — bots pick up interrupted multi-step work automatically after a crash, with safety classification so risky steps always ask first
- **Lock Gate** (Problem #21) — prevents background workers and live sessions from clobbering each other's state files
- **GPU Queue** (Problem #23) — if you run local LLM backends (llama.cpp), a queue daemon coordinates all requests by priority and manages model lifecycle
- **Local Inference** (Problem #24) — grammar-constrained local inference for cheap structured output (email triage, log classification) without burning cloud API quota
- **Inter-Agent v3** (Problem #25) — SQLite-based messaging that replaces the file-based inbox with atomic writes, threading, and delivery tracking
- **Fleet Heartbeat** (Problem #26) — a dead-man's-switch that watches the watchdog itself
- **Fleet Metrics** (Problem #27) — Prometheus-compatible metrics for tracking bake rates, session ages, and queue depths over time

---

# Part 2: Engineering Appendix

This section is for those who want to add technical/engineering bots to the fleet. These bots review code, manage PRs, enforce architecture standards, and run automated audits.

> **You don't need this section** if you're a PM or business operator who doesn't work with code repositories. The COS + Marketing fleet from Part 1 is a complete, useful setup on its own.

---

## A. Add a CTO Bot

The CTO bot owns cross-project architecture decisions, technical standards, and code quality. It's the one that ensures consistency when you have multiple projects.

### When you need a CTO bot

- You have 2+ code repositories that should follow consistent patterns
- You want someone to enforce architecture decisions (ADRs, coding standards)
- You need a technical voice that can review plans from engineering bots

### Setup

Follow the same pattern as COS/Marketing:

1. **Working directory**: `~/CTO/`
2. **CLAUDE.md**: Senior technical leader persona — owns architecture, standards, cross-project consistency
3. **State file**: `~/CTO/cto-state.md`
4. **Hooks**: Same 4-hook lifecycle, paths adjusted
5. **Start script**: `~/bin/claude-cto-bot-start.sh`
6. **systemd**: `~/.config/systemd/user/claude-cto-bot.service`

The CTO bot's CLAUDE.md should include:
- Architecture decision records (ADRs) or where to find them
- Cross-project standards (naming, patterns, security requirements)
- References to project-specific bots and how to delegate

---

## B. Add VP Engineering Bots

VP Engineering bots are your per-project engineering leads. Each one owns a specific codebase and handles code review, PR management, bug fixing, and architecture decisions within that project.

### Why one bot per project (not one bot for all projects)

- **Context efficiency**: A bot that only works on one project keeps its context focused. A bot juggling two codebases wastes context on the wrong project's details.
- **Specialization**: Each project has different frameworks, patterns, and conventions. Separate bots learn and enforce project-specific patterns.
- **Isolation**: A bug in one bot's workflow doesn't affect the other project.

### Setup

For each project:

1. **Working directory**: The project's repo root (e.g., `~/Projects/my-app/`)
2. **CLAUDE.md**: VP Engineering persona, tuned for this specific project
3. **State file**: `vpe-state.md` in the project root
4. **Start script**: Add `--add-dir` if the bot needs access to shared directories

Example start script addition for shared access:

```bash
exec claude --channels plugin:telegram@claude-plugins-official \
    --add-dir ~/shared-reference-docs
```

> **The VPE bot's working directory should be your actual code repo.** This way Claude can read the codebase, run tests, create PRs, and review code. The COS and Marketing bots live in dedicated directories because they don't need codebase access.

---

## C. Agent Skills (Slash Commands)

Agent skills are reusable prompt templates that give your engineering bots specialized capabilities. They live in `.claude/commands/` in the project directory.

### How to use them

1. Browse [examples/agent-skills/](../examples/agent-skills/) for the full catalog
2. Copy any `.md` file into your project's `.claude/commands/` directory
3. The bot can now run them as slash commands (e.g., `/deep-fix`, `/security-reviewer`)

### Recommended starter set

| Skill | Category | What it does |
|-------|----------|-------------|
| `/bug-analyzer` | Development | Root cause analysis with evidence chain |
| `/deep-fix` | Development | Systematic multi-step bug resolution |
| `/security-reviewer` | Auditor | Auth, injection, data exposure scan |
| `/test-writer` | Development | Generates tests following project patterns |
| `/peer-review` | Quality | External-perspective code review |

You can add all 39 skills at once (`cp examples/agent-skills/**/*.md your-project/.claude/commands/`) or start with a few and add more as needed.

See [examples/agent-skills/README.md](../examples/agent-skills/README.md) for the complete catalog.

---

## D. Fleet Hook Automation

Once you have 3+ bots, manually maintaining hooks files becomes error-prone. One typo in a path, and a bot silently stops saving state.

The fleet hook automation script generates `.claude/settings.local.json` for every bot from a single configuration:

```bash
cp examples/fleet-hooks/update-fleet-hooks.js ~/bin/
```

Edit the `bots` object in the script to define your fleet, then run:

```bash
node ~/bin/update-fleet-hooks.js
```

It generates validated hook configs for every bot. When you need to change a hook pattern fleet-wide (like upgrading from reminder-style to mandatory-save-style), edit one file and regenerate.

See [examples/fleet-hooks/update-fleet-hooks.js](../examples/fleet-hooks/update-fleet-hooks.js) for the full script with comments.

---

# Part 3: Platform Appendix

## E. Running on a Mac Mini

A Mac Mini (especially the M-series models) is a great always-on machine for running a bot fleet — quiet, low power consumption, and reliable. The main guide assumes Linux, so this appendix covers everything that's different on macOS.

### What's the same

Most of the setup is identical:
- Claude Code CLI works the same on macOS
- The Telegram plugin, hooks, state files, CLAUDE.md, inbox system — all unchanged
- The start scripts, management CLI, and memory search scripts work as-is (they're bash)
- tmux works the same (`brew install tmux`)

### What's different

| Component | Linux | macOS |
|-----------|-------|-------|
| Package manager | `apt` | `brew` (Homebrew) |
| Auto-start on boot | systemd | launchd |
| Keep running after logout | `loginctl enable-linger` | launchd handles this natively |
| Service logs | `journalctl` | `log show` or Console.app |
| System cron | crontab (same) | crontab (same) or launchd timers |
| File paths | `/home/username` | `/Users/username` |

### Prerequisites (macOS version)

```bash
# Install Homebrew if you don't have it
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install tmux
brew install tmux

# Install Bun (required by the Telegram plugin)
brew install oven-sh/bun/bun

# Claude Code CLI — install from https://claude.ai/code
# Or if you use npm:
npm install -g @anthropic-ai/claude-code
```

### Auto-start with launchd (replaces systemd)

macOS uses `launchd` instead of `systemd` for managing background services. The concept is the same — you create a config file that tells the system to start your bot on boot and restart it if it crashes.

Create `~/Library/LaunchAgents/com.claude.cos-bot.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.cos-bot</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/tmux</string>
        <string>-L</string>
        <string>claude-cos</string>
        <string>new-session</string>
        <string>-d</string>
        <string>-s</string>
        <string>claude-cos-bot</string>
        <string>/Users/yourusername/bin/claude-cos-bot-start.sh</string>
    </array>

    <!-- Start on boot / login -->
    <key>RunAtLoad</key>
    <true/>

    <!-- Restart if it exits -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <!-- Wait 10 seconds before restarting after a crash -->
    <key>ThrottleInterval</key>
    <integer>10</integer>

    <!-- Log output for debugging -->
    <key>StandardOutPath</key>
    <string>/Users/yourusername/.claude/channels/cos-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/yourusername/.claude/channels/cos-launchd-error.log</string>

    <!-- Set environment variables -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/yourusername</string>
        <key>PATH</key>
        <string>/Users/yourusername/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
```

> **Important**: Replace `/Users/yourusername` with your actual home directory throughout. On Apple Silicon Macs, Homebrew lives at `/opt/homebrew/bin`. On Intel Macs, it's `/usr/local/bin`. Check with `brew --prefix`.

> **Also important**: The tmux path may be `/opt/homebrew/bin/tmux` on Apple Silicon instead of `/usr/local/bin/tmux`. Check with `which tmux`.

Load and start the service:

```bash
# Load the service (starts immediately because RunAtLoad is true)
launchctl load ~/Library/LaunchAgents/com.claude.cos-bot.plist

# Check status
launchctl list | grep claude

# If you need to stop it
launchctl unload ~/Library/LaunchAgents/com.claude.cos-bot.plist
```

Repeat for each bot — create a separate `.plist` file for each one (e.g., `com.claude.marketing-bot.plist`).

> **Why launchd instead of just putting tmux commands in Login Items?** Login Items only run when you log in to the GUI. launchd runs services at boot, before anyone logs in, and keeps them running through logout/login cycles. It also handles crash recovery (the `KeepAlive` key) — if tmux dies, launchd restarts it automatically.

### Start script adjustments for macOS

The start scripts from Part 1 work on macOS with two path changes:

```bash
#!/usr/bin/env bash

# macOS paths — adjust for your setup
# Apple Silicon Macs: Homebrew is at /opt/homebrew
# Intel Macs: Homebrew is at /usr/local
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin"
export HOME="/Users/yourusername"    # <-- CHANGE THIS (note: /Users, not /home)

export TELEGRAM_STATE_DIR="$HOME/.claude/channels/telegram-cos"

TOKEN_PREFIX=$(head -c 10 "$TELEGRAM_STATE_DIR/.env" | grep -oP '\d+' | head -1)
if [ -n "$TOKEN_PREFIX" ]; then
    pkill -f "telegram.*${TOKEN_PREFIX}" 2>/dev/null || true
    sleep 1
fi

cd ~/COS

exec claude --channels plugin:telegram@claude-plugins-official
```

> **Note on `grep -oP`**: macOS's built-in `grep` doesn't support `-P` (Perl regex). If the zombie poller cleanup line fails, either install GNU grep (`brew install grep`, then use `ggrep -oP`) or replace the line with: `TOKEN_PREFIX=$(head -c 40 "$TELEGRAM_STATE_DIR/.env" | sed -n 's/.*=\([0-9]*\).*/\1/p' | head -1)`

### Viewing logs

```bash
# launchd service logs (stdout/stderr from the plist config)
tail -f ~/.claude/channels/cos-launchd.log
tail -f ~/.claude/channels/cos-launchd-error.log

# System log for launchd events
log show --predicate 'senderImagePath CONTAINS "tmux"' --last 1h

# Or use Console.app (GUI) and search for "claude"
```

### Preventing sleep

A Mac Mini that goes to sleep stops your bots. Make sure it stays awake:

**System Settings > Energy Saver (or Battery):**
- Turn OFF "Automatically sleep when the display is off"
- Turn ON "Prevent your Mac from automatically sleeping when the display is off"
- Turn ON "Wake for network access" (so you can SSH in remotely)
- Turn ON "Start up automatically after a power failure"

Or from the terminal:

```bash
# Prevent sleep entirely (survives reboots via Energy Saver settings)
sudo pmset -a sleep 0
sudo pmset -a disksleep 0

# Verify
pmset -g
```

> **Why this matters**: Unlike a Linux server or WSL on a desktop, Mac Mini defaults to sleeping after a period of inactivity. A sleeping Mac can't process Telegram messages. The bots will appear dead until you wake the machine.

### Cron on macOS

`crontab` works the same on macOS:

```bash
crontab -e
# Same syntax as Linux:
*/5 * * * * ~/bin/claude-bot-watchdog.sh all >> ~/.claude/channels/watchdog.log 2>&1
```

One gotcha: macOS may prompt you to grant "Full Disk Access" to cron. If your cron scripts fail with permission errors, go to **System Settings > Privacy & Security > Full Disk Access** and add `/usr/sbin/cron`.

> **Alternative: launchd timers instead of cron.** You can use launchd for scheduled tasks too (add a `StartInterval` or `StartCalendarInterval` key to a plist). But crontab is simpler for most cases and works identically to the Linux instructions.

### Remote access

If your Mac Mini is headless (no monitor), you'll want remote access:

```bash
# Enable SSH (if not already on)
sudo systemsetup -setremotelogin on

# Connect from another machine
ssh yourusername@your-mac-mini-ip
```

You can also use **Screen Sharing** (System Settings > Sharing > Screen Sharing) for GUI access, but SSH is sufficient for bot management.

> **Tip**: Set a static IP or use a dynamic DNS service so you can always reach your Mac Mini, even if your router assigns a new IP after a reboot.

### Mac Mini vs Linux VPS: tradeoffs

| Factor | Mac Mini | Linux VPS |
|--------|----------|-----------|
| **Cost** | ~$600 one-time (M2/M4 Mini) | $5-20/month ongoing |
| **Performance** | Fast (local SSD, lots of RAM) | Varies by plan |
| **Reliability** | Depends on your power/internet | Cloud-grade uptime |
| **Privacy** | Everything stays on your machine | Data on someone else's server |
| **Maintenance** | You handle updates, power, internet | Provider handles hardware |
| **Remote access** | SSH over your network (or Tailscale for remote) | SSH from anywhere |
| **Power outages** | Need a UPS for reliability | Not your problem |

> **Our recommendation**: If you already have a Mac Mini or are buying one anyway, use it. If you're starting from scratch and want the lowest-friction option, a $10/month Linux VPS on Hetzner or DigitalOcean avoids all the power/sleep/network concerns. Either works — pick what fits your situation.

---

## Quick Reference

| Task | Command |
|------|---------|
| Check all bots | `claude-bot status` |
| Start a specific bot | `claude-bot start cos` |
| Restart a bot | `claude-bot restart marketing` |
| See a bot's live session | `claude-bot logs cos` |
| Detach from live session | `Ctrl+B` then `D` |
| Check systemd status | `systemctl --user status claude-cos-bot` |
| View systemd logs | `journalctl --user -u claude-cos-bot -n 50` |
| Update fleet hooks | `node ~/bin/update-fleet-hooks.js` |
| Search bot memory | `~/bin/memory-search cos "query"` |
| Reindex memory | `~/bin/memory-search cos --index` |

---

*Built by [Mindspan Labs](https://github.com/SalmonSlayer75/mindspan-labs-agents). Based on the original setup guide by [Peter Steinberger](https://github.com/steipete).*

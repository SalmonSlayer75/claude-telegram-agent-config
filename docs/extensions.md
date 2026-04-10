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

**COS example** (`~/AgentWorkspace/bot-state.md`):
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

**VPE example** (`~/Projects/bot-state.md`) — same structure but with engineering-specific sections:
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
  - **Read `~/AgentWorkspace/bot-state.md` at the START of every conversation**
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
            "command": "if [ ! -f /tmp/bot-state-loaded ]; then echo '[STARTUP] Read ~/AgentWorkspace/bot-state.md FIRST to restore your working memory before replying.'; touch /tmp/bot-state-loaded; fi"
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
            "command": "echo '[STATE REMINDER] You just sent a Telegram reply. If this interaction involved any decisions, action items, commitments, or important context — update ~/AgentWorkspace/bot-state.md NOW before doing anything else.'"
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

The `/tmp/bot-state-loaded` flag file resets on reboot (since `/tmp` is cleared), so the startup reminder fires again after each restart.

---

## Problem #2: Cron Jobs (Scheduled One-Shot Tasks)

### What the original guide doesn't cover

The original guide sets up an always-on channel bot. But we also needed the bots to do things on a schedule — morning briefings, email checks, weekly research sweeps — without the human asking.

### What we do: Cron scripts that run separate Claude one-shots

Each scheduled task is a bash script that:
1. Runs `claude -p` (one-shot prompt mode, not channel mode) with the relevant MCP config
2. Sends results to Telegram via the Bot API directly (curl, not through the channel)
3. Logs output to a dedicated log file

**Example** (`~/bin/scheduled-email-check.sh`):
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
RESULT=$(cd ~/AgentWorkspace && claude -p \
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
0 7 * * * ~/bin/morning-brief.sh >> ~/.claude/channels/morning-brief.log 2>&1

# COS Email Check — every 15 min, 7am-10pm
*/15 7-22 * * * ~/bin/scheduled-email-check.sh >> ~/.claude/channels/email-check.log 2>&1

# VPE Daily Status — daily 8am
0 8 * * * ~/bin/daily-status.sh >> ~/.claude/channels/daily-status.log 2>&1

# VPE PR Watcher — every 30 min, 8am-10pm
*/30 8-22 * * * ~/bin/pr-watch.sh >> ~/.claude/channels/pr-watch.log 2>&1
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
  --add-dir ~/my-other-project \
  --add-dir "~/other-project"
```

This lets VPE review code across both projects from a single bot. The working directory (`~/Projects`) contains the VPE's CLAUDE.md and state file, while `--add-dir` grants read/write access to the actual codebases.

COS also uses `--add-dir` for cross-referencing project status when briefing the human:

```bash
cd ~/AgentWorkspace
exec claude --channels plugin:telegram@claude-plugins-official \
  --add-dir ~/Projects \
  --add-dir ~/my-other-project
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

## Problem #7: Bot Can't Search Its Own History

### What happens

After a few weeks of operation, the bot has accumulated daily notes, conversation logs, memory files, and state files across multiple directories. When you ask "what did we discuss about the quarterly review last week?", the bot can't efficiently search across all of these.

### What we do: SQLite FTS5 search index

We built a small Python tool (`~/bin/memory-search`) that:
1. Indexes all of a bot's memory files into a SQLite FTS5 database with BM25 ranking
2. Chunks documents intelligently (by markdown sections, conversation entries, or daily notes)
3. Returns ranked results with snippets, filterable by date

```bash
# Search for past context
memory-search work "quarterly review" --limit 5
memory-search work "client feedback" --since 2026-03-01

# Rebuild the index
memory-search work --index

# Check what's indexed
memory-search work --status
```

The tool indexes: state files, user profiles, Claude Code memory files (`~/.claude/projects/.../memory/*.md`), daily notes, reference docs, and conversation transcripts.

**Hook integration**: The PreToolUse hook calls `memory-search <agent> --index` on first reply of a new session (to pick up any files changed while the bot was down). PostCompact also reindexes (to capture anything written during the session). The bot can then search past context with `memory-search <agent> "query"` whenever it needs historical information.

See [examples/memory-search/](../examples/memory-search/) for the full implementation.

---

## Problem #8: Bot Doesn't Learn About You Over Time

### What happens

Every session starts fresh. The bot doesn't remember that you prefer 15-minute buffers between meetings, that you hate sloppy email formatting, or who your key contacts are. You end up re-explaining preferences that should be obvious after weeks of interaction.

### What we do: Structured user profile + learning loop

We give the bot a structured profile file (`~/AgentWorkspace/user-profile.md`) that it updates incrementally as it learns things about you. The PostToolUse hook prompts the bot after every Telegram reply: "If you learned anything new about the user, update the profile." The PreCompact hook gives it one last chance to save observations before context is lost.

Over time, the profile fills in organically:
- Communication preferences (brief vs detailed, tone, formatting)
- Scheduling constraints (blackout hours, buffer times, preferred locations)
- Relationships (contacts encountered in emails, meetings, conversations)
- Recurring patterns (messaging habits, travel patterns, work rhythms)

See [docs/personalization.md](personalization.md) for the full pattern and [examples/personalization/](../examples/personalization/) for the template.

---

## Problem #9: Context Compaction Loses Important State

### What happens

Claude Code compacts the context window when it gets too large. This is good for keeping the session alive longer, but it can lose important observations the bot hasn't written to disk yet.

### What we do: PreCompact and PostCompact hooks

Two additional hooks in `settings.local.json` handle the compaction lifecycle:

- **PreCompact** fires before compaction. It urgently tells the bot: "This is your LAST CHANCE to persist context. Save state, update the user profile, write daily notes NOW."
- **PostCompact** fires after compaction. It reindexes the memory search database and tells the bot to re-read its state files, since it may have lost context about what's in them.

Together with PreToolUse and PostToolUse, this creates a 4-hook lifecycle:

| Hook | When | What it does |
|------|------|-------------|
| PreToolUse | Before first Telegram reply | Load state, profile, daily notes; initialize daily note; rebuild search index |
| PostToolUse | After every Telegram reply | Nudge to save state and update user profile |
| PreCompact | Before context compaction | Emergency save of all unsaved state |
| PostCompact | After context compaction | Reindex search; reload state files |

See [examples/hooks/settings.local.json](../examples/hooks/settings.local.json) for the full config.

---

## Problem #10: Daily Context Drift

### What happens

Over a long session, the bot accumulates context about the day's conversations, decisions, and action items. But this context only lives in the conversation window. If the session bakes or compacts, the day's narrative is fragmented across state file snapshots.

### What we do: Daily notes

Each bot maintains a `daily/YYYY-MM-DD.md` file that serves as a running log for the day. The `memory-daily-init` script (called from PreToolUse at session start) creates the day's file with standard sections: Conversations, Decisions Made, Action Items, Notes. Old daily notes are auto-pruned after 14 days.

The bot appends to the daily note throughout the day. On restart or compaction, it re-reads the daily note to pick up where it left off. The memory search tool indexes daily notes so they're searchable later.

See [examples/memory-search/memory-daily-init](../examples/memory-search/memory-daily-init).

---

## Problem #11: Credentials Scattered Across Scripts

### What happens

Bot tokens, chat IDs, and API keys end up hardcoded in every cron script and the watchdog. When you rotate a token, you have to update it in five places. One missed update and a cron job silently fails.

### What we do: Centralized credentials file

All secrets live in `~/.claude/bot-credentials.env` with `chmod 600`. Every script sources it:

```bash
source "$HOME/.claude/bot-credentials.env"
BOT_TOKEN="$BOT_TOKEN_1"
CHAT_ID="$TELEGRAM_CHAT_ID"
```

One file to update when tokens change. One file to protect. See [examples/credentials/bot-credentials.env.example](../examples/credentials/bot-credentials.env.example) for the template.

---

## Summary of Additions

| Addition | What it solves | Files involved |
|----------|---------------|----------------|
| Structured state file | Bot loses context across restarts | `bot-state.md` |
| Aggressive CLAUDE.md instructions | Bot doesn't save state reliably | `CLAUDE.md` |
| PreToolUse hook | Bot doesn't read state on new session | `.claude/settings.local.json` |
| PostToolUse hook | Bot forgets to update state after interactions | `.claude/settings.local.json` |
| PreCompact hook | Context compaction loses unsaved state | `.claude/settings.local.json` |
| PostCompact hook | Bot is disoriented after compaction | `.claude/settings.local.json` |
| Memory search | Bot can't search its own history | `~/bin/memory-search`, SQLite FTS5 |
| User profile + learning loop | Bot doesn't learn about you over time | `user-profile.md`, PostToolUse hook |
| Daily notes | Day's context is lost on restart/compaction | `daily/YYYY-MM-DD.md`, `memory-daily-init` |
| Watchdog cron | Bot appears "RUNNING" but is actually dead | `~/bin/claude-bot-watchdog.sh`, crontab |
| Cron one-shot scripts | Scheduled tasks (briefings, email checks, PR monitoring) | `~/bin/*.sh`, crontab |
| Credential management | Tokens scattered across scripts | `~/.claude/bot-credentials.env` |
| `--add-dir` for multi-codebase | Bot needs access beyond working directory | Start scripts |
| Role isolation in CLAUDE.md | Two bots producing conflicting information | `CLAUDE.md` |
| WSL auto-start | Bots don't survive Windows reboot | Boot script + Windows Startup |
| Log rotation | Log files grow unbounded | `logrotate.conf` |

---

## Recommendations (Priority Order)

### Priority 1: Watchdog (5 min to set up, biggest reliability win)

If you do nothing else, add the watchdog. Without it, a baked bot sits dead until you manually notice and restart it. With it, max downtime is 5 minutes. The watchdog inspects the tmux pane for "Listening for channel messages" vs "Baked for" and auto-restarts when needed, with a Telegram notification so you know it happened.

### Priority 2: State file + 4-hook lifecycle (persistent memory)

If your bots run long enough to hit context limits (and they will), they lose everything from the prior session. The state file + hook pattern gives you persistent memory without external infrastructure. It's four files:

1. A structured markdown state file (the bot's working memory)
2. A CLAUDE.md section telling the bot to read/write it aggressively
3. A user profile file for long-term personalization
4. Hook config in `settings.local.json` with all 4 hooks (PreToolUse, PostToolUse, PreCompact, PostCompact)

### Priority 3: Credential management + cron one-shots (proactive behavior)

Set up `bot-credentials.env` first, then build cron scripts that source it. If you want the bot to do things on a schedule (morning briefings, email checks, monitoring) without waiting for a message, cron scripts running `claude -p` (one-shot mode) are the way.

### Priority 4: Memory search + daily notes (long-term recall)

Once the bot has been running for a few weeks, searchable history becomes valuable. The memory search tool and daily notes give the bot the ability to recall past conversations and decisions without you re-explaining them.

### Priority 5: `--add-dir`, role isolation, and log rotation

These matter once you have multiple bots or a bot that needs access to files outside its working directory. Not critical for a single-bot setup, but essential as complexity grows. Log rotation prevents disk space issues over months of operation.

---

## Problem #13: Bots Ignore "Save Your State" Reminders Under Pressure

### What happens

PostToolUse reminders ("don't forget to save state") get ignored when the bot is deep in a complex task. It keeps working, hits context limits, and loses everything since the last save. The reminder pattern was too gentle — it relied on the bot choosing to comply.

### What we do now: Hard Gate on State Saves (Bot Gate)

A PreToolUse hook that **blocks** substantive tool calls (Bash, Edit, WebSearch, etc.) unless the bot has updated its state file recently. Two invariants:

1. **ACK invariant** — after a new Telegram message, the bot must update `## Active Conversation` before doing anything else. This ensures it acknowledges what was asked.
2. **Counter invariant** — after 10 substantive tool calls without updating `## Active Conversation`, the gate blocks until the bot saves.

Read-only tools (Read, Grep, Glob) are exempt. The bot can always edit its own state file (that's the escape hatch). The gate uses file locking to prevent races between the arm and check modes.

This was the single biggest reliability improvement after the original 4-hook lifecycle. Bots that previously lost hours of work now checkpoint every 5-10 tool calls automatically.

See [examples/bot-gate/](../examples/bot-gate/) for the full implementation.

---

## Problem #14: Bots Don't Learn From Experience

### What happens

AI agents make the same mistakes across sessions. They don't remember that a particular approach failed last time, or that a specific tool sequence is the most efficient workflow. You end up encoding every lesson manually in CLAUDE.md, which bloats the prompt.

### What we do now: Instinct Learning System

A three-stage pipeline:

1. **Observe** — A PostToolUse hook captures every tool call to a JSONL log (with secret scrubbing and size limits)
2. **Analyze** — A pattern detector runs periodically, identifying recurring flows, error-resolution patterns, and tool preferences
3. **Inject** — A session-start hook loads high-confidence instincts into the bot's context

Instincts use a confidence scoring system: new instincts start at 0.3, bump up with additional evidence, cap at 0.85 (never fully trust automated learning), and decay over time. Only instincts above 0.5 confidence are injected into sessions.

This is experimental — the pattern detection is simple and can produce false positives. The confidence cap and decay mechanism prevent bad instincts from accumulating.

See [examples/instinct-learning/](../examples/instinct-learning/) for the full implementation.

---

## Problem #15: Hook Count Grows Unmanageable

### What happens

As you add more hooks (state gates, inbox checks, memory indexing, compaction advisors), every tool call runs 10+ hooks. Development sessions are slow, debugging is painful, and some hooks interfere with others. You need a way to control which hooks run in which context.

### What we do now: Hook Runtime Profiles

A thin wrapper script that gates hook execution based on a profile level:

- **minimal** — bare minimum for safety (just the state gate)
- **standard** — normal production (state gate + inbox + memory)
- **strict** — everything including expensive advisors

Each hook declares its minimum profile level. Set `HOOK_PROFILE=minimal` for debugging, `standard` for normal operation, `strict` for critical work.

Individual hooks can also be disabled by ID via `DISABLED_HOOKS=pre:gate:check,post:tg:heartbeat`.

See [examples/hook-profiles/](../examples/hook-profiles/) for the implementation.

---

## Problem #16: Bots Weaken Linter/CI Configs to "Fix" Failures

### What happens

When an AI agent encounters a failing lint check or CI error, the path of least resistance is to edit the config — disable the ESLint rule, relax the TypeScript strictness, add an ignore pattern. This produces green CI with degraded code quality. We caught this multiple times: agents silently weakened configs to make errors disappear.

### What we do now: Config Protection Hook

A PreToolUse hook that blocks Edit/Write operations targeting known config files (ESLint, Prettier, tsconfig, CI workflows, etc.). The bot gets a clear message: "fix the source code, not the config."

See [examples/config-protection/](../examples/config-protection/) for the implementation.

---

## Problem #17: One-Shot Tasks Need Different Models for Different Phases

### What happens

Running `claude -p` for automated tasks (CI fixes, code review, implementation) at the same model tier is wasteful. Implementation is high-volume and well-scoped — a fast model handles it fine. Review requires deeper reasoning — you want a more capable model. Using opus for everything is slow and expensive; using sonnet for everything misses subtle bugs.

### What we do now: Model Routing in Automated Pipelines

Our continuous PR loop script uses `--model` flags to route different phases to different models:

- **Implementation, cleanup, CI fixes** → `sonnet` (fast, good enough for well-scoped tasks)
- **Code review** → `opus` (deeper reasoning for correctness analysis)

The script also supports multi-iteration mode with shared notes, a mandatory "de-sloppify" pass (separate context window that removes AI-typical cruft), and automatic CI failure detection with retry.

See [examples/continuous-pr-loop/](../examples/continuous-pr-loop/) for the implementation.

---

## Problem #18: No Guardrails on Dangerous Commands

### What happens

Channel bots running in `dontAsk` permission mode have broad tool access. Without explicit deny rules, nothing prevents the bot from reading SSH keys, piping curl output to bash, force-pushing to git, or accessing credential files — whether accidentally or via prompt injection in processed content.

### What we do now: Security Deny Rules

Claude Code's `settings.json` supports `deny` rules that override all `allow` rules. We block:

- **Destructive git**: `git push --force`, `git reset --hard`
- **Catastrophic deletion**: `rm -rf /`, `rm -rf ~`
- **Remote code execution**: `curl|bash`, `wget|sh`
- **Network tools**: `ssh`, `scp`, `nc`, `netcat`
- **Credential files**: `~/.ssh/**`, `~/.aws/**`, `.env` files, bot credential files

These rules apply regardless of what the prompt says or what MCP tool output contains. They're the last line of defense.

See [examples/security-deny-rules/](../examples/security-deny-rules/) for the full recommended ruleset.

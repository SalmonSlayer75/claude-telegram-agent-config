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
| Fleet review | No visibility into fleet health | `fleet-review.sh`, cron |
| Auto-resume + JSON sidecar | Session dies mid-task, work abandoned | `bot-auto-resume.sh`, `ac-resume.json` |
| Lock-aware PreToolUse gate | Background workers conflict with live sessions | `bot-lock-gate.py`, flock |
| Stale lock janitor | Orphaned lock files block operations | `stale-lock-janitor.sh`, cron |
| GPU queue daemon | Local LLM requests are uncoordinated | `gpu-queue-daemon.py`, `gpu-queue-client.sh` |
| Grammar-constrained local inference | Cron jobs need structured LLM output cheaply | `local-infer-structured.sh` |
| SQLite inter-agent messaging (v3) | File-based inbox doesn't scale | `interbot-send-v3`, `schema.sql` |
| Fleet heartbeat (dead-man's-switch) | Watchdog itself goes down silently | `fleet-heartbeat-check.sh`, cron |
| Prometheus textfile metrics | No fleet-level metrics | `fleet-metrics.sh` |

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

---

## Problem #19: No Visibility Into Fleet Health

### What happens

With 6 bots running, problems hide. A bot silently loses context. A cron job fails every third run. A hook is misconfigured. You only discover it when you notice the bot acting strangely — hours or days later.

### What we do now: Automated Fleet Review

A daily cron job gathers logs from all bots, watchdog output, cron job results, and state files, then feeds everything to Claude for analysis. The output is a prioritized report sent to Telegram:

- **P0**: Things that are broken right now
- **P1**: Things that are degraded or will break soon
- **P2**: Optimization opportunities

The review script uses `claude -p` (one-shot mode) so it runs independently of all bot sessions.

See [examples/fleet-review/](../examples/fleet-review/) for the implementation.

---

## Problem #20: Session Dies Mid-Task, Work Abandoned

### What happens

Multi-step work (deploy a change across 5 bots, review and merge a PR chain, run a diagnostic sequence) gets interrupted when the bot hits its context limit. The next session starts fresh with no idea what step it was on. You either re-explain the task or — worse — the bot repeats work already done.

### What we do now: Auto-Resume with Safety Rails

A JSON sidecar file tracks each step of a multi-step task:

```json
{
  "topic": "Deploy fleet hook update",
  "status": "in-progress",
  "auto_resume": true,
  "current_step": 3,
  "total_steps": 5,
  "steps": [
    {"num": 1, "description": "Generate new configs", "safety": "safe", "done": true},
    {"num": 2, "description": "Test on devops bot", "safety": "safe", "done": true},
    {"num": 3, "description": "Roll out to all bots", "safety": "needs-approval", "done": false}
  ],
  "resumption_context": "Steps 1-2 complete. Configs generated and tested. Ready to roll out fleet-wide."
}
```

On startup, a resume engine (`bot-auto-resume.sh`) reads the sidecar and decides:

- **Next step is `safe`** → auto-resume, notify owner via Telegram
- **Next step is `needs-approval`** → check for a durable approval token on disk; if found, resume; if not, ask the owner and wait
- **Next step is `destructive`** → never auto-resume, set idle, notify the owner
- **Too many retries** (≥2) → escalate ("task too large, consider breaking up")
- **Too stale** (>2 hours) → set idle, notify the owner

Approval tokens are written to disk and survive session crashes — if the owner says "yes" but the bot dies before executing, the next session finds the token and proceeds without re-asking.

See [examples/auto-resume/](../examples/auto-resume/) for the full implementation.

---

## Problem #21: Background Workers Conflict with Live Sessions

### What happens

The auto-resume system spawns a `claude -p` subprocess (the "resume worker") to continue interrupted work. Meanwhile, the Telegram channel bot is running in the same tmux session. Both processes try to read and write the same state file. Result: race conditions, corrupted state, or one process overwriting the other's changes.

### What we do now: Lock-Aware PreToolUse Gate

A Python-based PreToolUse hook (`bot-lock-gate.py`) that uses `flock` to detect when the resume worker holds the lock:

1. **If lock is held**: block all substantive tool calls (Bash, Edit, Write) from the Telegram session. Read-only tools (Read, Grep, Glob) pass through — the bot can still investigate, it just can't modify anything.
2. **Stale-write guard**: while the lock was held, the gate records every file path the bot tried to write. After the lock releases, those paths are "stale" — the bot must Read them first (to pick up the resume worker's changes) before Writing.
3. **Lock released**: normal operation resumes, with the stale-path check enforced.

This prevents the Telegram session from clobbering resume worker output, without blocking reads.

See [examples/lock-gate/](../examples/lock-gate/) for the implementation.

---

## Problem #22: Stale Lock Files Block Operations

### What happens

A process crashes while holding a `.lock` file. The file stays on disk even though no process holds the lock. The next time a bot or cron job tries to acquire the lock, it blocks forever — the lock is "held" by a process that no longer exists.

### What we do now: Stale Lock Janitor

A cron job (`stale-lock-janitor.sh`) that safely detects and removes orphaned locks:

1. For each `.lock` file, try `flock -n` (non-blocking) to test if any process actually holds it
2. If the lock is acquirable (no process holds it) AND the file is older than a grace window (default: 10 minutes), delete it
3. If the lock is held by a live process, leave it alone

The grace window prevents a race: a lock file that was just created might not be held yet (the process is between `open()` and `flock()`). Waiting 10 minutes ensures we only delete truly orphaned locks.

Supports `--dry-run` mode to see what it would delete without actually deleting.

See [examples/stale-lock-janitor/](../examples/stale-lock-janitor/) for the implementation.

---

## Problem #23: Local LLM Requests Are Uncoordinated

### What happens

Multiple cron jobs, hooks, and bots need local inference (email classification, document summaries, structured extraction). Without coordination:
- Concurrent requests to the same GPU cause OOM or slow everything down
- On-demand models stay loaded forever, wasting VRAM
- Crashed requests are silently lost

### What we do now: Journal-Based GPU Queue Daemon

A single-instance daemon that manages all local LLM dispatch:

**Architecture:**
```
Clients (cron, hooks, bots)
    |  enqueue via gpu-queue-client.sh
    v
[queue.jsonl]  <-- append-only journal
    |
gpu-queue-daemon.py (single instance via flock)
    |  dispatch by priority
    |-- :8080  model-a  (always-on, resident)
    |-- :8081  model-b  (on-demand, start/stop via systemd)
    +-- :8082  embed    (always-on, resident)
```

**Key features:**
- **Priority scheduling**: interactive (10s timeout) > inbox-digest (60s) > evidence-pack (600s) > eod-digest (1800s) > index-rebuild (7200s). Every 5th dispatch picks the oldest request regardless of priority (fairness).
- **On-demand model lifecycle**: expensive models start on first request (`systemctl --user start`), wait for health check, dispatch, then unload after 15 minutes idle (`systemctl --user stop`). Saves VRAM when not in use.
- **Crash recovery via lease_epoch**: on startup, the daemon replays the journal. Requests dispatched under a previous lease_epoch without completion are marked `daemon-restart`. Requests past their hard deadline are `queue-stale`. No request is silently lost.
- **Single-instance via flock**: prevents two daemons from running simultaneously.

See [examples/gpu-queue/](../examples/gpu-queue/) for the implementation.

---

## Problem #24: Cron Jobs Need Structured LLM Output Cheaply

### What happens

Cron jobs that need structured output (JSON classification, extracted fields, yes/no decisions) currently call the cloud API via `claude -p`. This works but counts against your Claude Max quota and is slow for simple tasks. For routine classification and extraction, a local LLM with grammar constraints is faster and free.

### What we do now: Grammar-Constrained Local Inference

A shell script (`local-infer-structured.sh`) that calls a local llama.cpp server with GBNF grammar constraints:

```bash
# Classify an email as urgent/normal/spam
local-infer-structured.sh \
  --grammar "root ::= (\"urgent\" | \"normal\" | \"spam\")" \
  --prompt "Classify this email: $EMAIL_BODY"
```

**Key features:**
- **GBNF grammar support**: constrains the model output to match a grammar, so you always get valid structured output (no JSON parsing failures, no hallucinated fields)
- **Telemetry**: logs every call to a JSONL file (model, grammar, latency, token count) for monitoring
- **Retry logic**: retries on connection failure (the local server may be starting up)
- **Queue integration**: can enqueue through the GPU queue daemon for priority scheduling

This is not a replacement for Claude — it's for routine tasks where you need structured output cheaply: email triage, log classification, simple extraction.

See [examples/local-inference/](../examples/local-inference/) for the implementation.

---

## Problem #25: File-Based Inbox Doesn't Scale

### What happens

The v1 inter-agent inbox (Problem #11) uses markdown files. This works for 2-3 bots but breaks down as the fleet grows:
- **Race conditions**: two bots writing to the same inbox.md simultaneously can corrupt it
- **No threading**: responding to a specific message requires matching MSG-IDs by hand
- **No delivery tracking**: the sender has no confirmation the message was received
- **Polling overhead**: every bot checks every inbox before every reply

### What we do now: SQLite-Based Real-Time Messaging (v3)

A SQLite database replaces inbox.md files:

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
  delivered_at TEXT
);
```

**Key improvements over v1:**
- **Atomic writes**: SQLite handles concurrent access natively — no corruption risk
- **Threading**: `reply_to` and `thread_id` fields link conversations
- **Delivery tracking**: `recipients.delivered` is set when the bot reads the message
- **Dedupe**: `dedupe_key` prevents duplicate messages after crash recovery
- **Wake-file notifications**: after inserting a message, the sender touches a wake-file (`~/.claude/interbot-wake/<bot-name>`). The recipient's channel plugin picks up the notification in real-time — no polling needed.

The v1 inbox system still works for simple setups. v3 is for fleets where race conditions or delivery reliability matter.

See [examples/inter-agent/](../examples/inter-agent/) for the schema and sender script.

---

## Problem #26: Watchdog Itself Goes Down Silently

### What happens

The watchdog (Problem #5) auto-restarts baked bots every 5 minutes. But it's a cron job — if cron breaks, or the watchdog script has a bug, or the machine is under heavy load and skips cron runs, nobody notices. The bots go down and stay down.

### What we do now: Fleet Heartbeat (Dead-Man's-Switch)

A separate script (`fleet-heartbeat-check.sh`) that monitors the watchdog itself:

1. **Checks the watchdog's tick file**: the watchdog writes a timestamp to a heartbeat file on every run. If the timestamp is older than 15 minutes (3 missed cycles), the heartbeat script alerts.
2. **Checks all bot tmux sessions**: independently verifies that each bot's tmux session exists and is responsive.
3. **Alert suppression**: doesn't spam you on every check — alerts once, then suppresses for 30 minutes to avoid notification fatigue.

Run this from a separate cron entry (every 10 minutes). It's a safety net for the safety net.

See [examples/fleet-heartbeat/](../examples/fleet-heartbeat/) for the implementation.

---

## Problem #27: No Fleet-Level Metrics

### What happens

You can tell if a bot is "up" (watchdog) and if the watchdog is running (heartbeat), but you can't answer questions like: "What's the average bake rate this week?" "How long do sessions last?" "Is the GPU queue backing up?" Without metrics, you're flying blind on fleet health trends.

### What we do now: Prometheus Textfile Emitter

A shell script (`fleet-metrics.sh`) that writes Prometheus-compatible metrics to a textfile:

```
# HELP fleet_bot_session_age_seconds Age of current bot session in seconds
# TYPE fleet_bot_session_age_seconds gauge
fleet_bot_session_age_seconds{bot="cos"} 3847
fleet_bot_session_age_seconds{bot="cto"} 12453

# HELP fleet_bot_bake_total Number of times bot has baked (hit context limit)
# TYPE fleet_bot_bake_total counter
fleet_bot_bake_total{bot="cos"} 14
fleet_bot_bake_total{bot="cto"} 7
```

**Key features:**
- **Thread-safe**: uses `flock` for atomic writes — safe to call from multiple cron jobs simultaneously
- **Dual-mode**: use as a shell library (`source fleet-metrics.sh; metric_gauge ...`) or as a CLI (`fleet-metrics.sh gauge bot_session_age 3847 bot=cos`)
- **Prometheus-compatible**: if you run Prometheus + node_exporter with the textfile collector, you get dashboards and alerting for free. Without Prometheus, the textfile is still human-readable.

Run via cron (every 5 minutes) alongside the watchdog to build up time-series data on fleet health.

See [examples/fleet-metrics/](../examples/fleet-metrics/) for the implementation.

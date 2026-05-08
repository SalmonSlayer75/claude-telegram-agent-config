# Mindspan Labs Agents

Battle-tested configuration for running a fleet of Claude Code bots as 24/7 Telegram agents with persistent memory, automatic recovery, interrupted-work resumption, local LLM inference, inter-agent coordination, behavioral learning, fleet metrics, and 45+ reusable agent skills.

## What This Is

We run six Claude Code bots on a single machine via Telegram — a **Chief of Staff** (email, calendar, admin), a **CTO** (cross-project architecture, standards), two **VP Engineering** bots (one per project), a **DevOps** lead (fleet management), and a **Product Marketing** agent (research, content). After months in production, we hit real problems and built solutions for each one. This repo contains those solutions as reusable templates.

**What you get**: You message a Telegram bot from your phone, and Claude Code responds — with full access to your codebase, files, terminal, databases, and any MCP tools you've configured. It remembers what you were working on across session restarts, coordinates with other bots via an inbox system, proactively does things on a schedule, and auto-recovers when it hits context limits.

---

## The Problems We Solved

| # | Problem | Solution | Docs |
|---|---------|----------|------|
| 1 | **Bot forgets everything after restart** — context window fills up, session "bakes", all conversation history is lost | Structured state file + mandatory save-before-reply hooks | [State File & Hooks](docs/state-file-and-hooks.md) |
| 2 | **No scheduled/proactive behavior** — bot only responds when messaged | Cron scripts running `claude -p` one-shots, independent of the channel bot | [Cron Jobs](docs/cron-jobs.md) |
| 3 | **Bot can't access files outside working directory** | `--add-dir` flags in start scripts | [Start Scripts](examples/start-scripts/) |
| 4 | **Multiple bots producing conflicting information** | Explicit role boundaries and redirect rules in CLAUDE.md | [Role Isolation](docs/role-isolation.md) |
| 5 | **Bot reports "RUNNING" but is actually dead** — tmux session exists but Claude is idle at the prompt | Watchdog cron that inspects the tmux pane and auto-restarts baked bots | [Watchdog](examples/watchdog/) |
| 6 | **WSL doesn't auto-start bots on Windows reboot** | Windows Startup batch file + boot script + systemd | [WSL Auto-Start](docs/wsl-autostart.md) |
| 7 | **Bot can't search its own history** — weeks of context across scattered files | SQLite FTS5 search index across all memory files | [Memory Search](examples/memory-search/) |
| 8 | **Bot doesn't learn about you over time** — re-explain preferences every session | Structured user profile + PostToolUse learning loop | [Personalization](docs/personalization.md) |
| 9 | **Context compaction loses important state** | PreCompact emergency save + PostCompact reload | [Compaction Hooks](docs/extensions.md#problem-9-context-compaction-loses-important-state) |
| 10 | **Credentials scattered across scripts** | Centralized env file sourced by all scripts | [Credentials](examples/credentials/) |
| 11 | **Bots can't coordinate with each other** — tasks that span roles fall through the cracks | File-based inbox system with priority routing and hook-driven checks | [Inter-Agent Communication](docs/inter-agent-communication.md) |
| 12 | **Hook changes are error-prone across many bots** — manual edits to 6 settings files is fragile | Fleet hook automation script that generates validated configs for all bots | [Fleet Hooks](examples/fleet-hooks/) |
| 13 | **Bot ignores "save your state" reminders** — under pressure, soft reminders get skipped and context is lost | Hard gate that blocks substantive tool calls until state file is updated | [Bot Gate](examples/bot-gate/) |
| 14 | **Bot doesn't learn from experience** — same mistakes repeated across sessions | Automated observation → pattern detection → instinct injection pipeline | [Instinct Learning](examples/instinct-learning/) |
| 15 | **Hook count grows unmanageable** — 10+ hooks slow development, interfere with debugging | Runtime profiles (minimal/standard/strict) that gate which hooks run | [Hook Profiles](examples/hook-profiles/) |
| 16 | **Bot weakens linter/CI configs** to "fix" failures instead of fixing the code | PreToolUse hook that blocks edits to protected config files | [Config Protection](examples/config-protection/) |
| 17 | **One-shot tasks need different models** for different phases (implement vs review) | Automated PR pipeline with model routing per phase | [Continuous PR Loop](examples/continuous-pr-loop/) |
| 18 | **No guardrails on dangerous commands** — `dontAsk` mode gives broad access with no safety net | Deny rules that block destructive git, credential access, and remote code execution | [Security Deny Rules](examples/security-deny-rules/) |
| 19 | **No visibility into fleet health** — problems discovered only when the owner notices a bot is broken | Daily automated review: gather all logs, feed to Claude, get prioritized report | [Fleet Review](examples/fleet-review/) |
| 20 | **Session dies mid-task, work abandoned** — multi-step work (deploy, migrate, review) lost on crash | JSON sidecar tracks steps + safety classification; auto-resumes safe steps, asks approval for risky ones | [Auto-Resume](examples/auto-resume/) |
| 21 | **Background workers conflict with live sessions** — resume worker and Telegram session write same state | Lock-aware PreToolUse gate blocks substantive writes while flock is held; stale-write guard prevents stale reads | [Lock Gate](examples/lock-gate/) |
| 22 | **Stale lock files block operations** — crashed processes leave orphaned .lock files | Janitor uses `flock -n` to detect unheld locks; only deletes locks older than grace window | [Stale Lock Janitor](examples/stale-lock-janitor/) |
| 23 | **Local LLM requests are uncoordinated** — multiple cron jobs hit the GPU simultaneously | Journal-based queue daemon with priority dispatch, on-demand model lifecycle, crash recovery | [GPU Queue](examples/gpu-queue/) |
| 24 | **Cron jobs need structured LLM output cheaply** — cloud API calls are expensive for routine tasks | Grammar-constrained local inference with GBNF support, telemetry, and retry logic | [Local Inference](examples/local-inference/) |
| 25 | **File-based inbox doesn't scale** — race conditions, no threading, no delivery tracking | SQLite-based real-time messaging with threading, dedupe, delivery state, and wake-file notifications | [Inter-Agent v3](examples/inter-agent/) |
| 26 | **Watchdog itself goes down silently** — nobody watches the watcher | Dead-man's-switch: verifies watchdog tick + all bot tmux sessions, with alert suppression | [Fleet Heartbeat](examples/fleet-heartbeat/) |
| 27 | **No fleet-level metrics** — can't track bake rates, session ages, queue depths over time | Prometheus textfile emitter: thread-safe counters/gauges, dual-mode (library + CLI) | [Fleet Metrics](examples/fleet-metrics/) |

---

## Quick Start

### New to all of this? Start here:
1. Read the **[How-To Guide](docs/how-to-guide.md)** — a step-by-step walkthrough with explanations of *why* each piece exists, aimed at PMs and operators (not just engineers)

### Want the technical reference instead?
1. Follow the [Base Setup Guide](docs/base-setup-guide.md) to get a working Telegram bot

### Already have a working bot? Add these in order:

**Priority 1 — Watchdog** (5 min, biggest reliability win):
- Copy [examples/watchdog/claude-bot-watchdog.sh](examples/watchdog/claude-bot-watchdog.sh)
- Customize the bot names, tmux sockets, and tokens
- Add to crontab: `*/5 * * * * ~/bin/claude-bot-watchdog.sh all >> ~/.claude/channels/watchdog.log 2>&1`
- Your bot will now auto-recover within 5 minutes of hitting context limits

**Priority 2 — Persistent Memory** (10 min):
- Copy a [state file template](examples/state-files/) into your project directory
- Copy the [user profile template](examples/personalization/user-profile-template.md) and fill in your basics
- Add the [CLAUDE.md instructions](docs/state-file-and-hooks.md#layer-2-aggressive-claudemd-instructions) to your bot's CLAUDE.md
- Add the [hooks config](examples/hooks/settings.local.json) to your project's `.claude/settings.local.json` (includes mandatory state-save gates + all 4 lifecycle hooks)
- Set up [credentials](examples/credentials/bot-credentials.env.example) in `~/.claude/bot-credentials.env`
- Your bot will now remember action items, decisions, context, and learn your preferences over time

**Priority 3 — Scheduled Tasks** (15 min per task):
- Copy the [cron script template](examples/cron-scripts/scheduled-task-template.sh)
- Customize the prompt and delivery method
- Add to crontab
- Your bot will now do things proactively without being asked

**Priority 4 — Memory Search** (15 min, long-term recall):
- Copy the [memory search scripts](examples/memory-search/) to `~/bin/` and `chmod +x` them
- Edit the `AGENT_SOURCES` / `AGENT_DIRS` dicts to match your directory layout
- The hooks config already calls `memory-search --index` at session start — the bot can now search its own history

**Priority 5 — Agent Skills** (drop-in):
- Browse [examples/agent-skills/](examples/agent-skills/) for reusable slash commands
- Copy any `.md` file into your project's `.claude/commands/` directory
- The bot can now run specialized audits, reviews, and analysis on demand

**Priority 6 — Inter-Agent Communication** (15 min, multi-bot only):
- Follow the [Inter-Agent Communication](docs/inter-agent-communication.md) guide
- Copy the [inbox-check script](examples/inter-agent/inbox-check) to `~/bin/`
- Each bot gets an `inbox.md` file and hooks that auto-check it before every reply

**Priority 7 — Fleet Hook Automation** (10 min, 3+ bots):
- Copy [examples/fleet-hooks/update-fleet-hooks.js](examples/fleet-hooks/update-fleet-hooks.js)
- Configure your bot definitions
- Run once to generate all hooks configs, re-run whenever you change the fleet

---

## Prerequisites

- **Claude Code CLI** installed and authenticated
- **Claude Max or Team subscription** (the bot uses your account's API quota)
- **Linux with systemd** (native or WSL2)
- **Telegram bot** created via [@BotFather](https://t.me/BotFather)
- **tmux** installed (`sudo apt install tmux`)

---

## Repository Structure

```
docs/
  how-to-guide.md                  # Complete walkthrough for PMs/operators (start here)
  base-setup-guide.md              # Technical reference: from zero to working Telegram bot
  extensions.md                    # Full writeup of all production additions
  personalization.md               # User profile learning loop pattern
  state-file-and-hooks.md          # Deep dive: persistent memory across restarts
  cron-jobs.md                     # Deep dive: scheduled one-shot tasks
  role-isolation.md                # Deep dive: multi-bot coordination
  wsl-autostart.md                 # WSL-specific auto-start on Windows boot
  inter-agent-communication.md     # Inter-agent inbox system + coordination patterns

examples/
  start-scripts/                   # Bot start scripts with --add-dir and zombie cleanup
    work-bot-start.sh

  watchdog/                        # Auto-restart bots that hit context limits
    claude-bot-watchdog.sh         # With sentinel paging, debounce, and local-model backoff

  cron-scripts/                    # Templates for scheduled tasks
    scheduled-task-template.sh     # With flock, stderr capture, --max-turns

  hooks/                           # Claude Code hooks — full 4-hook lifecycle
    settings.local.json            # With mandatory state-save gates

  fleet-hooks/                     # Fleet-wide hook management
    update-fleet-hooks.js          # Generate hook configs for all bots at once

  inter-agent/                     # Inter-agent coordination
    inbox-check                    # v1: Check bot inbox for new messages (file-based)
    inbox-template.md              # Template for bot inbox files
    interbot-send-v3               # v3: SQLite-based real-time message sender
    schema.sql                     # SQLite schema for interbot messaging

  state-files/                     # Structured state file templates
    bot-state.md                   # General-purpose bot
    engineering-bot-state.md       # Engineering-focused bot

  memory-search/                   # SQLite FTS5 search across all bot memory
    memory-search                  # Search/index tool (Python)
    memory-log-conversation        # Log exchanges to conversation log + daily note
    memory-daily-init              # Initialize today's daily note

  personalization/                 # User profile learning loop
    user-profile-template.md       # Template for structured user profile

  credentials/                     # Centralized secret management
    bot-credentials.env.example

  wsl-autostart/                   # Auto-start bots on Windows boot
    wsl-boot.sh                    # Linux-side boot script
    wsl-claude-bots.bat            # Windows Startup folder batch file

  logrotate/                       # Log rotation config
    logrotate.conf

  management/                      # Bot lifecycle management
    claude-bot                     # start/stop/restart/status/logs for all bots

  bot-gate/                        # Hard state-save enforcement gate
    bot-gate.py                    # Unified gate with arm/check/stop-warn modes
    gate-lists.sh                  # Tool classification (exempt vs substantive)
    active-conversation-hash       # AC section hasher (required by bot-gate.py)

  hook-profiles/                   # Runtime hook gating by profile level
    hook-profile-gate.sh           # minimal/standard/strict profile wrapper

  config-protection/               # Block edits to linter/formatter/CI configs
    config-protection.sh           # PreToolUse hook for protected files

  instinct-learning/               # Automated behavioral learning system
    instinct-observe.py            # PostToolUse hook — captures observations
    instinct-observer.py           # Pattern detector — creates instincts
    instinct-cli.py                # CLI for managing instincts

  continuous-pr-loop/              # Automated implement→review→merge pipeline
    continuous-pr-loop.sh          # Multi-phase PR automation with model routing

  fleet-review/                     # Automated daily fleet health report
    fleet-review.sh                # Gather logs + Claude analysis → Telegram

  security-deny-rules/             # Permission deny rules for safety
    settings.json.example          # Recommended deny rules template

  auto-resume/                     # Interrupted work recovery (problem 20)
    bot-auto-resume.sh             # Detection engine: reads sidecar, checks safety, emits resume prompt
    ac-resume-write.sh             # Fallback atomic sidecar writer

  lock-gate/                       # Concurrent access protection (problem 21)
    bot-lock-gate.py               # flock-based PreToolUse gate with stale-write guard

  stale-lock-janitor/              # Orphaned lock cleanup (problem 22)
    stale-lock-janitor.sh          # flock -n probe + grace window + dry-run mode

  gpu-queue/                       # Local LLM dispatch daemon (problem 23)
    gpu-queue-daemon.py            # Priority scheduler with on-demand model lifecycle
    gpu-queue-client.sh            # CLI: enqueue, status, wait

  local-inference/                 # Grammar-constrained local LLM (problem 24)
    local-infer-structured.sh      # GBNF grammar + telemetry + retry

  fleet-heartbeat/                 # Dead-man's-switch monitor (problem 26)
    fleet-heartbeat-check.sh       # Watches-the-watcher with alert suppression

  fleet-metrics/                   # Prometheus-compatible metrics (problem 27)
    fleet-metrics.sh               # Thread-safe counter/gauge emitter (library + CLI)

  lib/                             # Shared shell libraries
    auto-resume-paths.sh           # Per-bot state directory lookup table
    page-telegram.sh               # Validated Telegram sender with retry-as-plain fallback

  agent-skills/                    # 45 reusable Claude Code slash commands
    README.md                      # Full catalog with descriptions
    vpe-workflow/                  # Plan -> Review -> Ship workflow (4 skills)
    auditors/                      # Specialized code review lenses (8 skills)
    development/                   # Building, fixing, and analyzing code (15 skills)
    quality/                       # Testing, review, and diagnostics (6 skills)
    ux-design/                     # UX, design systems, and content (5 skills)
    agent-coordination/            # Multi-agent workflows (3 skills)
```

---

## How It All Fits Together

```
┌─────────────────────────────────────────────────────┐
│                    Your Phone                        │
│                   (Telegram)                         │
└──────────────────────┬──────────────────────────────┘
                       │
     ┌─────────┬───────┼───────┬─────────┬──────────┐
     │         │       │       │         │          │
  @cos_bot  @cto_bot  @vpe1  @vpe2  @devops   @mktg_bot
     │         │       │       │         │          │
┌────┴────┐ ┌──┴──┐ ┌──┴──┐ ┌──┴──┐ ┌────┴────┐ ┌──┴──┐
│  tmux   │ │tmux │ │tmux │ │tmux │ │  tmux   │ │tmux │
│ session │ │sess.│ │sess.│ │sess.│ │ session │ │sess.│
│         │ │     │ │     │ │     │ │         │ │     │
│ Claude  │ │Clau-│ │Clau-│ │Clau-│ │ Claude  │ │Clau-│
│ Code    │ │de   │ │de   │ │de   │ │ Code    │ │de   │
│--channel│ │Code │ │Code │ │Code │ │--channel│ │Code │
│         │ │     │ │     │ │     │ │         │ │     │
│CLAUDE.md│ │     │ │     │ │     │ │CLAUDE.md│ │     │
│state.md │ │     │ │     │ │     │ │state.md │ │     │
│inbox.md │ │     │ │     │ │     │ │inbox.md │ │     │
└────┬────┘ └──┬──┘ └──┬──┘ └──┬──┘ └────┬────┘ └──┬──┘
     │         │       │       │         │          │
     └─────────┴───────┼───────┴─────────┴──────────┘
                       │
              ┌────────┴────────┐
              │   Watchdog      │
              │   (cron 5min)   │
              │   Auto-restart  │
              └────────┬────────┘
                       │
              ┌────────┴────────┐
              │   Cron Jobs     │
              │   (claude -p)   │
              │   Scheduled     │
              │   one-shots     │
              └─────────────────┘
```

---

## Key Concepts

### State File = Working Memory
The bot writes a structured markdown file after every interaction. On restart, it reads this file first. This is how it "remembers" across sessions. Hooks enforce the discipline — the bot is **blocked from replying** until it saves unsaved state.

### Mandatory State-Save Gates (Production-Hardened)
The original "reminder" hooks were too gentle — bots would ignore them under pressure. The production fix: a **PreToolUse gate** on the Telegram reply tool that forces the bot to save state BEFORE it can send a reply. This is the single most important reliability improvement we made.

### 4-Hook Lifecycle = Nothing Falls Through the Cracks
Four hooks cover the full session lifecycle: **PreToolUse** loads state on first reply + gates every reply behind a state save, **PostToolUse** enforces a mandatory post-reply save, **PreCompact** is a last-chance emergency save before context compaction, **PostCompact** reindexes and reloads after compaction.

### User Profile = Long-Term Learning
A structured markdown file where the bot records what it learns about you — preferences, relationships, scheduling habits, communication style. Updated incrementally via PostToolUse hooks. Compounds over weeks into genuine personalization.

### Memory Search = Searchable History
SQLite FTS5 index across all bot files — state, profiles, daily notes, conversation logs, Claude Code memory files. The bot can search its own history when it needs to recall past decisions or context.

### Watchdog = Self-Healing
When Claude hits its context limit, the conversation "bakes" and the bot goes idle. The tmux session is still running, so `status` says RUNNING, but the bot is deaf. The watchdog inspects what's actually on the tmux screen every 5 minutes and restarts baked bots automatically.

### Cron One-Shots = Proactive Behavior
Scheduled tasks use `claude -p` (one-shot prompt mode), completely independent of the channel bot. They fire, run a prompt, send results to Telegram, and exit. The channel bot stays alive for interactive messages.

### Role Isolation = No Conflicts
Each bot's CLAUDE.md defines what it owns, what it must not do, and how to redirect questions to the other bot. Bots coordinate through files and databases, not shared memory.

### Inter-Agent Inbox = Asynchronous Coordination
Each bot has an `inbox.md` file. Bots write messages to each other's inboxes with priority levels and status tracking. A PreToolUse hook checks the inbox before every reply, so bots pick up messages automatically without polling.

### Fleet Hook Automation = Consistent Configuration
A Node.js script generates `.claude/settings.local.json` for all bots from a single config. When you need to change a hook pattern fleet-wide, edit one file and regenerate.

### Bot Gate = Hard State-Save Enforcement
The original "save your state" reminders were too gentle — bots ignore them under pressure. The bot gate is a PreToolUse hook that **blocks** substantive tool calls unless the bot has recently updated its state file. Two invariants: acknowledge new messages before working, and checkpoint every 10 tool calls.

### Instinct Learning = Behavioral Improvement Over Time
A three-stage pipeline: observe tool usage → detect recurring patterns → inject learned instincts into future sessions. Instincts have confidence scores that increase with evidence and decay over time, with a hard cap at 0.85 (never fully trust automated learning).

### Hook Profiles = Controlled Overhead
As hook count grows (15+ per bot), you need runtime control. Three profiles — minimal (debugging), standard (production), strict (critical operations) — gate which hooks execute. Individual hooks can also be disabled by ID.

### Security Deny Rules = Last Line of Defense
Deny rules in `settings.json` that block dangerous commands regardless of what the conversation says: no `git push --force`, no reading SSH keys, no `curl|bash`, no credential file access. These override all allow rules.

### Auto-Resume = Interrupted Work Recovery
Sessions die mid-task. A JSON sidecar tracks each step's completion status and safety classification (`safe`, `needs-approval`, `destructive`). On restart, the resume engine checks safety rails (staleness, attempt limits) and either auto-resumes safe steps, requests approval for risky ones, or escalates to the owner. Durable approval tokens survive session crashes.

### Lock Gate = Concurrent Access Protection
When a background worker (`claude -p`) holds a flock on shared state, the live Telegram session's substantive writes are blocked. Read-only tools always pass. A stale-write guard tracks paths denied during lock-hold — the bot must Read them before Writing after the lock releases.

### GPU Queue = Coordinated Local Inference
A single-instance daemon manages dispatch to local LLM backends (llama.cpp). Append-only JSONL journal for crash recovery. Priority scheduling with fairness override. On-demand model lifecycle: start on first request, unload after 15-minute idle.

### Fleet Heartbeat = Watches the Watcher
The watchdog restarts baked bots. But what if the watchdog itself dies? A separate dead-man's-switch monitors the watchdog's tick file and all bot tmux sessions, with alert suppression to avoid spam.

---

## Our Production Setup

For reference, here's what we actually run:

| Bot | Role | Cron Jobs | Integrations |
|-----|------|-----------|--------------|
| **COS** (Chief of Staff) | Email, calendar, admin, research | Timezone-aware briefings (every 30min, full at 6am/9am/noon/3pm/6pm local), weekly review (Fri 4pm) | Google Workspace, Notion, LinkedIn API, WebSearch |
| **CTO** | Cross-project architecture, standards, strategy | On-demand | Playwright, GitHub |
| **VPE-1** (VP Engineering) | Code review, PRs, architecture for Project A | On-demand | 45 agent skills, Playwright, GitHub |
| **VPE-2** (VP Engineering) | Code review, PRs, architecture for Project B | On-demand | 45 agent skills, Playwright, GitHub |
| **DevOps** | Fleet management, bot creation/maintenance | On-demand | All bot configs, systemd, cron |
| **Marketing** (Product Marketing) | Market research, content, thought leadership | Weekly research (Mon 6am), weekly use cases (Tue 6am) | Google Workspace, WebSearch |

All bots share:
- Isolated tmux sessions with separate sockets
- Structured state files with mandatory save-before-reply hooks
- Watchdog monitoring (5-min cron)
- Auto-start via systemd on boot
- Explicit role boundaries preventing overlap
- Inter-agent inbox for async coordination
- Memory search for long-term recall
- User profile for personalization

---

## Credits

- Base setup guide by [Peter Steinberger](https://github.com/steipete)
- Extensions and agent skills by the community contributors and Claude

## License

MIT — use however you like.

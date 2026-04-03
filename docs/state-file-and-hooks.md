# Persistent Memory: State File + Hooks

The biggest problem with running Claude Code as a 24/7 Telegram agent is **memory loss**. When a conversation hits the context limit, the session ends and restarts fresh. Everything discussed — action items, decisions, pending tasks — is gone.

This guide shows how to give your bot persistent working memory that survives session restarts.

## The Problem

Claude Code channel sessions have a finite context window. When it fills up, the session "bakes" (ends) and goes idle. After restart, it's a blank slate. The bot literally forgets what you were just talking about.

## Why "Save at End of Session" Doesn't Work

We tried adding CLAUDE.md instructions like: "At the end of each meaningful interaction, save context to a log file."

This fails because:
- The bot often hits the context limit **unexpectedly** — the session dies before it gets a chance to write
- It relies on the bot **remembering** to do something before an event it can't predict
- It's too passive — "at the end of" is a weak instruction for an LLM

## The Solution: Three Layers

### Layer 1: Structured State File

Create a markdown file in your bot's working directory that serves as its working memory:

```markdown
# Bot State
<!-- Auto-updated after every substantive interaction. Read at conversation start. -->
<!-- Last updated: YYYY-MM-DDTHH:MMZ -->

## Open Threads
<!-- Active conversations or tasks in progress. Remove when resolved. -->

## Pending Action Items
<!-- Format: - [ ] [item] | owner: [who] | due: [date] | source: [where] -->

## Recent Decisions (last 7 days)
<!-- Format: - [decision] (YYYY-MM-DD) -->

## Waiting On Human
<!-- Things the bot needs human input on before proceeding -->

## Context Carry-Forward
<!-- Important context from recent conversations that would be lost on restart -->
```

See [examples/state-files/](../examples/state-files/) for templates.

### Layer 2: Aggressive CLAUDE.md Instructions

Add this to your bot's CLAUDE.md:

```markdown
- **CRITICAL — Maintain state across restarts:** Your conversation WILL end unexpectedly
  (context limit, crash, restart). You WILL lose everything in your conversation history.
  The ONLY thing that survives is what you write to disk. To compensate:
  - **Read your state file at the START of every conversation** — this is your working memory
  - **Update it IMMEDIATELY after every substantive interaction** — do NOT wait until
    session end, because session end may never come
  - After every Telegram exchange where something was decided, requested, or committed to:
    update the state file RIGHT THEN
  - Prune "Recent Decisions" older than 7 days; prune "Context Carry-Forward" older than 3 days
```

Key principles:
- **"WILL end unexpectedly"** — urgency matters for LLM instruction-following
- **"IMMEDIATELY after"** — write after each exchange, not at session end
- **Explicit pruning rules** — prevent unbounded growth

### Layer 3: Hooks (Mandatory State-Save Gates)

Instructions alone aren't enough. Gentle reminders get ignored under pressure. The production-hardened approach: **gate every Telegram reply behind a mandatory state save.**

Add to your project's `.claude/settings.local.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "mcp__plugin_telegram_telegram__reply",
        "hooks": [
          {
            "type": "command",
            "command": "if [ ! -f /tmp/mybot-state-loaded ]; then echo '[STARTUP] Read ~/myproject/bot-state.md FIRST to restore your working memory before replying.'; touch /tmp/mybot-state-loaded; fi"
          }
        ]
      },
      {
        "matcher": "mcp__plugin_telegram_telegram__reply",
        "hooks": [
          {
            "type": "command",
            "command": "echo '[MANDATORY STATE SAVE] BEFORE sending this reply: Do you have ANY unsaved analysis, findings, decisions, or context that are NOT yet in ~/myproject/bot-state.md? If YES: STOP. Write them to your state file FIRST, THEN send this reply. Your conversation can end at any moment — if it is not in your state file, it is LOST. This is not optional.'"
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
            "command": "echo '[MANDATORY] You just sent a Telegram reply. Update ~/myproject/bot-state.md NOW with any decisions, action items, or context from this exchange. Do NOT skip this — your conversation can reset at any moment and anything not in the state file will be permanently lost.'"
          }
        ]
      }
    ]
  }
}
```

**How it works:**
- **PreToolUse (startup)** fires before the first Telegram reply of a new session. A `/tmp/` flag file tracks whether the bot has read its state file. Flag resets on reboot.
- **PreToolUse (mandatory save)** fires before **every** Telegram reply — forces the bot to save state BEFORE it can respond. This is the critical reliability improvement over gentle post-reply reminders.
- **PostToolUse** fires after **every** Telegram reply — a second enforcement to capture anything from that exchange.

> **Why mandatory gates, not reminders?** We ran gentle "reminder" hooks for weeks. Bots would consistently ignore them when under pressure (long conversations, complex tasks). The mandatory PreToolUse gate changed the dynamic — the bot now saves state as a precondition for replying, not as an afterthought.

See [examples/hooks/settings.local.json](../examples/hooks/settings.local.json) for the complete 4-hook lifecycle config.

## How the Layers Work Together

1. **Bot starts** (fresh session, no context)
2. **PreToolUse startup hook fires** → "Read your state file first!"
3. Bot reads state file → knows what was happening before the restart
4. User sends a message, bot prepares to reply
5. **PreToolUse mandatory-save hook fires** → "Save unsaved state BEFORE replying!"
6. Bot writes any pending state to state file
7. Bot replies to the user on Telegram
8. **PostToolUse hook fires** → "Update state file with this exchange NOW!"
9. Bot captures decisions/items from the reply
10. Repeat 4-9 for every interaction
11. Session eventually bakes → state file is already up to date
12. Go to step 1

The key insight: **don't rely on the bot to remember — gate its actions behind mandatory persistence.**

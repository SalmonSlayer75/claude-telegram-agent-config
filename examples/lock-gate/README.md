# Lock Gate — Concurrent Access Protection

A PreToolUse hook that prevents live Telegram sessions from making substantive writes while a background worker (resume worker, mail-turn) is operating on shared state.

## The Problem

When a background `claude -p` subprocess runs against the same state files as the live Telegram session, both can write simultaneously. This causes state corruption — the live session writes based on stale reads while the worker is mid-operation.

## The Solution

`flock`-based mutual exclusion. The background worker holds an exclusive flock on a lock file. The PreToolUse hook probes the lock non-blockingly:
- **Lock not held** → all tools pass
- **Lock held** → read-only tools pass, substantive tools are denied with a retry message

### Stale-Write Guard

When a Write is denied during lock-hold, the target path is recorded. After the lock releases, that path remains guarded — the bot must Read it first (to get fresh contents) before Write is allowed. This prevents writes based on pre-lock-era reads. Edit/MultiEdit are unaffected because their `old_string` contract forces a fresh read.

## Tool Classification

Tools are classified via a JSON config file (`tool-classes.json`):

```json
{
  "read_only": ["Read", "Grep", "Glob", "Bash"],
  "substantive": ["Edit", "Write", "MultiEdit", "NotebookEdit", "WebFetch"],
  "substantive_prefixes": ["mcp__"],
  "bash_read_only_whitelist": ["ls", "cat", "head", "tail", "wc", "date", "pwd"],
  "bash_read_only_git_subcommands": ["status", "log", "diff", "show", "branch"]
}
```

Bash commands are further classified: if the command head is in the whitelist, it's read-only. Git subcommands have their own whitelist.

## Setup

1. Copy `bot-lock-gate.py` to `~/bin/`
2. Create `tool-classes.json` with your tool classification
3. Add as PreToolUse hook in `.claude/settings.local.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "python3 $HOME/bin/bot-lock-gate.py mybot --check"
        }]
      }
    ]
  }
}
```

## Design Decisions

- **Exit 0 always** — deny is communicated via JSON stdout, never via exit code
- **Fail-open** — missing config, unparseable stdin, or errors → allow (never block the session)
- **Non-blocking probe** — the flock test is instantaneous, no waiting

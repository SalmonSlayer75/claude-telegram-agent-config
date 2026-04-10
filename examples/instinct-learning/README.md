# Instinct Learning System

An automated system that observes bot behavior, detects recurring patterns, and injects learned "instincts" into future sessions — so the bot gradually gets better at its job without manual tuning.

## The Problem

AI agents make the same mistakes repeatedly across sessions. They don't learn from experience — every new conversation starts from scratch. You end up writing increasingly detailed CLAUDE.md instructions to cover every edge case, which bloats the prompt and wastes context.

## The Solution

A three-stage pipeline:

1. **Observe** — A PostToolUse hook captures every tool call (with secret scrubbing) to a JSONL log
2. **Analyze** — A pattern detector runs periodically, clustering observations into typed instincts with confidence scores
3. **Inject** — A session-start hook loads high-confidence instincts into the bot's context

### The Pipeline

```
Bot uses tools during normal work
  → instinct-observe.py captures each tool call to observations.jsonl
  → (periodically) instinct-observer.py analyzes patterns
  → Writes/updates instinct-*.yaml files with confidence scores
  → (on session start) instinct-cli.py apply outputs high-confidence instincts
  → Bot's SessionStart hook injects them as context
```

## Pattern Types

| Type | What it detects | Example |
|------|----------------|---------|
| `repeated_flow` | Same tool sequence used 3+ times | "Edit → Bash(test) → Edit seen 5 times" |
| `error_resolve` | Error followed by consistent fix | "Bash errors resolved by Edit 4 times" |
| `tool_preference` | Dominant tool choices | "Edit used 45% of the time" |
| `correction` | Approach changes after user feedback | "File X edited after every reply" |

## Confidence Scoring

- New instincts start at `0.3`
- Each additional observation bumps by `0.05`
- Maximum confidence capped at `0.85` (never fully trust automated learning)
- Instincts not seen in a run decay by `0.01` per cycle
- Instincts at confidence `0` are automatically pruned
- Only instincts above `0.5` are injected into sessions

## Files

- **instinct-observe.py** — PostToolUse hook, captures observations
- **instinct-observer.py** — Pattern detector, creates/updates instincts
- **instinct-cli.py** — CLI for listing, inspecting, applying, pruning instincts

## Setup

1. Copy all three scripts to `~/bin/` and `chmod +x`
2. Edit `BOT_WORKDIRS` in each file to match your fleet
3. Add the observation hook to `.claude/settings.local.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "command": "$HOME/bin/instinct-observe.py mybot",
        "timeout": 3000
      }
    ]
  }
}
```

4. Run the observer periodically (via cron or manually):

```bash
# Analyze patterns and update instincts
instinct-observer.py mybot

# Dry run to see what would be created
instinct-observer.py mybot --dry-run

# View stats
instinct-observer.py mybot --stats
```

5. Wire `instinct-cli.py apply` into your session start hook:

```bash
# In your bot-session-start.sh:
INSTINCTS=$($HOME/bin/instinct-cli.py mybot apply 2>/dev/null)
if [ -n "$INSTINCTS" ]; then
    # Include in the additionalContext JSON output
    CONTEXT="$CONTEXT\n\n$INSTINCTS"
fi
```

## CLI Usage

```bash
# List all instincts
instinct-cli.py mybot list

# Show details for a specific instinct
instinct-cli.py mybot show repeated-flow-edit-bash-edit

# Output instincts for context injection
instinct-cli.py mybot apply

# Remove zero-confidence instincts
instinct-cli.py mybot prune

# Start fresh
instinct-cli.py mybot reset
```

## Design Decisions

- **Confidence cap at 0.85** — Automated pattern detection can find false positives. Never let the system become so confident it overrides human judgment.
- **Secret scrubbing** — Observations strip tokens, passwords, and credentials before writing to disk.
- **Observation rotation** — Log rotates at 1MB to prevent unbounded growth.
- **Minimal YAML parser** — No PyYAML dependency. The instinct format is simple enough for a 20-line parser.
- **Never blocks the bot** — All observation/analysis errors are swallowed. The instinct system is advisory, not critical path.

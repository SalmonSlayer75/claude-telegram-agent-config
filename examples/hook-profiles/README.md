# Hook Runtime Profiles

As your hook count grows (we have 15+ per bot), you need a way to control which hooks run in which context. A development session doesn't need the full production gate stack, and debugging a specific issue requires disabling hooks that interfere.

## The Solution

A thin wrapper script that gates hook execution based on a runtime profile level.

### Profile Levels

| Profile | When to use | What runs |
|---------|-------------|-----------|
| `minimal` | Debugging, development | Only hooks marked `minimal` (bare minimum for safety) |
| `standard` | Normal production | Hooks marked `minimal` + `standard` (default) |
| `strict` | Critical operations | All hooks including expensive advisors and extra validation |

### Usage

Wrap each hook command in your `settings.local.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "command": "$HOME/bin/hook-profile-gate.sh pre:gate:check minimal -- $HOME/bin/bot-gate.py mybot --check",
        "timeout": 5000
      },
      {
        "command": "$HOME/bin/hook-profile-gate.sh pre:config:protect standard -- $HOME/bin/config-protection.sh",
        "timeout": 3000
      },
      {
        "command": "$HOME/bin/hook-profile-gate.sh pre:advisor:compaction strict -- $HOME/bin/compaction-advisor.sh mybot",
        "timeout": 5000
      }
    ]
  }
}
```

### Controlling the Profile

Set `HOOK_PROFILE` in the bot's start script or environment:

```bash
# In your start script:
export HOOK_PROFILE=standard
claude --channels

# For debugging:
HOOK_PROFILE=minimal claude --channels

# For critical deployments:
HOOK_PROFILE=strict claude --channels
```

### Disabling Specific Hooks

For surgical debugging, disable individual hooks by ID:

```bash
DISABLED_HOOKS="pre:gate:check,post:tg:heartbeat" claude --channels
```

### Hook ID Convention

`{phase}:{category}:{name}` — e.g., `pre:gate:check`, `post:state:save`, `compact-pre:memory:flush`

This makes it easy to grep for hooks, disable categories, and understand what each hook does at a glance.

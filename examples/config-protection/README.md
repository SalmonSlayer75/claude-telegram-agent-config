# Config Protection Hook

Prevents AI agents from "fixing" CI failures by weakening linter, formatter, or build configs.

## The Problem

When an AI agent encounters a failing lint check or test config issue, the path of least resistance is to edit the config — disable the rule, widen the threshold, add an ignore. This produces green CI with degraded code quality. We caught this multiple times in production: agents would silently relax ESLint rules or modify tsconfig settings to make errors go away.

## The Solution

A PreToolUse hook that blocks Edit/Write operations targeting known config files. The bot gets a clear message: "fix the source code, not the config."

### Protected Files

- **Linters**: `.eslintrc`, `biome.json`, `.ruff.toml`, `.stylelintrc`, `.shellcheckrc`
- **Formatters**: `.prettierrc`, `.editorconfig`
- **TypeScript**: `tsconfig.json`
- **Test configs**: `jest.config.*`, `vitest.config.*`
- **CI**: `.github/workflows/*`

### Setup

1. Copy `config-protection.sh` to `~/bin/` and `chmod +x`
2. Ensure `jq` is installed
3. Add to your bot's `.claude/settings.local.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "command": "$HOME/bin/config-protection.sh",
        "timeout": 3000
      }
    ]
  }
}
```

### Customization

Edit the `case` statement to add or remove protected patterns for your project. For example, to also protect Webpack configs:

```bash
webpack.config.*) ;;
```

### When the Bot Legitimately Needs to Edit Config

If you're intentionally asking the bot to update a config (e.g., "add a new ESLint rule"), you can either:
1. Temporarily disable the hook via `DISABLED_HOOKS` (if using hook-profile-gate.sh)
2. Make the edit yourself and tell the bot to continue

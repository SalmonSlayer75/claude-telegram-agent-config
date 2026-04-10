#!/bin/bash
# config-protection.sh — PreToolUse hook that blocks edits to linter/formatter/CI configs
#
# Problem: AI agents under pressure will "fix" failing CI checks by weakening
# the linter config, disabling rules, or lowering thresholds. This produces
# passing CI with worse code quality. The right fix is always to fix the
# source code, not the config.
#
# Usage: Add as a PreToolUse hook in .claude/settings.local.json
# Reads tool input JSON from stdin. Exits 0 to allow, 2 to block.

set -euo pipefail

# Extract file_path from the tool input JSON
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# If no file_path in the input, allow (not a file operation)
[ -z "$FILE_PATH" ] && exit 0

BASENAME=$(basename "$FILE_PATH")

# Protected config file patterns
case "$BASENAME" in
  .eslintrc|.eslintrc.*|eslint.config.*) ;;
  .prettierrc|.prettierrc.*|prettier.config.*) ;;
  biome.json|biome.jsonc) ;;
  .stylelintrc|.stylelintrc.*) ;;
  .markdownlint*) ;;
  .ruff.toml|ruff.toml|pyproject.toml) ;;
  .shellcheckrc) ;;
  .editorconfig) ;;
  tsconfig.json|tsconfig.*.json) ;;
  jest.config.*|vitest.config.*) ;;
  .github/workflows/*) ;;
  *)
    # Also check for CI workflow files by path
    case "$FILE_PATH" in
      */.github/workflows/*) ;;
      *) exit 0 ;;  # Not a protected file — allow
    esac
    ;;
esac

# If we reach here, the file is protected
echo "[CONFIG-PROTECTION] BLOCKED: Cannot modify $BASENAME — fix the source code to satisfy linter/formatter/CI rules instead of weakening the config." >&2
exit 2

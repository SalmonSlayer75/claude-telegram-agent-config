#!/bin/bash
# ac-resume-write.sh — Fallback Bash writer for the auto-continue JSON sidecar.
#
# Normal sidecar updates should use the Edit tool directly. This helper exists
# as defense-in-depth if a permission/tooling regression denies direct writes
# to the sidecar path (e.g., ~/.claude/ is a protected zone where project-level
# allows may not apply).
#
# Usage:   ac-resume-write.sh <bot>    # reads JSON from stdin
# Example: jq '.current_step = 3' sidecar.json | ac-resume-write.sh mybot

set -euo pipefail

# shellcheck source=lib/auto-resume-paths.sh
source "$HOME/bin/lib/auto-resume-paths.sh"

bot="${1:?usage: $0 <bot>}"
target="$(auto_resume_state_dir "$bot")/ac-resume.json"
target_dir="$(dirname "$target")"

[ -d "$target_dir" ] || { echo "[ac-resume-write] state dir missing: $target_dir" >&2; exit 2; }

tmp=$(mktemp "${target}.XXXXXX")
trap 'rm -f "$tmp"' EXIT

cat > "$tmp"

if ! jq -e . "$tmp" >/dev/null 2>&1; then
  echo "[ac-resume-write] input is not valid JSON; refusing to write $target" >&2
  exit 3
fi

mv "$tmp" "$target"
echo "[ac-resume-write] wrote $target"

#!/usr/bin/env bash
# hook-profile-gate.sh — Runtime hook gating by profile level
#
# Problem: Not every hook should run in every context. Development
# sessions need minimal overhead, production bots need full enforcement,
# and debugging sessions need to selectively disable specific hooks.
#
# Usage: hook-profile-gate.sh <hook-id> <min-profile> -- <actual-command...>
#
# Environment:
#   HOOK_PROFILE    — minimal|standard|strict (default: standard)
#   DISABLED_HOOKS  — comma-separated hook IDs to skip
#
# Profile hierarchy: minimal < standard < strict
# Each hook declares its minimum required profile level.
# If HOOK_PROFILE < min-profile, the hook is skipped silently.
#
# Hook ID format: {phase}:{category}:{name}
#   phase:    pre, post, compact-pre, compact-post, submit, start, stop
#   category: gate, tg, state, memory, inbox, daily, advisor
#   name:     short descriptive name
#
# Examples:
#   # This hook only runs in standard or strict mode:
#   hook-profile-gate.sh pre:gate:check standard -- bot-gate.py mybot --check
#
#   # This hook only runs in strict mode:
#   hook-profile-gate.sh post:advisor:compaction strict -- compaction-advisor.sh mybot
#
#   # Disable specific hooks via environment:
#   DISABLED_HOOKS="pre:gate:check,post:tg:heartbeat" claude --channels
#
# Exit codes:
#   If gated out: exits 0 with no output (hook is skipped silently)
#   Otherwise: execs the actual command (inherits its exit code)

set -euo pipefail

HOOK_ID="${1:?Usage: hook-profile-gate.sh <hook-id> <min-profile> -- <command...>}"
MIN_PROFILE="${2:?Usage: hook-profile-gate.sh <hook-id> <min-profile> -- <command...>}"
shift 2

# Consume the -- separator
if [ "${1:-}" = "--" ]; then
    shift
else
    echo "hook-profile-gate.sh: missing -- separator after min-profile" >&2
    exit 1
fi

PROFILE="${HOOK_PROFILE:-standard}"

# Profile level mapping
profile_level() {
    case "$1" in
        minimal)  echo 1 ;;
        standard) echo 2 ;;
        strict)   echo 3 ;;
        *)        echo 2 ;; # unknown defaults to standard
    esac
}

CURRENT_LEVEL=$(profile_level "$PROFILE")
REQUIRED_LEVEL=$(profile_level "$MIN_PROFILE")

# Check profile level
if [ "$CURRENT_LEVEL" -lt "$REQUIRED_LEVEL" ]; then
    exit 0
fi

# Check disabled hooks list
if [ -n "${DISABLED_HOOKS:-}" ]; then
    IFS=',' read -ra DISABLED <<< "$DISABLED_HOOKS"
    for disabled in "${DISABLED[@]}"; do
        if [ "$disabled" = "$HOOK_ID" ]; then
            exit 0
        fi
    done
fi

# Profile gate passed — execute the actual command
exec "$@"

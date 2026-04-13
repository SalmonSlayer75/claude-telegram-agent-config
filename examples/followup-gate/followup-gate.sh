#!/usr/bin/env bash
# followup-gate.sh — Checks for overdue background task follow-ups.
#
# Bots register pending follow-ups by writing to a file. This hook
# checks if any are overdue and injects a reminder into context.
#
# Follow-up file format (~/<workdir>/pending-followups.md):
#   ## task-1712847600
#   - **Output:** /tmp/test-output.txt
#   - **Status:** pending
#
# Usage (PreToolUse hook on telegram reply):
#   followup-gate.sh <bot-name>
#
# Behavior:
#   - If pending follow-ups exist with output files that are now
#     non-empty (task finished), inject a reminder to report results.
#   - Does NOT hard-block — injects advisory context only.
#   - Exit 0 always (never blocks).

set -euo pipefail

BOT="${1:?Usage: followup-gate.sh <bot-name>}"

export HOME="${HOME:-$(echo ~)}"

# Map bot names to working directories — customize for your fleet
declare -A BOT_WORKDIRS
BOT_WORKDIRS[mybot]="MyProject"
# Add your bots here

WORKDIR="${BOT_WORKDIRS[$BOT]:-}"
[ -z "$WORKDIR" ] && exit 0

FOLLOWUP_FILE="$HOME/$WORKDIR/pending-followups.md"
[ -f "$FOLLOWUP_FILE" ] || exit 0

# Check for pending entries with finished output files
REMINDERS=""
PENDING_COUNT=0

while IFS= read -r line; do
    if [[ "$line" =~ \*\*Output:\*\*\ (.+) ]]; then
        OUTPUT_FILE="${BASH_REMATCH[1]}"
        # Check if the output file exists and has content (task finished)
        if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
            PENDING_COUNT=$((PENDING_COUNT + 1))
            REMINDERS="${REMINDERS}\n- Background task output ready: $OUTPUT_FILE"
        fi
    fi
done < "$FOLLOWUP_FILE"

if [ "$PENDING_COUNT" -gt 0 ]; then
    echo "[FOLLOWUP REMINDER] You have $PENDING_COUNT background task(s) with results ready. Check the output files and report results to the user BEFORE doing other work:$REMINDERS"
fi

exit 0

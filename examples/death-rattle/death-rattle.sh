#!/usr/bin/env bash
# death-rattle.sh — Notify the user via Telegram when a bot session is dying.
#
# Called from PreCompact and Stop hooks. Reads the bot's state file to
# extract what was being worked on, then sends a Telegram notification.
#
# Stop-mode has two suppressions to avoid noise:
#   1. Idle bots — if the AC section status isn't "in-progress", skip it.
#      Most sessions end naturally when no work is happening.
#   2. Cron one-shots — if CLAUDE_CRON=1 is set (by cron-ac-preseed.sh),
#      the session ending is expected, not a crash.
#
# Usage:
#   death-rattle.sh <bot-name> compact    # PreCompact: "context compacting"
#   death-rattle.sh <bot-name> stop       # Stop: "session ended"
#
# Environment: sources bot-credentials.env for tokens and chat ID.

set -euo pipefail

BOT="${1:?Usage: death-rattle.sh <bot-name> compact|stop}"
MODE="${2:?Usage: death-rattle.sh <bot-name> compact|stop}"

export HOME="${HOME:-$(echo ~)}"
source "$HOME/.claude/bot-credentials.env"

# Map bot names to tokens and state files — customize for your fleet
declare -A BOT_TOKENS BOT_STATES
# BOT_TOKENS[mybot]="$MY_BOT_TOKEN"
# BOT_STATES[mybot]="$HOME/MyProject/mybot-state.md"

TOKEN="${BOT_TOKENS[$BOT]:-}"
STATE_FILE="${BOT_STATES[$BOT]:-}"
CHAT_ID="$TELEGRAM_CHAT_ID"

[ -z "$TOKEN" ] && exit 0  # unknown bot, fail silently

# Extract Active Conversation topic from state file (first 200 chars)
TOPIC=""
if [ -f "$STATE_FILE" ]; then
    TOPIC=$(sed -n '/^## Active Conversation/,/^## /{ /^## Active Conversation/d; /^## /d; p; }' "$STATE_FILE" \
        | head -5 | tr '\n' ' ' | cut -c1-200)
fi

BOT_UPPER=$(echo "$BOT" | tr '[:lower:]' '[:upper:]')

# Determine if the bot was actively working (has in-progress status in AC section)
WAS_ACTIVE=false
if [ -f "$STATE_FILE" ]; then
    AC_STATUS=$(sed -n '/^## Active Conversation/,/^## /{
        /^\*\*Status:\*\*/{ s/.*\*\*Status:\*\* *//; s/ *$//; p; q; }
    }' "$STATE_FILE")
    case "$AC_STATUS" in
        in-progress|assessing) WAS_ACTIVE=true ;;
    esac
fi

case "$MODE" in
    compact)
        MSG="⚠️ ${BOT_UPPER} — context compacting, may lose thread"
        [ -n "$TOPIC" ] && MSG="$MSG

Working on: ${TOPIC}"
        ;;
    stop)
        # Suppress notification for idle bots — only notify if actively working
        if [ "$WAS_ACTIVE" = false ]; then
            exit 0
        fi
        # Suppress for cron one-shots — session ending is expected, not a crash.
        # CLAUDE_CRON is set by cron-ac-preseed.sh before running claude -p.
        if [ "${CLAUDE_CRON:-}" = "1" ]; then
            exit 0
        fi
        MSG="🛑 ${BOT_UPPER} session ended"
        [ -n "$TOPIC" ] && MSG="$MSG

Was working on: ${TOPIC}"
        MSG="$MSG

State saved — will resume on restart."
        ;;
    *)
        exit 0
        ;;
esac

# Send notification — best effort, never block
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${MSG}" \
    > /dev/null 2>&1 || true

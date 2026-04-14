#!/usr/bin/env bash
# fleet-review.sh — Daily automated fleet health review
# Gathers logs, errors, and health data from all bots, then uses
# claude -p to analyze and send a Telegram report with findings
# and recommended improvements.
#
# Runs daily via cron. Designed for a DevOps/operator bot context.
#
# Prerequisites:
#   - bot-credentials.env with BOT_TOKEN and TELEGRAM_CHAT_ID
#   - cron-ac-preseed.sh (see ../cron-scripts/)
#   - claude CLI with -p (pipe) mode
#   - All bots running in separate tmux sessions with per-bot sockets
#
# Cron example (5:30am daily):
#   30 5 * * * /path/to/fleet-review.sh >> ~/.claude/channels/fleet-review.log 2>&1

set -uo pipefail
# Note: not using set -e because grep returning no matches (rc=1) would kill the script

export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

source "$HOME/.claude/bot-credentials.env"
source "$HOME/bin/cron-ac-preseed.sh"

# --- Configuration ---
# Adjust these to match your fleet layout
BOT_TOKEN="${DEVOPS_BOT_TOKEN:-$BOT_TOKEN}"
CHAT_ID="$TELEGRAM_CHAT_ID"
OPERATOR_STATE="$HOME/DevOps/devops-state.md"       # State file for the operator bot
LOG="$HOME/.claude/channels/fleet-review.log"

# Bot definitions — add/remove bots here
# Format: name:tmux-socket:tmux-session:state-file
BOTS=(
    "cos:claude-cos:claude-cos-bot:$HOME/ChiefOfStaff/cos-state.md"
    "vpe:claude-vpe:claude-vpe-bot:$HOME/Projects/vpe-state.md"
    "vpe-wendy:claude-vpe-wendy:claude-vpe-wendy-bot:$HOME/VPE-Wendy/vpe-wendy-state.md"
    "cto:claude-cto:claude-cto-bot:$HOME/CTO/cto-state.md"
    "devops:claude-devops:claude-devops-bot:$HOME/DevOps/devops-state.md"
    "prodmktg:claude-prodmktg:claude-prodmktg-bot:$HOME/ProdMktg/prodmktg-state.md"
)

# Log files to scan for errors (glob patterns)
LOG_DIRS=(
    "$HOME/.claude/channels"
    "$HOME/.claude/logs"
)

# Watchdog log path
WATCHDOG_LOG="$HOME/.claude/channels/watchdog.log"

# Bot-gate sentinel log pattern
BOTGATE_PATTERN="$HOME/.claude/channels/bot-gate-*.log"

# Heartbeat file pattern (/tmp/{name}-heartbeat)
HEARTBEAT_DIR="/tmp"

# Where to save the report for the operator bot to read on next session
REPORT_FILE="$HOME/DevOps/fleet-review-latest.md"

# --- End configuration ---

REPORT_DIR="/tmp/fleet-review-$$"
LOCKFILE="/tmp/fleet-review.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "$(date '+%Y-%m-%d %H:%M:%S') Already running — skipping" >> "$LOG"; exit 0; }

mkdir -p "$REPORT_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

send_telegram() {
    local text="$1"
    if [ ${#text} -gt 4000 ]; then
        text="${text:0:3997}..."
    fi
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="${text}" \
        -d parse_mode="Markdown" \
        > /dev/null 2>&1
}

# Helper: parse bot definition
parse_bot() {
    local def="$1"
    BOT_NAME="${def%%:*}"; def="${def#*:}"
    BOT_SOCKET="${def%%:*}"; def="${def#*:}"
    BOT_SESSION="${def%%:*}"; def="${def#*:}"
    BOT_STATE_FILE="$def"
}

log "Fleet review starting"

YESTERDAY=$(date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || date -v-1d '+%Y-%m-%d')
TODAY=$(date '+%Y-%m-%d')
YESTERDAY_EPOCH=$(date -d 'yesterday' '+%s' 2>/dev/null || date -v-1d '+%s')

# --- Gather data ---

# 1. Watchdog log — last 24 hours of restarts and sentinel pages
if [ -f "$WATCHDOG_LOG" ]; then
    grep "$YESTERDAY\|$TODAY" "$WATCHDOG_LOG" 2>/dev/null \
        > "$REPORT_DIR/watchdog.txt" || true
fi

# 2. Bot-gate sentinel logs — last 24 hours
# Bot-gate logs use unix timestamps, so filter by epoch range and convert
for f in $BOTGATE_PATTERN; do
    [ -f "$f" ] || continue
    recent_lines=""
    while IFS= read -r line; do
        ts="${line%% *}"
        if [[ "$ts" =~ ^[0-9]+$ ]] && [ "$ts" -ge "$YESTERDAY_EPOCH" ] 2>/dev/null; then
            recent_lines+="$(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$ts" '+%Y-%m-%d %H:%M:%S') ${line#* }"$'\n'
        fi
    done < "$f"
    if [ -n "$recent_lines" ]; then
        echo "=== $(basename "$f") ===" >> "$REPORT_DIR/bot-gate.txt"
        echo "$recent_lines" >> "$REPORT_DIR/bot-gate.txt"
    fi
done

# 3. Bot tmux session status
for bot_def in "${BOTS[@]}"; do
    parse_bot "$bot_def"
    if tmux -L "$BOT_SOCKET" has-session -t "$BOT_SESSION" 2>/dev/null; then
        pane=$(tmux -L "$BOT_SOCKET" capture-pane -t "$BOT_SESSION" -p 2>/dev/null | tail -5)
        echo "$BOT_NAME: RUNNING — last lines: $pane"
    else
        echo "$BOT_NAME: DOWN"
    fi
done > "$REPORT_DIR/bot-status.txt" 2>/dev/null

# 4. State file freshness
for bot_def in "${BOTS[@]}"; do
    parse_bot "$bot_def"
    if [ -f "$BOT_STATE_FILE" ]; then
        mod_time=$(stat -c '%Y' "$BOT_STATE_FILE" 2>/dev/null || stat -f '%m' "$BOT_STATE_FILE")
        now=$(date +%s)
        age_hours=$(( (now - mod_time) / 3600 ))
        status=$(grep -m1 '^\*\*Status:\*\*' "$BOT_STATE_FILE" 2>/dev/null || echo "unknown")
        topic=$(grep -m1 '^\*\*Topic:\*\*' "$BOT_STATE_FILE" 2>/dev/null || echo "unknown")
        echo "$BOT_NAME: modified ${age_hours}h ago | $status | $topic"
    else
        echo "$BOT_NAME: STATE FILE MISSING"
    fi
done > "$REPORT_DIR/state-freshness.txt" 2>/dev/null

# 5. Cron job logs with errors/failures (scan all .log files)
for dir in "${LOG_DIRS[@]}"; do
    for f in "$dir"/*.log; do
        [ -f "$f" ] || continue
        errors=$(grep -i "error\|fail\|Exit code: [^0]" "$f" 2>/dev/null \
            | grep "$YESTERDAY\|$TODAY" 2>/dev/null \
            | tail -10)
        if [ -n "$errors" ]; then
            echo "=== $(basename "$f") ===" >> "$REPORT_DIR/cron-errors.txt"
            echo "$errors" >> "$REPORT_DIR/cron-errors.txt"
        fi
    done
done

# 6. Heartbeat file ages
for bot_def in "${BOTS[@]}"; do
    parse_bot "$bot_def"
    # Normalize heartbeat name (strip hyphens)
    hb_name="${BOT_NAME//-/}"
    hb="$HEARTBEAT_DIR/${hb_name}-heartbeat"
    if [ -f "$hb" ]; then
        mod_time=$(stat -c '%Y' "$hb" 2>/dev/null || stat -f '%m' "$hb")
        now=$(date +%s)
        age_min=$(( (now - mod_time) / 60 ))
        echo "$BOT_NAME: heartbeat ${age_min}m ago"
    else
        echo "$BOT_NAME: NO HEARTBEAT FILE"
    fi
done > "$REPORT_DIR/heartbeats.txt" 2>/dev/null

# --- Build the prompt ---

PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" << 'PROMPT_HEADER'
You are the DevOps lead for an AI agent team. This is your DAILY FLEET HEALTH REVIEW.

Analyze the data below and produce a concise Telegram-friendly report. Structure:

1. **Fleet Status** — one line per bot: up/down, last restart reason if any
2. **Issues Found** — anything that needs attention, ranked by severity (P0/P1/P2)
3. **Patterns** — recurring problems (e.g., a bot that keeps baking, stale connections)
4. **Recommendations** — specific, actionable improvements (config changes, script fixes, etc.)

Rules:
- Be direct and specific. "VPE-Wendy restarted 4x for stale connections — consider increasing heartbeat interval" not "some bots had issues"
- Only flag real problems. If everything is clean, say so briefly.
- Keep under 3500 characters total.
- Use plain text, no markdown formatting (this goes to Telegram as plain text).

--- DATA ---

PROMPT_HEADER

echo "" >> "$PROMPT_FILE"
for f in "$REPORT_DIR"/*.txt; do
    [ -f "$f" ] || continue
    echo "=== $(basename "$f" .txt) ===" >> "$PROMPT_FILE"
    cat "$f" >> "$PROMPT_FILE"
    echo "" >> "$PROMPT_FILE"
done

# --- Run analysis ---

# Run claude -p from /tmp to avoid triggering project-specific hooks
cd /tmp
cron_ac_preseed "$OPERATOR_STATE" "Daily Fleet Health Review"

ERRLOG=$(mktemp)
RESULT=$(cat "$PROMPT_FILE" | claude -p --model sonnet --max-turns 5 --permission-mode dontAsk 2>"$ERRLOG")
EXIT_CODE=$?
rm -f "$PROMPT_FILE"

if [ $EXIT_CODE -ne 0 ] || [ -z "$RESULT" ]; then
    log "Fleet review FAILED — exit code: $EXIT_CODE"
    log "Stderr: $(cat "$ERRLOG")"
    send_telegram "Fleet review failed — check fleet-review.log"
else
    # Save report to disk so operator bot can read it and follow up
    cat > "$REPORT_FILE" << REPORTEOF
# Fleet Review — $(date '+%Y-%m-%d %H:%M %Z')

$RESULT
REPORTEOF
    log "Fleet review OK — sent (${#RESULT} chars), saved to $REPORT_FILE"
    send_telegram "$RESULT"
fi

rm -f "$ERRLOG"
rm -rf "$REPORT_DIR"
cron_ac_complete "$OPERATOR_STATE"

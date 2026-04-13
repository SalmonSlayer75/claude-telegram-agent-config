#!/usr/bin/env bash
# claude-bot-watchdog — detects bots that have "baked" (session ended) and restarts them
#
# Run via cron every 5 minutes. Detects three failure modes:
#   1. Session gone — tmux session doesn't exist at all
#   2. Session baked — conversation ended (context limit, crash)
#   3. Stale connection — bot says "Listening" but hasn't done anything for 3+ hours
#
# The heartbeat file (/tmp/<bot>-heartbeat) is touched by a PostToolUse hook
# on every tool call. If it goes stale while the bot claims to be listening,
# the Telegram long-poll has silently died.
#
# Usage: claude-bot-watchdog.sh [work|personal|all]
#
# CUSTOMIZE: Update the BOT_* arrays below with your bot names, tmux sockets,
# start scripts, and Telegram bot tokens.

set -euo pipefail

export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
export HOME="/home/yourusername"    # <-- CHANGE THIS

# Source credentials from env file (keeps tokens out of scripts)
source "$HOME/.claude/bot-credentials.env"

LOG="$HOME/.claude/channels/watchdog.log"

# --- CONFIGURE YOUR BOTS HERE ---
declare -A BOT_SOCKET BOT_SESSION BOT_SCRIPT BOT_TOKEN BOT_HEARTBEAT

BOT_SOCKET[work]="claude-work"
BOT_SESSION[work]="claude-work-bot"
BOT_SCRIPT[work]="$HOME/bin/claude-work-bot-start.sh"
BOT_TOKEN[work]="$BOT_TOKEN_1"
BOT_HEARTBEAT[work]="work"

BOT_SOCKET[personal]="claude-personal"
BOT_SESSION[personal]="claude-personal-bot"
BOT_SCRIPT[personal]="$HOME/bin/claude-personal-bot-start.sh"
BOT_TOKEN[personal]="$BOT_TOKEN_2"
BOT_HEARTBEAT[personal]="personal"

CHAT_ID="$TELEGRAM_CHAT_ID"

# Map bot names to state files for active-topic extraction
declare -A BOT_STATE_FILE
BOT_STATE_FILE[work]="$HOME/WorkProject/work-state.md"
BOT_STATE_FILE[personal]="$HOME/PersonalProject/personal-state.md"

ALL_BOTS="work personal"
# --- END CONFIGURATION ---

HEARTBEAT_STALE_SECONDS=10800  # 3 hours

# Extract Active Conversation topic from a bot's state file (first 200 chars)
get_active_topic() {
    local state_file="${BOT_STATE_FILE[$1]:-}"
    [ -z "$state_file" ] || [ ! -f "$state_file" ] && return
    sed -n '/^## Active Conversation/,/^## /{ /^## Active Conversation/d; /^## /d; p; }' "$state_file" \
        | head -5 | tr '\n' ' ' | cut -c1-200
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

send_telegram() {
    local token="$1" text="$2"
    curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="${text}" \
        -d parse_mode="Markdown" \
        > /dev/null 2>&1
}

# Check if the heartbeat file is stale (no tool activity for 3+ hours).
# The heartbeat is touched by a PostToolUse hook on every tool call, and
# also on session start. If it goes stale while tmux shows "Listening",
# the Telegram long-poll connection has silently died.
check_heartbeat() {
    local name="$1"
    local hb_prefix="${BOT_HEARTBEAT[$name]}"
    local hb_file="/tmp/${hb_prefix}-heartbeat"

    # No heartbeat file yet — create one (first watchdog run after deploy)
    if [ ! -f "$hb_file" ]; then
        touch "$hb_file"
        return 1  # not stale
    fi

    local now hb_time age
    now=$(date +%s)
    hb_time=$(stat -c %Y "$hb_file" 2>/dev/null || echo "$now")
    age=$(( now - hb_time ))

    if [ "$age" -ge "$HEARTBEAT_STALE_SECONDS" ]; then
        return 0  # stale
    fi
    return 1  # not stale
}

check_and_restart() {
    local name="$1"
    local socket="${BOT_SOCKET[$name]}"
    local session="${BOT_SESSION[$name]}"
    local script="${BOT_SCRIPT[$name]}"
    local token="${BOT_TOKEN[$name]}"
    local hb_prefix="${BOT_HEARTBEAT[$name]}"

    # Check if tmux session exists at all
    if ! tmux -L "$socket" has-session -t "$session" 2>/dev/null; then
        log "[$name] tmux session not found — starting bot"
        tmux -L "$socket" new-session -d -s "$session" "$script"
        touch "/tmp/${hb_prefix}-heartbeat"
        send_telegram "$token" "Bot was down — watchdog restarted it."
        return
    fi

    # Capture the tmux pane and check for active listening
    local pane_content
    pane_content=$(tmux -L "$socket" capture-pane -t "$session" -p -S -50 2>&1)

    if echo "$pane_content" | grep -q "Listening for channel messages"; then
        # Bot says it's listening — but check if the connection is actually alive
        if check_heartbeat "$name"; then
            log "[$name] stale connection detected (listening but no activity for 3+ hours) — restarting"
            local active_topic
            active_topic=$(get_active_topic "$name")
            tmux -L "$socket" send-keys -t "$session" C-c
            sleep 2
            tmux -L "$socket" kill-session -t "$session" 2>/dev/null || true
            sleep 1
            rm -f "/tmp/${hb_prefix}-state-loaded" "/tmp/${name}-state-loaded"
            tmux -L "$socket" new-session -d -s "$session" "$script"
            touch "/tmp/${hb_prefix}-heartbeat"
            local msg="Bot had a stale connection (listening but not receiving messages for 3+ hours) — watchdog restarted it."
            if [ -n "$active_topic" ]; then
                msg="$msg"$'\n\n'"Was working on: ${active_topic}"
            fi
            send_telegram "$token" "$msg"
            return
        fi
        return 0
    fi

    if echo "$pane_content" | grep -qE "Baked for|Cooked for"; then
        # Bot conversation ended — session baked out
        log "[$name] conversation baked — restarting"

        # Capture what the bot was working on before restarting
        local active_topic
        active_topic=$(get_active_topic "$name")

        tmux -L "$socket" send-keys -t "$session" C-c
        sleep 2
        tmux -L "$socket" kill-session -t "$session" 2>/dev/null || true
        sleep 1
        # Clear the state-loaded flag so PreToolUse hook fires on new session
        rm -f "/tmp/${hb_prefix}-state-loaded" "/tmp/${name}-state-loaded"
        tmux -L "$socket" new-session -d -s "$session" "$script"
        touch "/tmp/${hb_prefix}-heartbeat"

        local msg="Bot hit context limit — watchdog restarted it. State file preserved."
        if [ -n "$active_topic" ]; then
            msg="$msg"$'\n\n'"Was working on: ${active_topic}"
        fi
        send_telegram "$token" "$msg"
        return
    fi

    # Bot is in a conversation (processing a message) — leave it alone
    # This covers the case where it's mid-reply and neither "Listening" nor "Baked" appears
}

# --- OPTIONAL: Local model health check with backoff ---
# If you run a local model (Qwen, llama.cpp, etc.) alongside your bots,
# uncomment this section to auto-restart it when it goes down.
#
# LOCAL_MODEL_FAIL_FILE="/tmp/local-model-restart-failures"
# check_local_model() {
#     if curl -s http://localhost:8001/health > /dev/null 2>&1; then
#         # Healthy — reset failure counter
#         rm -f "$LOCAL_MODEL_FAIL_FILE"
#         return
#     fi
#
#     # Check backoff — skip if too many recent failures
#     local failures=0
#     if [ -f "$LOCAL_MODEL_FAIL_FILE" ]; then
#         failures=$(cat "$LOCAL_MODEL_FAIL_FILE")
#         # Back off: after 3 consecutive failures, only retry every 30 min (6 cycles)
#         if [ "$failures" -ge 3 ]; then
#             local skip=$(( failures % 6 ))
#             if [ "$skip" -ne 0 ]; then
#                 return
#             fi
#             log "[local-model] retry after $failures consecutive failures"
#         fi
#     fi
#
#     log "[local-model] server not running — auto-starting"
#     "$HOME/bin/start-local-model.sh" >> "$LOG" 2>&1
#     if curl -s http://localhost:8001/health > /dev/null 2>&1; then
#         log "[local-model] server restarted successfully"
#         rm -f "$LOCAL_MODEL_FAIL_FILE"
#     else
#         failures=$((failures + 1))
#         echo "$failures" > "$LOCAL_MODEL_FAIL_FILE"
#         log "[local-model] ERROR: server failed to start (failure #$failures)"
#     fi
# }

# --- CONFIGURE YOUR BOT NAMES HERE ---
resolve_targets() {
    local target="${1:-all}"
    case "$target" in
        all) echo "$ALL_BOTS" ;;
        work|personal) echo "$target" ;;
        *) echo "Unknown bot: $target" >&2; exit 1 ;;
    esac
}

TARGET="${1:-all}"
for bot in $(resolve_targets "$TARGET"); do
    check_and_restart "$bot"
done
# Uncomment if using local model health check:
# check_local_model

#!/usr/bin/env bash
# fleet-heartbeat-check.sh — Dead-man's-switch for the bot fleet.
#
# Watches-the-watcher. Runs every 5 min via cron or systemd timer. Checks:
#   1. Watchdog has been active in the last 15 min (tick file mtime)
#   2. Each bot has a non-stale tmux session
# Fires a Telegram alert if any condition fails. Self-suppresses repeat alerts
# for 30 minutes per distinct failure mode to avoid spam.
#
# Usage: fleet-heartbeat-check.sh
#
# CUSTOMIZE: Update BOT_SOCKET/BOT_SESSION arrays and BOTS list for your fleet.

set -u

export HOME="${HOME:-/home/yourusername}"    # <-- CHANGE THIS
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"

CREDS="$HOME/.claude/bot-credentials.env"
if [ ! -f "$CREDS" ]; then
    echo "[heartbeat] credentials not found: $CREDS" >&2
    exit 2
fi
# shellcheck source=/dev/null
source "$CREDS"

# Shared Telegram paging helper (validated send with retry-as-plain fallback)
# shellcheck source=lib/page-telegram.sh
source "$HOME/bin/lib/page-telegram.sh"

STATE_DIR="$HOME/.claude/fleet-metrics/heartbeat"
mkdir -p "$STATE_DIR"

LOG="$STATE_DIR/heartbeat.log"
SUPPRESS_DIR="$STATE_DIR/suppress"
mkdir -p "$SUPPRESS_DIR"

# Dedicated liveness tick file — touched by watchdog on EVERY run.
WATCHDOG_TICK="${WATCHDOG_TICK:-$HOME/.claude/watchdog/last-tick}"
WATCHDOG_STALE_SECONDS="${WATCHDOG_STALE_SECONDS:-900}"   # 15 min
SUPPRESS_SECONDS="${SUPPRESS_SECONDS:-1800}"              # 30 min

# --- CONFIGURE YOUR BOTS HERE ---
BOTS="work research devops engineering"       # <-- CHANGE THIS
declare -A BOT_SOCKET BOT_SESSION
BOT_SOCKET[work]="claude-work";               BOT_SESSION[work]="claude-work-bot"
BOT_SOCKET[research]="claude-research";       BOT_SESSION[research]="claude-research-bot"
BOT_SOCKET[devops]="claude-devops";           BOT_SESSION[devops]="claude-devops-bot"
BOT_SOCKET[engineering]="claude-eng";         BOT_SESSION[engineering]="claude-eng-bot"

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[%s] %s\n' "$(timestamp)" "$*" >> "$LOG"; }

alert() {
    local key="$1" msg="$2"
    local supp_file="$SUPPRESS_DIR/$key"
    if [ -f "$supp_file" ]; then
        local age
        age=$(( $(date +%s) - $(stat -c %Y "$supp_file" 2>/dev/null || echo 0) ))
        if [ "$age" -lt "$SUPPRESS_SECONDS" ]; then
            log "alert suppressed (key=$key, age=${age}s): $msg"
            return 0
        fi
    fi
    touch "$supp_file"

    local token="${DEVOPS_BOT_TOKEN:-${BOT_TOKEN_3:-}}"    # <-- CHANGE THIS
    local chat="${TELEGRAM_CHAT_ID:-}"
    if [ -z "$token" ] || [ -z "$chat" ]; then
        log "alert fired but token/chat missing: $msg"
        return 1
    fi

    if page_telegram "$token" "$chat" "DEAD-MAN'S-SWITCH: $msg" \
        "$HOME/.claude/channels" "heartbeat-${key}"; then
        log "alert sent (key=$key): $msg"
    else
        log "alert send FAILED (key=$key): $msg"
    fi
}

clear_alert() {
    rm -f "$SUPPRESS_DIR/$1" 2>/dev/null || true
}

check_watchdog() {
    local target="$WATCHDOG_TICK"
    local key="watchdog-stale"
    if [ ! -f "$target" ]; then
        alert "watchdog-missing" "watchdog tick file missing ($target)"
        return 1
    fi
    local now age
    now=$(date +%s)
    age=$(( now - $(stat -c %Y "$target" 2>/dev/null || echo "$now") ))
    if [ "$age" -ge "$WATCHDOG_STALE_SECONDS" ]; then
        alert "$key" "watchdog stale: $target not updated in ${age}s (threshold ${WATCHDOG_STALE_SECONDS}s)"
        return 1
    fi
    clear_alert "watchdog-missing"
    clear_alert "watchdog-stale"
    return 0
}

check_bot() {
    local name="$1"
    local socket="${BOT_SOCKET[$name]}"
    local session="${BOT_SESSION[$name]}"
    local grace_flag="$STATE_DIR/${name}-tmux-missing"

    if ! tmux -L "$socket" has-session -t "$session" 2>/dev/null; then
        if [ -f "$grace_flag" ]; then
            local flag_age
            flag_age=$(( $(date +%s) - $(stat -c %Y "$grace_flag" 2>/dev/null || echo 0) ))
            if [ "$flag_age" -ge 60 ]; then
                rm -f "$grace_flag"
                alert "bot-down-$name" "$name tmux session missing for ${flag_age}s"
                return 1
            fi
            log "[$name] tmux missing — grace period active (${flag_age}s)"
            return 0
        else
            touch "$grace_flag"
            log "[$name] tmux missing — grace period started"
            return 0
        fi
    fi
    rm -f "$grace_flag" 2>/dev/null
    clear_alert "bot-down-$name"
    return 0
}

log "heartbeat check start"

fail=0
check_watchdog || fail=1
for bot in $BOTS; do
    check_bot "$bot" || fail=1
done

if [ "$fail" -eq 0 ]; then
    log "all checks passed"
else
    log "at least one check failed"
fi

exit "$fail"

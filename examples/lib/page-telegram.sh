#!/usr/bin/env bash
# page-telegram.sh — Shared Telegram paging helper.
# Sourced by watchdog, heartbeat monitor, and other alerting scripts.
#
# Validates HTTP 200 + JSON ok:true. On HTTP 400 (typical Markdown parse
# error), retries once without parse_mode. Writes PAGE_FAILED forensic
# sentinels on failure.

# page_telegram <token> <chat_id> <text> [<sentinel_dir> <sentinel_name>]
#   - token:        Telegram bot token
#   - chat_id:      target chat id
#   - text:         message text (Markdown by default; retried plain on 400)
#   - sentinel_dir: optional directory for PAGE_FAILED forensic sentinels
#   - sentinel_name: optional tag for the sentinel filename
#
# Returns 0 on delivered (HTTP 200 + JSON ok:true), 3 on failure.
page_telegram() {
    local token="$1" chat_id="$2" text="$3"
    local sentinel_dir="${4:-}" sentinel_name="${5:-}"

    local resp http page_ok=0
    resp=$(mktemp)

    http=$(curl -sS -o "$resp" -w '%{http_code}' -X POST \
        "https://api.telegram.org/bot${token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
        -d "parse_mode=Markdown" 2>/dev/null) || http="000"

    if [[ "$http" == "200" ]] && python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and d.get("ok") is True else 1)
' "$resp" 2>/dev/null; then
        page_ok=1
    fi

    # HTTP 400 retry without Markdown (parse_mode errors)
    if [[ $page_ok -eq 0 && "$http" == "400" ]]; then
        local body_redacted
        body_redacted=$(head -c 500 "$resp" 2>/dev/null | tr -d '\n' | sed "s|${token}|<TOKEN>|g")
        if [ -n "$sentinel_dir" ] && [ -n "$sentinel_name" ]; then
            mkdir -p "$sentinel_dir" 2>/dev/null || true
            printf '%s page http=400 body=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$body_redacted" \
                >> "${sentinel_dir}/${sentinel_name}.PAGE_FAILED"
        fi

        : > "$resp"
        http=$(curl -sS -o "$resp" -w '%{http_code}' -X POST \
            "https://api.telegram.org/bot${token}/sendMessage" \
            -d "chat_id=${chat_id}" \
            --data-urlencode "text=${text}" 2>/dev/null) || http="000"
        if [[ "$http" == "200" ]] && python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and d.get("ok") is True else 1)
' "$resp" 2>/dev/null; then
            page_ok=1
        fi
    fi

    if [[ $page_ok -eq 0 ]]; then
        local body_redacted
        body_redacted=$(head -c 500 "$resp" 2>/dev/null | tr -d '\n' | sed "s|${token}|<TOKEN>|g")
        if [ -n "$sentinel_dir" ] && [ -n "$sentinel_name" ]; then
            mkdir -p "$sentinel_dir" 2>/dev/null || true
            printf '%s page failed http=%s body=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$http" "$body_redacted" \
                >> "${sentinel_dir}/${sentinel_name}.PAGE_FAILED"
        fi
        rm -f "$resp"
        return 3
    fi

    rm -f "$resp"
    return 0
}

#!/usr/bin/env bash
# bot-auto-resume.sh — Resume detection engine for auto-continue interrupted work.
#
# Reads the JSON sidecar (ac-resume.json) for a given bot, checks safety rails,
# and emits a resume prompt to stdout if interrupted work should be continued.
# Called as the last step of a bot's session start script.
#
# Usage: bot-auto-resume.sh <bot-name>
#
# Exit codes:
#   0 — always (fail-safe: never block session startup)
#
# Outputs:
#   stdout — resume prompt text (if resume warranted), or nothing
#   stderr — diagnostics/warnings (not injected into session)

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
STALENESS_SECONDS=7200        # 2 hours
MAX_RESUME_COUNT=2            # 3 total attempts (original + 2 resumes)
STALE_IN_PROGRESS_SECONDS=300 # 5 minutes — "in-progress" older than this = interrupted
APPROVAL_TOKEN_TTL=7200       # 2 hours

HOME_DIR="${HOME:-/home/yourusername}"    # <-- CHANGE THIS
CREDENTIALS_FILE="$HOME_DIR/.claude/bot-credentials.env"

# Source the per-bot auto-resume directory lookup table.
# Defines `auto_resume_state_dir <bot>` with legacy-path fallback.
# shellcheck disable=SC1090
source "$HOME_DIR/bin/lib/auto-resume-paths.sh"

# ---------------------------------------------------------------------------
# Bot token mapping — CUSTOMIZE for your fleet
# ---------------------------------------------------------------------------
declare -A TOKEN_VAR_MAP=(
    [work]="BOT_TOKEN_1"
    [research]="BOT_TOKEN_2"
    [devops]="BOT_TOKEN_3"
    [engineering]="BOT_TOKEN_4"
    # Add your bots here
)

VALID_BOTS="${!TOKEN_VAR_MAP[*]}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[bot-auto-resume] $*" >&2; }

LOG_FILE=""
init_log() {
    local bot="$1"
    local dir
    dir=$(dirname "$(sidecar_path "$bot")")
    LOG_FILE="$dir/auto-resume.log"
}

log_event() {
    local outcome="$1"    # resumed | skipped | blocked | approval-needed | error
    local topic="${2:-}"
    local step="${3:-0}"
    local safety="${4:-}"
    local count="${5:-0}"
    local reason="${6:-}"
    [[ -z "$LOG_FILE" ]] && return 0
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$(date -Iseconds)" "${BOT_NAME:-unknown}" "$outcome" \
        "$topic" "$step" "$safety" "$count" "$reason" \
        >> "$LOG_FILE" 2>/dev/null || true
}

die_safe() {
    log "$@"
    exit 0  # never block startup
}

now_epoch() { date +%s; }

iso_to_epoch() {
    local ts="$1"
    date -d "$ts" +%s 2>/dev/null || echo "0"
}

sidecar_path() {
    local bot="$1"
    local override="${BOT_AUTO_RESUME_SIDECAR_OVERRIDE:-}"
    if [[ -n "$override" ]]; then
        echo "$override"
    else
        echo "$(auto_resume_state_dir "$bot")/ac-resume.json"
    fi
}

approval_dir() {
    local bot="$1"
    local override="${BOT_AUTO_RESUME_APPROVAL_DIR_OVERRIDE:-}"
    if [[ -n "$override" ]]; then
        echo "$override"
    else
        echo "$(auto_resume_state_dir "$bot")/approval-tokens"
    fi
}

send_telegram() {
    local bot="$1"
    local message="$2"

    if [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        if [[ -f "$CREDENTIALS_FILE" ]]; then
            # shellcheck disable=SC1090
            source "$CREDENTIALS_FILE"
        else
            log "credentials file not found, skipping Telegram notification"
            return 0
        fi
    fi

    local token_var="${TOKEN_VAR_MAP[$bot]:-}"
    if [[ -z "$token_var" ]]; then
        log "no token var for bot $bot"
        return 0
    fi
    local token="${!token_var:-}"
    local chat_id="${TELEGRAM_CHAT_ID:-}"

    if [[ -z "$token" || -z "$chat_id" ]]; then
        log "missing token or chat_id, skipping Telegram"
        return 0
    fi

    curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        -d chat_id="${chat_id}" \
        -d text="${message}" \
        -d parse_mode="HTML" >/dev/null 2>&1 || true
}

sidecar_update() {
    local file="$1"
    shift
    local filter="$1"
    local tmp="${file}.tmp"
    if jq "$filter" "$file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        log "failed to update sidecar"
    fi
}

# ---------------------------------------------------------------------------
# Approval token helpers
# ---------------------------------------------------------------------------
find_approval_token() {
    local bot="$1"
    local topic="$2"
    local step_num="$3"

    local dir
    dir=$(approval_dir "$bot")
    [[ -d "$dir" ]] || return 1

    local now
    now=$(now_epoch)

    for token_file in "$dir"/*.json; do
        [[ -f "$token_file" ]] || continue

        local t_topic t_step t_approved t_consumed t_expires
        t_topic=$(jq -r '.task_topic // ""' "$token_file" 2>/dev/null) || continue
        t_step=$(jq -r '.step_num // 0' "$token_file" 2>/dev/null) || continue
        t_approved=$(jq -r '.approved_at // ""' "$token_file" 2>/dev/null) || continue
        t_consumed=$(jq -r 'if .consumed == false then "false" else "true" end' "$token_file" 2>/dev/null) || continue
        t_expires=$(jq -r '.expires_at // ""' "$token_file" 2>/dev/null) || continue

        if [[ "$t_topic" != "$topic" || "$t_step" != "$step_num" ]]; then
            continue
        fi
        if [[ -z "$t_approved" || "$t_approved" == "null" ]]; then
            continue
        fi
        if [[ "$t_consumed" == "true" ]]; then
            continue
        fi
        if [[ -n "$t_expires" && "$t_expires" != "null" ]]; then
            local exp_epoch
            exp_epoch=$(iso_to_epoch "$t_expires")
            if (( exp_epoch > 0 && exp_epoch < now )); then
                continue
            fi
        fi

        echo "$token_file"
        return 0
    done

    return 1
}

write_pending_approval_token() {
    local bot="$1"
    local topic="$2"
    local step_num="$3"
    local step_desc="$4"

    local dir
    dir=$(approval_dir "$bot")
    mkdir -p "$dir"

    local now_iso
    now_iso=$(date -Iseconds)
    local token_id="approve-${now_iso}-step${step_num}"
    local expires_iso
    expires_iso=$(date -Iseconds -d "+${APPROVAL_TOKEN_TTL} seconds")

    local token_file="$dir/${token_id}.json"
    cat > "$token_file" <<TOKEOF
{
  "token_id": "$token_id",
  "task_topic": $(echo "$topic" | jq -Rs .),
  "step_num": $step_num,
  "step_description": $(echo "$step_desc" | jq -Rs .),
  "step_safety": "needs-approval",
  "requested_at": "$now_iso",
  "approved_at": null,
  "approved_by": null,
  "consumed": false,
  "expires_at": "$expires_iso"
}
TOKEOF

    echo "$token_id"
}

# ---------------------------------------------------------------------------
# Build resume prompt
# ---------------------------------------------------------------------------
build_resume_prompt() {
    local topic="$1"
    local current_step="$2"
    local total_steps="$3"
    local resumption_context="$4"
    local sidecar="$5"

    local prompt=""
    prompt+="--- AUTO-RESUME: INTERRUPTED WORK DETECTED ---\n"
    prompt+="\n"
    prompt+="Your previous session was interrupted mid-task. Pick up where you left off.\n"
    prompt+="\n"
    prompt+="**Topic:** $topic\n"
    prompt+="**Picking up at:** step $current_step of $total_steps\n"
    prompt+="\n"

    local completed
    completed=$(jq -r '.steps[] | select(.done == true) | "- [x] Step \(.num): \(.description) — \(.result // "done")"' "$sidecar" 2>/dev/null)
    if [[ -n "$completed" ]]; then
        prompt+="**Completed steps:**\n"
        prompt+="$completed\n"
        prompt+="\n"
    fi

    local remaining
    remaining=$(jq -r '.steps[] | select(.done == false) | "- [ ] Step \(.num): \(.description) [safety: \(.safety // "unknown")]"' "$sidecar" 2>/dev/null)
    if [[ -n "$remaining" ]]; then
        prompt+="**Remaining steps:**\n"
        prompt+="$remaining\n"
        prompt+="\n"
    fi

    prompt+="**Context:** $resumption_context\n"
    prompt+="\n"
    prompt+="Resume this work now. Update ac-resume.json and your state file as you complete each step.\n"
    prompt+="--- END AUTO-RESUME ---"

    echo -e "$prompt"
}

build_approval_prompt() {
    local topic="$1"
    local step_num="$2"
    local step_desc="$3"
    local token_id="$4"
    local resumption_context="$5"

    local prompt=""
    prompt+="--- AUTO-RESUME: APPROVAL REQUIRED ---\n"
    prompt+="\n"
    prompt+="Your previous session was interrupted. The next step requires approval.\n"
    prompt+="\n"
    prompt+="**Topic:** $topic\n"
    prompt+="**Step $step_num:** $step_desc\n"
    prompt+="**Approval token:** $token_id\n"
    prompt+="\n"
    prompt+="**Context:** $resumption_context\n"
    prompt+="\n"
    prompt+="Send a Telegram message asking for approval to proceed with step $step_num.\n"
    prompt+="Include the step description and wait for the response.\n"
    prompt+="--- END AUTO-RESUME ---"

    echo -e "$prompt"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local bot="${1:-}"

    if [[ -z "$bot" ]]; then
        die_safe "usage: bot-auto-resume.sh <bot-name>"
    fi

    if [[ ! " $VALID_BOTS " =~ " $bot " ]]; then
        die_safe "unknown bot: $bot (valid: $VALID_BOTS)"
    fi

    BOT_NAME="$bot"
    init_log "$bot"

    local sidecar
    sidecar=$(sidecar_path "$bot")

    if [[ ! -f "$sidecar" ]]; then
        log "no sidecar at $sidecar — normal startup"
        exit 0
    fi

    if ! jq empty "$sidecar" 2>/dev/null; then
        log "malformed JSON in $sidecar — normal startup"
        exit 0
    fi

    local schema_version
    schema_version=$(jq -r '.schema_version // 0' "$sidecar")
    if [[ "$schema_version" != "1" ]]; then
        log "unknown schema_version=$schema_version — normal startup"
        exit 0
    fi

    local has_required
    has_required=$(jq 'has("status") and has("auto_resume") and has("steps")' "$sidecar")
    if [[ "$has_required" != "true" ]]; then
        log "missing required fields — normal startup"
        exit 0
    fi

    # --- Extract fields ---
    local status auto_resume last_checkpoint resume_count started topic
    local current_step total_steps resumption_context

    status=$(jq -r '.status // "idle"' "$sidecar")
    auto_resume=$(jq -r '.auto_resume // false' "$sidecar")
    last_checkpoint=$(jq -r '.last_checkpoint // ""' "$sidecar")
    resume_count=$(jq -r '.resume_count // 0' "$sidecar")
    started=$(jq -r '.started // ""' "$sidecar")
    topic=$(jq -r '.topic // "unknown task"' "$sidecar")
    current_step=$(jq -r '.current_step // 0' "$sidecar")
    total_steps=$(jq -r '.total_steps // 0' "$sidecar")
    resumption_context=$(jq -r '.resumption_context // ""' "$sidecar")

    # --- Stale in-progress detection ---
    if [[ "$status" == "in-progress" && -n "$last_checkpoint" && "$last_checkpoint" != "null" ]]; then
        local cp_epoch now
        cp_epoch=$(iso_to_epoch "$last_checkpoint")
        now=$(now_epoch)
        if (( cp_epoch > 0 && (now - cp_epoch) > STALE_IN_PROGRESS_SECONDS )); then
            log "stale in-progress detected (last checkpoint $(( (now - cp_epoch) / 60 ))m ago) — treating as interrupted"
            status="interrupted"
            sidecar_update "$sidecar" '.status = "interrupted"'
        fi
    fi

    # --- Decision tree ---

    if [[ "$status" == "completed" || "$status" == "idle" ]]; then
        log "status=$status — normal startup"
        exit 0
    fi

    if [[ "$auto_resume" != "true" ]]; then
        log "auto_resume=$auto_resume — normal startup"
        exit 0
    fi

    if [[ "$status" != "interrupted" ]]; then
        log "status=$status (not interrupted) — normal startup"
        exit 0
    fi

    # --- Safety rails ---

    # Rail 1: Staleness check
    if [[ -n "$started" && "$started" != "null" ]]; then
        local started_epoch now
        started_epoch=$(iso_to_epoch "$started")
        now=$(now_epoch)
        if (( started_epoch > 0 && (now - started_epoch) > STALENESS_SECONDS )); then
            local hours_ago=$(( (now - started_epoch) / 3600 ))
            log "task too stale (started ${hours_ago}h ago) — setting idle"
            log_event "skipped" "$topic" "0" "" "$resume_count" "stale: ${hours_ago}h old"
            sidecar_update "$sidecar" '.status = "idle" | .auto_resume = false'
            send_telegram "$bot" "Auto-resume skipped for <b>$topic</b>: task started ${hours_ago}h ago. Setting idle."
            exit 0
        fi
    fi

    # Rail 2: Attempt limit
    if (( resume_count >= MAX_RESUME_COUNT )); then
        log "attempt limit reached (resume_count=$resume_count) — escalating"
        log_event "skipped" "$topic" "0" "" "$resume_count" "attempt-limit: ${resume_count} resumes"
        sidecar_update "$sidecar" '.status = "idle" | .auto_resume = false'
        send_telegram "$bot" "Failed to complete <b>$topic</b> after $((resume_count + 1)) attempts. Consider breaking into smaller tasks."
        exit 0
    fi

    # Rail 3: Next step safety classification
    local next_step_json
    next_step_json=$(jq '[.steps[] | select(.done == false)] | first // empty' "$sidecar" 2>/dev/null)

    if [[ -z "$next_step_json" ]]; then
        log "no incomplete steps found — setting completed"
        sidecar_update "$sidecar" '.status = "completed" | .auto_resume = false'
        exit 0
    fi

    local next_safety next_num next_desc
    next_safety=$(echo "$next_step_json" | jq -r '.safety // "needs-approval"')
    next_num=$(echo "$next_step_json" | jq -r '.num // 0')
    next_desc=$(echo "$next_step_json" | jq -r '.description // "unknown"')

    case "$next_safety" in
        safe|needs-approval|destructive) ;;
        *)
            log "unrecognized safety='$next_safety' for step $next_num — defaulting to needs-approval"
            next_safety="needs-approval"
            ;;
    esac

    # --- Handle by safety classification ---

    case "$next_safety" in
        safe)
            log "resuming: step $next_num ($next_desc) is safe"
            log_event "resumed" "$topic" "$next_num" "safe" "$((resume_count + 1))" "auto-resume"
            sidecar_update "$sidecar" \
                ".resume_count = $((resume_count + 1)) | .status = \"in-progress\" | .last_checkpoint = \"$(date -Iseconds)\""

            send_telegram "$bot" "Session restarted. Resuming: <b>$topic</b> (step $next_num of $total_steps)"

            build_resume_prompt "$topic" "$next_num" "$total_steps" "$resumption_context" "$sidecar"
            ;;

        needs-approval)
            local token_file
            if token_file=$(find_approval_token "$bot" "$topic" "$next_num"); then
                log "valid approval token found — resuming step $next_num"
                log_event "resumed" "$topic" "$next_num" "needs-approval" "$((resume_count + 1))" "pre-approved-token"
                sidecar_update "$sidecar" \
                    ".resume_count = $((resume_count + 1)) | .status = \"in-progress\" | .last_checkpoint = \"$(date -Iseconds)\""

                send_telegram "$bot" "Session restarted. Resuming (pre-approved): <b>$topic</b> (step $next_num of $total_steps)"

                build_resume_prompt "$topic" "$next_num" "$total_steps" "$resumption_context" "$sidecar"
            else
                log "step $next_num needs approval — writing pending token"
                log_event "approval-needed" "$topic" "$next_num" "needs-approval" "$resume_count" "no-valid-token"
                local token_id
                token_id=$(write_pending_approval_token "$bot" "$topic" "$next_num" "$next_desc")

                sidecar_update "$sidecar" ".resume_count = $((resume_count + 1)) | .last_checkpoint = \"$(date -Iseconds)\""

                send_telegram "$bot" "Session restarted. Step $next_num of <b>$topic</b> needs approval: <b>$next_desc</b>. Waiting for owner."

                build_approval_prompt "$topic" "$next_num" "$next_desc" "$token_id" "$resumption_context"
            fi
            ;;

        destructive)
            log "step $next_num is destructive — setting idle"
            log_event "blocked" "$topic" "$next_num" "destructive" "$resume_count" "destructive-step"
            sidecar_update "$sidecar" '.status = "idle" | .auto_resume = false'
            send_telegram "$bot" "Destructive step in <b>$topic</b> (step $next_num: $next_desc) — manual intervention required."
            exit 0
            ;;
    esac
}

main "$@"

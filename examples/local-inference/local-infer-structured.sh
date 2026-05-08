#!/usr/bin/env bash
# local-infer-structured.sh — Grammar-constrained local LLM inference.
#
# Sends a prompt to a local llama.cpp server and returns schema-validated JSON
# output. Uses llama.cpp's GBNF grammar support to guarantee the response parses.
# Reusable by cron jobs, hooks, and scheduled tasks.
#
# Usage:
#   local-infer-structured.sh --prompt "..." --grammar /path/to/grammar.gbnf
#   local-infer-structured.sh --prompt-file /path/to/prompt.txt --grammar ...
#   echo "..." | local-infer-structured.sh --grammar ...
#
# Options:
#   --prompt TEXT           Prompt text (mutually exclusive with --prompt-file/stdin)
#   --prompt-file PATH      Read prompt from file
#   --grammar PATH          GBNF grammar file (required)
#   --model ALIAS           Model alias (default: your-model-alias)
#   --max-tokens N          Max tokens (default: 2048)
#   --temperature FLOAT     Temperature (default: 0.2)
#   --server URL            llama-server base URL (default: http://localhost:8080)
#   --timeout SECS          Request timeout (default: 120)
#   --retries N             Retries on transient failure (default: 1)
#   --bot NAME              Caller bot name (for telemetry; default: unknown)
#   --job NAME              Caller job name (for telemetry; default: unknown)
#
# Telemetry: every call appends one JSONL record to the telemetry file so you
# can compute latency percentiles, overhead, and throughput per day.
#
# Exit codes: 0 OK, 1 inference failure, 2 usage error, 3 grammar-file missing
# Output (stdout): {"ok":true,"content":"...","usage":{...},"latency_ms":N}
#                  or {"ok":false,"error":"...","attempts":N}

set -uo pipefail

PROMPT=""
PROMPT_FILE=""
GRAMMAR_FILE=""
MODEL="your-model-alias"           # <-- CHANGE THIS
MAX_TOKENS=2048
TEMPERATURE=0.2
SERVER="http://localhost:8080"      # <-- CHANGE THIS (llama-server URL)
TIMEOUT=120
RETRIES=1
BOT="unknown"
JOB="unknown"

TELEMETRY_FILE="${LOCAL_MODEL_TELEMETRY_FILE:-$HOME/.claude/state/telemetry/local-model-calls.jsonl}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prompt)        PROMPT="$2"; shift 2 ;;
        --prompt-file)   PROMPT_FILE="$2"; shift 2 ;;
        --grammar)       GRAMMAR_FILE="$2"; shift 2 ;;
        --model)         MODEL="$2"; shift 2 ;;
        --max-tokens)    MAX_TOKENS="$2"; shift 2 ;;
        --temperature)   TEMPERATURE="$2"; shift 2 ;;
        --server)        SERVER="$2"; shift 2 ;;
        --timeout)       TIMEOUT="$2"; shift 2 ;;
        --retries)       RETRIES="$2"; shift 2 ;;
        --bot)           BOT="$2"; shift 2 ;;
        --job)           JOB="$2"; shift 2 ;;
        -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

[[ -z "$GRAMMAR_FILE" ]] && { echo '{"ok":false,"error":"--grammar is required"}'; exit 2; }
[[ -f "$GRAMMAR_FILE" ]] || { echo "{\"ok\":false,\"error\":\"grammar file not found: $GRAMMAR_FILE\"}"; exit 3; }

if [[ -n "$PROMPT_FILE" ]]; then
    [[ -f "$PROMPT_FILE" ]] || { echo "{\"ok\":false,\"error\":\"prompt file not found: $PROMPT_FILE\"}"; exit 2; }
    PROMPT=$(cat "$PROMPT_FILE")
elif [[ -z "$PROMPT" ]]; then
    if [[ ! -t 0 ]]; then
        PROMPT=$(cat)
    else
        echo '{"ok":false,"error":"no prompt provided (use --prompt, --prompt-file, or stdin)"}'; exit 2
    fi
fi

GRAMMAR_CONTENT=$(cat "$GRAMMAR_FILE")

BACKEND_LABEL=$(echo "$SERVER" | sed -E 's|^https?://[^:/]+||; s|/.*||')
[[ -z "$BACKEND_LABEL" ]] && BACKEND_LABEL="$SERVER"

emit_telemetry() {
    local status="$1" tokens_in="${2:-0}" tokens_out="${3:-0}" \
          latency_ms="${4:-0}" generation_ms="${5:-null}" \
          throughput="${6:-null}"
    local overhead_ms
    if [[ "$generation_ms" == "null" ]]; then
        overhead_ms="null"
    else
        overhead_ms=$(awk -v l="$latency_ms" -v g="$generation_ms" 'BEGIN{printf "%.3f", l-g}')
    fi

    mkdir -p "$(dirname "$TELEMETRY_FILE")"
    jq -cn \
        --arg ts       "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
        --arg bot      "$BOT" \
        --arg backend  "$BACKEND_LABEL" \
        --arg job      "$JOB" \
        --arg status   "$status" \
        --argjson tin  "$tokens_in" \
        --argjson tout "$tokens_out" \
        --argjson lat  "$latency_ms" \
        --argjson gen  "$generation_ms" \
        --argjson ovr  "$overhead_ms" \
        --argjson thr  "$throughput" \
        '{ts:$ts, bot:$bot, backend:$backend, job:$job,
          tokens_in:$tin, tokens_out:$tout,
          latency_ms:$lat, generation_ms:$gen, overhead_ms:$ovr,
          throughput_tok_per_ms:$thr, status:$status}' \
        >>"$TELEMETRY_FILE" 2>/dev/null || true
}

PAYLOAD=$(jq -n \
    --arg model    "$MODEL" \
    --arg prompt   "$PROMPT" \
    --arg grammar  "$GRAMMAR_CONTENT" \
    --argjson mt   "$MAX_TOKENS" \
    --argjson temp "$TEMPERATURE" \
    '{
        model: $model,
        messages: [{role: "user", content: $prompt}],
        max_tokens: $mt,
        temperature: $temp,
        grammar: $grammar,
        chat_template_kwargs: {enable_thinking: false}
    }')

attempt=0
last_error=""
while [[ $attempt -le $RETRIES ]]; do
    attempt=$((attempt + 1))
    START_NS=$(date +%s%N)
    RESP=$(curl -sS --max-time "$TIMEOUT" -X POST "$SERVER/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" 2>&1) || { last_error="curl: $RESP"; continue; }
    END_NS=$(date +%s%N)
    LATENCY_MS=$(( (END_NS - START_NS) / 1000000 ))

    CONTENT=$(echo "$RESP" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    USAGE=$(echo "$RESP" | jq -c '.usage // {}' 2>/dev/null)
    [[ -z "$USAGE" ]] && USAGE='{}'

    TOK_IN=$(echo "$RESP"  | jq -r '.usage.prompt_tokens     // 0' 2>/dev/null)
    TOK_OUT=$(echo "$RESP" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
    PROMPT_MS=$(echo "$RESP" | jq -r '.timings.prompt_ms // null' 2>/dev/null)
    PRED_MS=$(echo    "$RESP" | jq -r '.timings.predicted_ms // null' 2>/dev/null)
    PRED_PER_S=$(echo "$RESP" | jq -r '.timings.predicted_per_second // null' 2>/dev/null)
    if [[ "$PROMPT_MS" != "null" && "$PRED_MS" != "null" ]]; then
        GEN_MS=$(awk -v p="$PROMPT_MS" -v g="$PRED_MS" 'BEGIN{printf "%.3f", p+g}')
    else
        GEN_MS="null"
    fi
    if [[ "$PRED_PER_S" != "null" ]]; then
        THROUGHPUT=$(awk -v s="$PRED_PER_S" 'BEGIN{printf "%.6f", s/1000.0}')
    else
        THROUGHPUT="null"
    fi

    if [[ -n "$CONTENT" ]]; then
        emit_telemetry "ok" "$TOK_IN" "$TOK_OUT" "$LATENCY_MS" "$GEN_MS" "$THROUGHPUT"
        jq -n \
            --arg content "$CONTENT" \
            --argjson usage "$USAGE" \
            --argjson latency "$LATENCY_MS" \
            --argjson attempts "$attempt" \
            '{ok: true, content: $content, usage: $usage, latency_ms: $latency, attempts: $attempts}'
        exit 0
    fi

    last_error=$(echo "$RESP" | jq -r '.error.message // .error // "empty content"' 2>/dev/null)
    [[ -z "$last_error" ]] && last_error="empty content / parse error"
done

emit_telemetry "fail" 0 0 "${LATENCY_MS:-0}" "null" "null"
jq -n --arg err "$last_error" --argjson a "$attempt" \
    '{ok: false, error: $err, attempts: $a}'
exit 1

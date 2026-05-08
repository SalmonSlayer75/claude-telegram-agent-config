#!/usr/bin/env bash
# GPU queue client — enqueue requests, check status, wait for completion.
#
# Usage:
#   gpu-queue-client.sh enqueue <id> <priority> <backend_hint> <payload_json>
#   gpu-queue-client.sh status  <id>
#   gpu-queue-client.sh wait    <id> [timeout_sec]

set -euo pipefail

STATE_DIR="${GPU_QUEUE_STATE_DIR:-$HOME/state/gpu-queue}"    # <-- CHANGE THIS
JOURNAL="$STATE_DIR/queue.jsonl"

cmd_enqueue() {
  local id="$1" priority="$2" backend="$3" payload="$4"

  mkdir -p "$STATE_DIR"

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local record
  record=$(jq -cn \
    --arg id "$id" \
    --arg priority "$priority" \
    --arg backend "$backend" \
    --arg ts "$ts" \
    --argjson payload "$payload" \
    '{kind:"enqueue", id:$id, priority:$priority, backend_hint:$backend, enqueued_at:$ts, payload:$payload}')

  echo "$record" >> "$JOURNAL"
  echo "enqueued: $id"
}

cmd_status() {
  local id="$1"
  python3 -c "
import json, sys
want = sys.argv[1]
state = 'unknown'
try:
    with open(sys.argv[2]) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get('id') != want:
                continue
            k = r.get('kind')
            if k == 'enqueue' and state == 'unknown':
                state = 'pending'
            elif k == 'dispatch':
                state = 'in-flight'
            elif k == 'complete':
                state = r.get('outcome', 'complete')
except FileNotFoundError:
    pass
print(state)
" "$id" "$JOURNAL"
}

cmd_wait() {
  local id="$1" timeout="${2:-30}" waited=0
  while :; do
    local s
    s=$(cmd_status "$id")
    case "$s" in
      pending|in-flight|unknown) : ;;
      *) echo "$s"; return 0 ;;
    esac
    if (( waited >= timeout )); then
      echo "timeout"; return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

case "${1:-}" in
  enqueue) shift; cmd_enqueue "$@" ;;
  status)  shift; cmd_status "$@" ;;
  wait)    shift; cmd_wait "$@" ;;
  *) echo "usage: $0 {enqueue|status|wait} ..." >&2; exit 2 ;;
esac

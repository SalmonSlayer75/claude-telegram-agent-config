#!/usr/bin/env bash
# stale-lock-janitor.sh — Sweeps stale .lock files using flock-based detection.
#
# flock-based detection: if `flock -n` succeeds, nobody holds the lock → file
# is stale. Only deletes locks whose mtime is > 30 min old (grace window).
# Logs every action (kept, deleted, skipped).
#
# Safe by construction: flock acquisition is non-blocking; if any process holds
# the lock, we leave it alone regardless of age.
#
# Usage:
#   stale-lock-janitor.sh                 # normal run (deletes stale locks)
#   stale-lock-janitor.sh --dry-run       # report only, no deletions
#   STALE_LOCK_ROOT=/tmp/t stale-lock-janitor.sh   # override scan root (for tests)

set -u
set -o pipefail

ROOT="${STALE_LOCK_ROOT:-$HOME/.claude/state}"
GRACE_SECONDS="${STALE_LOCK_GRACE_SECONDS:-1800}"   # 30 min
LOG_FILE="${STALE_LOCK_LOG:-$HOME/logs/stale-lock-janitor.log}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE"
}

if [[ ! -d "$ROOT" ]]; then
  log "SKIP root=$ROOT not a directory"
  exit 0
fi

now=$(date +%s)
scanned=0
deleted=0
kept_held=0
kept_fresh=0

while IFS= read -r -d '' f; do
  scanned=$((scanned + 1))
  mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
  age=$((now - mtime))

  if (( age < GRACE_SECONDS )); then
    kept_fresh=$((kept_fresh + 1))
    log "KEEP fresh age=${age}s path=$f"
    continue
  fi

  # Try non-blocking flock. Exit 0 => we got it => nobody holds it => stale.
  if flock -n "$f" -c true 2>/dev/null; then
    if (( DRY_RUN )); then
      log "WOULD-DELETE stale age=${age}s path=$f (dry-run)"
    else
      if rm -f "$f" 2>/dev/null; then
        deleted=$((deleted + 1))
        log "DELETE stale age=${age}s path=$f"
      else
        log "ERROR rm-failed path=$f"
      fi
    fi
  else
    kept_held=$((kept_held + 1))
    log "KEEP held age=${age}s path=$f"
  fi
done < <(find "$ROOT" -type f -name '*.lock' -print0 2>/dev/null)

log "SUMMARY scanned=$scanned deleted=$deleted kept_held=$kept_held kept_fresh=$kept_fresh dry_run=$DRY_RUN"
exit 0

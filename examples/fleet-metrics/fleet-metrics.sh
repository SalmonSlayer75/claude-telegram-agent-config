#!/usr/bin/env bash
# fleet-metrics.sh — Prometheus textfile counter emitter for a Claude Code bot fleet.
#
# Usage (shell library):
#   source ~/bin/fleet-metrics.sh
#   fleet_metric_inc fleet_bake_total bot=work reason=watchdog
#   fleet_metric_set fleet_watchdog_queue_depth bot=work value=3
#
# Usage (CLI):
#   ~/bin/fleet-metrics.sh inc fleet_bake_total bot=work reason=watchdog
#   ~/bin/fleet-metrics.sh set fleet_watchdog_queue_depth bot=work 3
#
# Output: ~/.claude/fleet-metrics/textfile/<metric>.prom
# Format: Prometheus textfile collector (one metric per file, atomic rename).
#
# Contract: best-effort, fail-soft. Never blocks or errors the caller.

set -u

FLEET_METRICS_DIR="${FLEET_METRICS_DIR:-$HOME/.claude/fleet-metrics/textfile}"
mkdir -p "$FLEET_METRICS_DIR" 2>/dev/null || true

_fleet_metric_atomic_write() {
    local target="$1"
    local contents="$2"
    local tmp="${target}.$$.tmp"
    printf '%s\n' "$contents" > "$tmp"
    mv "$tmp" "$target"
}

_fleet_metric_labels_to_prom() {
    local labels=""
    local first=1
    for kv in "$@"; do
        local k="${kv%%=*}"
        local v="${kv#*=}"
        [ "$first" -eq 0 ] && labels="${labels},"
        labels="${labels}${k}=\"${v}\""
        first=0
    done
    if [ -n "$labels" ]; then
        printf '{%s}' "$labels"
    fi
}

_fleet_metric_read_existing() {
    local file="$1"
    local labels="$2"
    [ -f "$file" ] || { printf '0'; return; }
    local line
    line="$(grep -F "${labels}" "$file" 2>/dev/null | grep -v '^#' | head -n1)"
    if [ -z "$line" ]; then
        printf '0'
    else
        printf '%s' "${line##* }"
    fi
}

# fleet_metric_inc <metric_name> [label=val ...]
# Increments a counter. Thread-safe via flock.
fleet_metric_inc() {
    _fleet_metric_inc_inner "$@" 2>/dev/null || return 0
}
_fleet_metric_inc_inner() {
    local metric="$1"
    shift
    local file="${FLEET_METRICS_DIR}/${metric}.prom"
    local labels
    labels="$(_fleet_metric_labels_to_prom "$@")"

    (
        flock -w 1 9 || exit 0
        local current
        current="$(_fleet_metric_read_existing "$file" "$labels")"
        local new=$((current + 1))
        _fleet_metric_rewrite "$file" "$metric" "$labels" "$new"
    ) 9> "${file}.lock"
}

# fleet_metric_set <metric_name> [label=val ...] <value>
# Sets a gauge (last arg is always the value).
fleet_metric_set() {
    _fleet_metric_set_inner "$@" 2>/dev/null || return 0
}
_fleet_metric_set_inner() {
    local metric="$1"
    shift
    local value="${!#}"
    local args=("$@")
    unset 'args[${#args[@]}-1]'
    local file="${FLEET_METRICS_DIR}/${metric}.prom"
    local labels
    labels="$(_fleet_metric_labels_to_prom "${args[@]}")"

    (
        flock -w 1 9 || exit 0
        _fleet_metric_rewrite "$file" "$metric" "$labels" "$value"
    ) 9> "${file}.lock"
}

_fleet_metric_rewrite() {
    local file="$1"
    local metric="$2"
    local labels="$3"
    local value="$4"
    local new_line="${metric}${labels} ${value}"
    local contents=""

    if [ -f "$file" ]; then
        local existing
        existing="$(grep -vF "${labels} " "$file" 2>/dev/null || true)"
        contents="${existing}"
    fi

    local metric_type="gauge"
    case "$metric" in
        *_total) metric_type="counter" ;;
    esac
    if ! printf '%s' "$contents" | grep -q "^# HELP ${metric} "; then
        contents="# HELP ${metric} Fleet metric
# TYPE ${metric} ${metric_type}
${contents}"
    fi

    contents="$(printf '%s' "$contents" | sed -e '/^$/d')"
    contents="${contents}
${new_line}"

    _fleet_metric_atomic_write "$file" "$contents"
}

# CLI entrypoint
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        inc) fleet_metric_inc "$@" ;;
        set) fleet_metric_set "$@" ;;
        *)
            echo "Usage: $0 {inc|set} <metric> [label=val ...] [value_for_set]" >&2
            exit 1
            ;;
    esac
fi

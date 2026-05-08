# Fleet Metrics — Prometheus-Compatible Bot Metrics

Emits Prometheus textfile-format counters and gauges for bot fleet monitoring. Works as both a shell library (source it) and a CLI tool.

## Usage

```bash
# As a library (in watchdog, hooks, etc.)
source ~/bin/fleet-metrics.sh
fleet_metric_inc fleet_bake_total bot=work reason=watchdog
fleet_metric_set fleet_session_age_seconds bot=work 3600

# As a CLI
~/bin/fleet-metrics.sh inc fleet_bake_total bot=work reason=context_limit
~/bin/fleet-metrics.sh set fleet_pending_tasks bot=devops 5
```

## Output Format

Each metric gets its own `.prom` file in `~/.claude/fleet-metrics/textfile/`:

```
# HELP fleet_bake_total Fleet metric
# TYPE fleet_bake_total counter
fleet_bake_total{bot="work",reason="watchdog"} 3
fleet_bake_total{bot="research",reason="context_limit"} 1
```

## Design

- **Thread-safe** — flock-based locking per metric file
- **Fail-soft** — all errors silently swallowed; never blocks the caller
- **Atomic writes** — tmp file + rename prevents partial reads
- **Dual-mode** — source as library for hooks/scripts, run as CLI for ad-hoc use
- **Convention** — metrics ending in `_total` are typed as counters; everything else is a gauge

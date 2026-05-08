# Stale Lock Janitor

Sweeps `.lock` files that are no longer held by any process. Uses `flock -n` (non-blocking) to safely detect unheld locks — if we can acquire the lock, nobody owns it.

## The Problem

Lock files accumulate when processes crash without cleaning up. Stale locks can block bot startups, resume workers, and other coordination mechanisms.

## How It Works

1. Scans all `.lock` files under `~/.claude/state/`
2. Skips files younger than 30 minutes (grace window for slow operations)
3. Tries `flock -n` on each old lock — if it succeeds, nobody holds it
4. Deletes unheld locks; leaves held locks alone regardless of age

## Safety

- **Never deletes a held lock** — the flock probe is the safety mechanism
- **Grace window** — fresh locks are never touched, even if unheld
- **Dry-run mode** — `--dry-run` reports what would be deleted without acting
- **Structured logging** — every action (KEEP/DELETE/SKIP) is logged

## Setup

Run via cron every 15-30 minutes:

```cron
*/15 * * * * $HOME/bin/stale-lock-janitor.sh >> /dev/null 2>&1
```

## Environment Overrides

- `STALE_LOCK_ROOT` — scan directory (default: `~/.claude/state`)
- `STALE_LOCK_GRACE_SECONDS` — grace window (default: 1800 = 30 min)
- `STALE_LOCK_LOG` — log file path

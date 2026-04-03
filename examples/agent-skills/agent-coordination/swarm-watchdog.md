# /swarm-watchdog — Orchestrator Polling Agent

Runs every 15 minutes during active sprint work. Checks all active sprint groups
for completion, stalls, or anomalies. Push-based auto-announce is unreliable —
this pull-based watchdog is the authoritative completion signal.

## Trigger
Spawned by orchestrator as a cron job during active sprints:
```bash
# Add to crontab during active sprints, remove when sprint completes
*/15 * * * * claude -p "Run swarm watchdog: check active sprint groups for completion or stalls. Report if action needed, HEARTBEAT_OK if all clear."
```

## What to check

```bash
cd ~/your-repo

# Find all active sprint pm-state files
find reports/swarm -name "pm-state.json" -newer reports/swarm/run-events.jsonl 2>/dev/null \
  | sort -r | head -5

# For each pm-state, read status
for f in $(find reports/swarm -name "pm-state.json" | sort -r | head -3); do
  RUN=$(dirname $f | xargs basename)
  echo "=== $RUN ==="
  cat $f | python3 -c "
import sys, json
d = json.load(sys.stdin)
for g, v in d.get('groups', {}).items():
    print(f'  Group {g}: {v.get(\"status\",\"?\")} | updated: {d.get(\"lastUpdated\",\"?\")}')
for a in d.get('activeAgents', []):
    print(f'  Active: {a.get(\"role\")} started {a.get(\"startedAt\",\"?\")}')
"
done
```

## Detection logic

For each group in a non-terminal status:

| Status | Expected output file | Stale threshold |
|--------|---------------------|-----------------|
| `review-p1` | `review-pass1.md` | 45 min |
| `revision-p1` | `impl-spec-v2.md` | 20 min |
| `executor` | `executor-complete.json` | 90 min |
| `review-p2` | `review-pass2.md` | 45 min |
| `revision-p2` | (new commit on branch) | 20 min |

```bash
# Check if output file exists but pm-state wasn't updated
check_group() {
  local RUNDIR=$1
  local GROUP=$2
  local STATUS=$3
  local EXPECTED_FILE=$4
  local STALE_MIN=$5

  if [ -f "$RUNDIR/group-$GROUP/$EXPECTED_FILE" ]; then
    echo "WARNING: group-$GROUP: output $EXPECTED_FILE EXISTS but status still '$STATUS' — update pm-state"
    return 1  # needs pm-state update
  fi

  # Check if agent has been running too long
  START=$(python3 -c "
import json
d = json.load(open('$RUNDIR/pm-state.json'))
agents = d.get('activeAgents', [])
a = next((x for x in agents if str(x.get('group')) == '$GROUP'), None)
print(a.get('startedAt', '') if a else '')
")
  if [ -n "$START" ]; then
    AGE=$(python3 -c "
from datetime import datetime, timezone
start = datetime.fromisoformat('$START'.replace('Z','+00:00'))
age = (datetime.now(timezone.utc) - start).total_seconds() / 60
print(int(age))
" 2>/dev/null || echo 0)
    if [ "$AGE" -gt "$STALE_MIN" ]; then
      echo "ALERT: group-$GROUP: agent in '$STATUS' for ${AGE}m (limit: ${STALE_MIN}m) — STALL DETECTED"
      return 2  # stall
    fi
  fi
  return 0  # all clear
}
```

## Response protocol

**If output file exists but pm-state not updated:**
- Update pm-state.json to correct status
- Continue to next phase (spawn next agent if applicable)
- Report to user: "Sprint [N] Group [N]: [status] complete (caught by watchdog). Advancing to [next step]."

**If stall detected (agent running > threshold):**
- Check if the subagent session is still alive
- If dead: re-spawn the agent from last known state
- Report to user: "Sprint [N] Group [N]: agent appears stalled at [status] for [N] min. Re-spawning."

**If all clear:**
- Reply HEARTBEAT_OK (no user notification)

## pm-state update helper

```python
import json
from pathlib import Path
from datetime import datetime, timezone

def update_pm_state(run_id, group_n, new_status, extra=None):
    f = Path(f"reports/swarm/{run_id}/pm-state.json")
    state = json.loads(f.read_text()) if f.exists() else {"runId": run_id, "groups": {}}
    g = str(group_n)
    state.setdefault("groups", {}).setdefault(g, {})
    state["groups"][g]["status"] = new_status
    if extra:
        state["groups"][g].update(extra)
    state["lastUpdated"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    f.write_text(json.dumps(state, indent=2))
    print(f"pm-state: group {group_n} → {new_status}")
```

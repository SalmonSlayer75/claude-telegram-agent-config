# Auto-Resume — Interrupted Work Recovery

Sessions die mid-task. Without structured state, the next session starts cold and the interrupted work is lost. This system tracks task progress in a JSON sidecar, classifies each step by safety, and automatically resumes interrupted work on restart.

## The Problem

Claude Code sessions end unexpectedly — context limits, crashes, system restarts. Multi-step work (deploy a feature, run a migration, update documentation) gets abandoned at whatever step was in progress. The next session has no idea what was happening.

## The Solution

Three components work together:

1. **bot-auto-resume.sh** — Detection engine. Reads the JSON sidecar at session startup, checks safety rails, and emits a resume prompt if interrupted work should be continued.
2. **ac-resume-write.sh** — Fallback sidecar writer. Atomically writes JSON from stdin when the Edit tool can't access the sidecar path (permission zones).

The bot itself writes the sidecar during normal operation (via Edit tool). These scripts handle the startup-resume and edge-case-write paths.

## Safety Rails

- **Staleness** — Tasks started >2 hours ago are too stale to resume. Set to idle, notify owner.
- **Attempt limit** — After 2 resume attempts, escalate to owner ("task too large, break it up").
- **Step classification:**
  - `safe` — read files, analyze, draft, run tests. Auto-resumes without approval.
  - `needs-approval` — send email, merge PR, publish. Checks for a durable approval token on disk; if none, asks owner via Telegram.
  - `destructive` — force push, file deletion, production deploy. Never auto-resumed.

## JSON Sidecar Format

```json
{
  "schema_version": 1,
  "topic": "Deploy API v2 endpoints",
  "status": "interrupted",
  "auto_resume": true,
  "started": "2026-05-01T10:00:00+00:00",
  "last_checkpoint": "2026-05-01T10:15:00+00:00",
  "resume_count": 0,
  "current_step": 3,
  "total_steps": 5,
  "steps": [
    {"num": 1, "description": "Run test suite", "safety": "safe", "done": true, "result": "all pass"},
    {"num": 2, "description": "Update configs", "safety": "safe", "done": true, "result": "3 files changed"},
    {"num": 3, "description": "Deploy to staging", "safety": "needs-approval", "done": false, "result": null},
    {"num": 4, "description": "Run smoke tests", "safety": "safe", "done": false, "result": null},
    {"num": 5, "description": "Deploy to production", "safety": "destructive", "done": false, "result": null}
  ],
  "artifacts": [],
  "resumption_context": "Tests passed, configs updated. Next: deploy to staging (needs approval).",
  "approval_token": null
}
```

## Approval Tokens

When the next step needs approval, the system writes a pending token to disk and notifies the owner. The owner can approve by placing an approval token file. If the session dies after approval but before execution, the next session finds the token and proceeds without re-asking.

Token files live in `<state-dir>/approval-tokens/` with format `approve-<timestamp>-step<N>.json`.

## Setup

1. Copy scripts to `~/bin/` and `chmod +x`
2. Configure `lib/auto-resume-paths.sh` with your bot names and state directories
3. Add `bot-auto-resume.sh <botname>` as the last step of your bot's start script
4. Have your bot write `ac-resume.json` after completing each step (dual-write: JSON sidecar first, then markdown state file)

## Design Decisions

- **JSON sidecar is source of truth** — The markdown state file is for human readability. Resume logic reads only the JSON.
- **Fail-safe** — `bot-auto-resume.sh` exits 0 always. It never blocks session startup.
- **Atomic writes** — All sidecar mutations use tmp+mv to prevent corruption.
- **Stale-in-progress detection** — If status is "in-progress" but last checkpoint is >5 minutes old, treat as interrupted (the session died without updating status).

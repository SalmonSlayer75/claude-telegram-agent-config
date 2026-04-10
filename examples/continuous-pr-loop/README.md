# Continuous PR Loop

An automated pipeline that takes a task description and produces a merged PR — with implementation, cleanup, CI fixing, and review all handled by separate Claude Code sessions.

## The Problem

Using `claude -p` for one-shot tasks works, but the output often needs cleanup: AI-typical cruft (unnecessary tests, defensive code, console.logs), CI failures that need fixing, and review findings that should be addressed before merge. Doing this manually defeats the purpose of automation.

## The Solution

A bash script that orchestrates 5 phases, each in its own Claude Code session:

### Phase 1: Implement
Full tool access. Executes the task, runs tests, updates shared notes for future iterations.

### Phase 2: De-sloppify
Fresh context window reviews all uncommitted changes and removes:
- Tests that verify language/framework behavior rather than business logic
- Over-defensive error handling for impossible states
- `console.log`, commented-out code, TODO placeholders
- Redundant type checks the type system already enforces

### Phase 3: Commit + PR
Stages changes, writes a conventional commit message, pushes, creates PR.

### Phase 4: CI Watch + Fix
Waits for CI checks. If they fail, runs a fix pass with the failure output as context. Retries up to `--max-fixes` times.

### Phase 5: Review
A separate session (optionally using a more capable model) reviews the PR diff for bugs, security issues, and edge cases. Reports findings as P0/P1/P2. P0 findings block the merge.

### Merge
If review passes and `--no-merge` isn't set, squash-merges the PR.

## Model Routing

Different phases benefit from different models:
- **Implementation/cleanup/CI fixes**: Use a fast model (sonnet) — these are high-volume, well-scoped tasks
- **Review**: Use a more capable model (opus) — this requires deeper reasoning about correctness

```bash
continuous-pr-loop.sh ~/myproject "Fix issue #42" \
  --model-implement sonnet \
  --model-review opus
```

## Multi-Iteration Mode

For large tasks, use `--max-runs` to iterate. A `SHARED_TASK_NOTES.md` file persists context across iterations:

```bash
continuous-pr-loop.sh ~/myproject "Migrate all API endpoints to v2" --max-runs 5
```

Each iteration reads the notes, does incremental work, updates the notes, and creates a PR. The next iteration picks up where the last one left off.

## Usage

```bash
# Single task, review but don't merge
continuous-pr-loop.sh ~/myproject "Add input validation to all API handlers" --no-merge

# Multi-iteration with CI fix retries
continuous-pr-loop.sh ~/myproject "Refactor auth module" --max-runs 3 --max-fixes 5

# Custom branch prefix
continuous-pr-loop.sh ~/myproject "Update deps" --branch-prefix auto-deps
```

## Prerequisites

- `claude` CLI installed and authenticated
- `gh` CLI installed and authenticated
- Repository with CI checks configured
- Git remote configured for push

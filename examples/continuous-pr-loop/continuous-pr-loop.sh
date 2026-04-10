#!/usr/bin/env bash
# continuous-pr-loop.sh — Automated branch→implement→review→PR→CI→fix→merge cycle
#
# Runs Claude Code in one-shot mode through a multi-phase pipeline:
#   1. Implement — execute the task prompt with full tool access
#   2. De-sloppify — cleanup pass removing AI-typical cruft
#   3. Commit + PR — stage, commit, push, create PR
#   4. CI watch — wait for checks, auto-fix failures (up to N retries)
#   5. Review — separate context window reviews the PR for issues
#   6. Merge — squash-merge if no P0 findings (or --no-merge to skip)
#
# Supports multiple iterations via --max-runs for large tasks that
# benefit from incremental progress with shared notes.
#
# Usage:
#   continuous-pr-loop.sh <repo-dir> <task-prompt> [options]
#
# Options:
#   --max-runs N          Number of implement→PR iterations (default: 1)
#   --max-fixes N         Max CI fix attempts per PR (default: 3)
#   --no-merge            Create PR but don't merge
#   --branch-prefix STR   Branch name prefix (default: claude-auto)
#   --model-implement M   Model for implementation (default: sonnet)
#   --model-review M      Model for review (default: opus)
#
# Examples:
#   continuous-pr-loop.sh ~/myproject "Fix all TODO comments in src/" --max-runs 3
#   continuous-pr-loop.sh ~/myproject "Implement feature per issue #42" --no-merge

set -euo pipefail

# --- Args ---
REPO_DIR="${1:?Usage: continuous-pr-loop.sh <repo-dir> <task-prompt> [options]}"
TASK_PROMPT="${2:?Usage: continuous-pr-loop.sh <repo-dir> <task-prompt> [options]}"
shift 2

MAX_RUNS=1
MAX_CI_FIXES=3
NO_MERGE=false
BRANCH_PREFIX="claude-auto"
MODEL_IMPLEMENT="sonnet"
MODEL_REVIEW="opus"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-runs) MAX_RUNS="$2"; shift 2 ;;
    --max-fixes) MAX_CI_FIXES="$2"; shift 2 ;;
    --no-merge) NO_MERGE=true; shift ;;
    --branch-prefix) BRANCH_PREFIX="$2"; shift 2 ;;
    --model-implement) MODEL_IMPLEMENT="$2"; shift 2 ;;
    --model-review) MODEL_REVIEW="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

LOG_FILE="/tmp/continuous-pr-loop-$(date +%Y%m%d-%H%M%S).log"
NOTES_FILE="$REPO_DIR/SHARED_TASK_NOTES.md"

log() { echo "[$(date -u '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# --- Main loop ---
cd "$REPO_DIR"

# Initialize shared notes for cross-iteration context
if [ ! -f "$NOTES_FILE" ]; then
  cat > "$NOTES_FILE" << 'NOTES'
# Shared Task Notes
This file persists context across iterations. Update after each run.

## Task
(filled by first iteration)

## Completed
(none yet)

## Remaining
(to be determined)

## Lessons
(patterns discovered during work)
NOTES
  log "Created $NOTES_FILE"
fi

for RUN in $(seq 1 "$MAX_RUNS"); do
  log "=== Iteration $RUN of $MAX_RUNS ==="

  # Ensure we're on main and up to date
  git checkout main 2>/dev/null || git checkout master 2>/dev/null
  git pull --ff-only 2>/dev/null || true

  BRANCH="${BRANCH_PREFIX}/run-${RUN}-$(date +%s)"
  git checkout -b "$BRANCH"
  log "Branch: $BRANCH"

  # Phase 1: Implement
  log "Phase 1: Implement (model: $MODEL_IMPLEMENT)"
  claude -p --model "$MODEL_IMPLEMENT" \
    --allowedTools "Read,Write,Edit,Bash,Grep,Glob" \
    --max-turns 30 \
    --permission-mode dontAsk \
    "Read $NOTES_FILE for context from previous iterations.

Your task: $TASK_PROMPT

After completing your work:
1. Run all tests to verify nothing is broken
2. Update $NOTES_FILE with what you completed and what remains
3. Do NOT commit — the next phase handles that" \
    >> "$LOG_FILE" 2>&1

  # Phase 2: De-sloppify (separate context window for fresh eyes)
  log "Phase 2: De-sloppify (model: $MODEL_IMPLEMENT)"
  claude -p --model "$MODEL_IMPLEMENT" \
    --allowedTools "Read,Edit,Bash,Grep,Glob" \
    --max-turns 15 \
    --permission-mode dontAsk \
    "Cleanup pass on all uncommitted changes in this repo.
Remove:
- Tests that verify language/framework behavior rather than business logic
- Over-defensive error handling for impossible states
- console.log, commented-out code, TODO placeholders
- Redundant type checks the type system already enforces

Run the full test suite after cleanup. Do NOT commit." \
    >> "$LOG_FILE" 2>&1

  # Check if there are any changes to commit
  if git diff --quiet && git diff --cached --quiet; then
    log "No changes after implementation — skipping PR"
    git checkout main 2>/dev/null || git checkout master 2>/dev/null
    git branch -D "$BRANCH" 2>/dev/null || true
    continue
  fi

  # Phase 3: Commit and PR
  log "Phase 3: Commit + PR (model: $MODEL_IMPLEMENT)"
  claude -p --model "$MODEL_IMPLEMENT" \
    --allowedTools "Read,Bash,Grep,Glob" \
    --max-turns 10 \
    --permission-mode dontAsk \
    "Stage and commit all changes with a clear conventional commit message.
Push the branch and create a PR using 'gh pr create'.
Include a summary of changes and link any relevant issues.
Do NOT merge the PR." \
    >> "$LOG_FILE" 2>&1

  # Phase 4: Wait for CI and fix if needed
  PR_NUMBER=$(gh pr list --head "$BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")

  if [ -z "$PR_NUMBER" ]; then
    log "WARNING: No PR found for branch $BRANCH — skipping CI check"
    continue
  fi

  log "PR #$PR_NUMBER created. Waiting for CI..."

  CI_FIX_COUNT=0
  while [ "$CI_FIX_COUNT" -lt "$MAX_CI_FIXES" ]; do
    if gh pr checks "$PR_NUMBER" --watch --fail-fast 2>/dev/null; then
      log "CI passed on PR #$PR_NUMBER"
      break
    fi

    CI_FIX_COUNT=$((CI_FIX_COUNT + 1))
    log "CI failed (attempt $CI_FIX_COUNT/$MAX_CI_FIXES) — running fix pass"

    CI_OUTPUT=$(gh pr checks "$PR_NUMBER" 2>/dev/null || echo "unknown failure")

    claude -p --model "$MODEL_IMPLEMENT" \
      --allowedTools "Read,Edit,Bash,Grep,Glob" \
      --max-turns 20 \
      --permission-mode dontAsk \
      "CI failed on PR #$PR_NUMBER. Check results:

$CI_OUTPUT

Fix the failing checks. Run tests locally to verify. Commit and push the fix." \
      >> "$LOG_FILE" 2>&1
  done

  # Phase 5: Review (uses more capable model)
  log "Phase 5: Review (model: $MODEL_REVIEW)"
  REVIEW_RESULT=$(claude -p --model "$MODEL_REVIEW" \
    --allowedTools "Read,Grep,Glob,Bash" \
    --max-turns 10 \
    --permission-mode dontAsk \
    "Review PR #$PR_NUMBER (branch: $BRANCH).
Run 'gh pr diff $PR_NUMBER' to see the changes.
Check for: bugs, security issues, edge cases, missing tests.
Report findings as P0 (block merge), P1 (should fix), P2 (nice to have).
If there are P0 findings, list them clearly." \
    2>>"$LOG_FILE")

  if echo "$REVIEW_RESULT" | grep -qi "P0"; then
    log "P0 findings in review — NOT merging PR #$PR_NUMBER"
    echo "$REVIEW_RESULT" >> "$LOG_FILE"
  elif [ "$NO_MERGE" = true ]; then
    log "PR #$PR_NUMBER ready but --no-merge flag set"
  else
    log "Merging PR #$PR_NUMBER"
    gh pr merge "$PR_NUMBER" --squash --delete-branch 2>>"$LOG_FILE" || log "Merge failed — manual review needed"
  fi

  git checkout main 2>/dev/null || git checkout master 2>/dev/null
  log "=== Iteration $RUN complete ==="
done

log "Continuous PR loop finished. Log: $LOG_FILE"
echo "$LOG_FILE"

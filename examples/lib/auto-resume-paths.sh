#!/usr/bin/env bash
# auto-resume-paths.sh — Single source of truth for per-bot auto-resume
# artifact directories.
#
# USAGE:
#   source ~/bin/lib/auto-resume-paths.sh
#   dir=$(auto_resume_state_dir "<bot>")
#   sidecar="$dir/ac-resume.json"
#
# ARTIFACTS IN THIS DIRECTORY:
#   - ac-resume.json          (JSON sidecar)
#   - approval-tokens/        (durable approval tokens)
#   - auto-resume.log         (per-bot resume log)
#   - resume-worker.log       (worker execution log)
#
# CUSTOMIZE: Update the associative array below with your bot names and
# their state directories. Two patterns are supported:
#   1. Legacy: ~/.claude/state/<bot>/  (central location)
#   2. Project-tree: ~/<BotWorkDir>/state/auto-resume/  (co-located with bot)
#
# You can migrate bots one at a time by changing their entry below.

declare -gA AUTO_RESUME_DIRS=(
  [work]="$HOME/.claude/state/work"              # <-- CUSTOMIZE
  [research]="$HOME/.claude/state/research"      # <-- CUSTOMIZE
  [devops]="$HOME/DevOpsBot/state/auto-resume"   # example: project-tree path
  [engineering]="$HOME/.claude/state/engineering" # <-- CUSTOMIZE
)

# Post-migration destinations (uncomment when cutting over a bot):
#   [work]="$HOME/WorkBot/state/auto-resume"
#   [research]="$HOME/ResearchBot/state/auto-resume"
#   [engineering]="$HOME/EngineeringBot/state/auto-resume"

auto_resume_state_dir() {
  local bot="$1"
  echo "${AUTO_RESUME_DIRS[$bot]:-$HOME/.claude/state/$bot}"
}

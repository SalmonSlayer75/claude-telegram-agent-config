#!/usr/bin/env bash
# gate-lists.sh — SINGLE SOURCE OF TRUTH for tool classification.
#
# Sourced by both the runtime gate (bot-gate.py) and the audit script.
# Any divergence between them is a P0 bug.
#
# Classification algorithm:
#   1. If name is in GATE_EXEMPT_EXACT        → exempt (always allowed)
#   2. Elif name is in GATE_SUBSTANTIVE_EXACT  → substantive (counted/gated)
#   3. Elif any prefix in GATE_SUBSTANTIVE_PREFIXES matches → substantive
#   4. Else → UNCLASSIFIED (fail-closed: blocked + sentinel alert)

# Substantive tools — gate counter increments for these.
# These represent real work: file edits, web access, shell commands, etc.
GATE_SUBSTANTIVE_EXACT="
WebSearch
WebFetch
Bash
Edit
Write
MultiEdit
NotebookEdit
Agent
TaskCreate
"

# Any tool name starting with one of these prefixes is substantive.
# Add your MCP tool prefixes here.
GATE_SUBSTANTIVE_PREFIXES="
mcp__google-workspace__
mcp__notion__
mcp__calendar__
mcp__email__
"

# Exempt tools — always allowed, never counted.
# These are read-only, meta, or trivial-interaction tools.
GATE_EXEMPT_EXACT="
Read
Grep
Glob
TodoWrite
TaskUpdate
TaskList
TaskGet
TaskOutput
TaskStop
ToolSearch
Skill
ExitPlanMode
EnterPlanMode
AskUserQuestion
ReadMcpResourceTool
ListMcpResourcesTool
mcp__telegram__reply
mcp__telegram__react
mcp__telegram__edit_message
RemoteTrigger
CronList
CronCreate
CronDelete
EnterWorktree
ExitWorktree
"

export GATE_SUBSTANTIVE_EXACT GATE_SUBSTANTIVE_PREFIXES GATE_EXEMPT_EXACT

#!/usr/bin/env python3
"""
instinct-observe.py — PostToolUse hook for capturing tool-use observations.

Part of the instinct learning system. Captures tool events to a JSONL file
for later pattern analysis by the observer agent.

Design:
  - Atomic append via fsync (no partial lines on crash)
  - Secret scrubbing: strips token/key/password patterns
  - Throttled: skips noisy read-only tools (Read, Grep, Glob)
  - Max observation size: 2KB per entry (truncates large outputs)
  - File rotation: when log exceeds 1MB, rotates to .1 backup

Usage in settings.local.json:
  PostToolUse hook: instinct-observe.py <bot-name>
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

# --- config ---

MAX_ENTRY_BYTES = 2048
MAX_LOG_BYTES = 1_048_576  # 1MB rotation threshold
MAX_INPUT_CHARS = 500
MAX_OUTPUT_CHARS = 1000

# Tools that generate too much noise to observe
SKIP_TOOLS = frozenset({
    "Read", "Grep", "Glob", "ToolSearch", "Skill",
    "TodoWrite", "TaskUpdate", "TaskList", "TaskGet", "TaskOutput", "TaskStop",
    "ExitPlanMode", "EnterPlanMode", "AskUserQuestion",
    "ReadMcpResourceTool", "ListMcpResourcesTool",
    "EnterWorktree", "ExitWorktree",
})

# Patterns to scrub from observations
SECRET_PATTERNS = [
    re.compile(r'(?i)(token|key|password|secret|credential|auth)["\s:=]+["\']?[\w\-\.]{8,}'),
    re.compile(r'(?i)Bearer\s+[\w\-\.]+'),
    re.compile(r'\b\d{4,}:[A-Za-z0-9_\-]{20,}\b'),  # Bot tokens
]

# Map bot names to working directories — customize for your fleet
BOT_WORKDIRS = {
    "mybot":  "MyProject",
    "devops": "DevOps",
}


def _home() -> Path:
    return Path(os.environ.get("HOME", os.path.expanduser("~")))


def _obs_dir(bot: str) -> Path:
    workdir = BOT_WORKDIRS.get(bot, bot)
    d = _home() / workdir / "instincts"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _obs_log(bot: str) -> Path:
    return _obs_dir(bot) / "observations.jsonl"


def _scrub(text: str) -> str:
    for pat in SECRET_PATTERNS:
        text = pat.sub("[REDACTED]", text)
    return text


def _truncate(text: str, max_chars: int) -> str:
    if len(text) <= max_chars:
        return text
    return text[:max_chars] + f"... [truncated, {len(text)} total chars]"


def _rotate_if_needed(log_path: Path) -> None:
    try:
        if log_path.exists() and log_path.stat().st_size > MAX_LOG_BYTES:
            backup = log_path.with_suffix(".jsonl.1")
            if backup.exists():
                backup.unlink()
            log_path.rename(backup)
    except OSError:
        pass


def observe(bot: str) -> int:
    try:
        raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        payload = json.loads(raw or "{}")
    except (json.JSONDecodeError, ValueError):
        return 0

    tool_name = payload.get("tool_name", "")
    tool_input = payload.get("tool_input", {})
    tool_output = payload.get("tool_output", "")

    if tool_name in SKIP_TOOLS or not tool_name:
        return 0

    input_str = json.dumps(tool_input) if isinstance(tool_input, dict) else str(tool_input)
    output_str = str(tool_output) if tool_output else ""

    entry = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "bot": bot,
        "tool": tool_name,
        "input_summary": _scrub(_truncate(input_str, MAX_INPUT_CHARS)),
        "output_summary": _scrub(_truncate(output_str, MAX_OUTPUT_CHARS)),
        "session_epoch": int(os.environ.get("CLAUDE_SESSION_EPOCH", "0") or "0"),
    }

    entry_json = json.dumps(entry, ensure_ascii=False)
    if len(entry_json.encode("utf-8")) > MAX_ENTRY_BYTES:
        entry["output_summary"] = entry["output_summary"][:200] + "...[trimmed]"
        entry_json = json.dumps(entry, ensure_ascii=False)

    log_path = _obs_log(bot)
    _rotate_if_needed(log_path)

    try:
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(entry_json + "\n")
            f.flush()
            os.fsync(f.fileno())
    except OSError as e:
        print(f"instinct-observe: write error: {e}", file=sys.stderr)

    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: instinct-observe.py <bot-name>", file=sys.stderr)
        return 1
    bot = sys.argv[1]
    if bot not in BOT_WORKDIRS:
        print(f"instinct-observe: unknown bot '{bot}'", file=sys.stderr)
        return 0
    return observe(bot)


if __name__ == "__main__":
    sys.exit(main())

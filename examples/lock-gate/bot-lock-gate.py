#!/usr/bin/env python3
"""
bot-lock-gate.py — Lock-aware PreToolUse gate for concurrent access protection.

Purpose
-------
Enforces live-session exclusion while a background worker (e.g., resume worker,
mail-turn) holds a flock on a shared lock file. The long-lived Telegram session
must NOT perform substantive writes while a background subprocess is actively
running against the same state.

Read-only tools always pass. Substantive tools (Edit, Write, Bash-non-whitelist,
WebFetch, WebSearch, MCP writes) are denied while the lock is held.

Stale-write guard
-----------------
When a Write is denied due to lock hold, the path is recorded in a guard file.
After the lock is released, a Write to a guarded path is denied until a Read of
that path clears the guard entry. This prevents stale writes based on pre-lock
file contents. Edit/MultiEdit pass naturally because their old_string contract
forces a fresh read.

Usage in settings.local.json (PreToolUse hook):
    bot-lock-gate.py mybot --check
"""
from __future__ import annotations

import errno
import fcntl
import json
import os
import shlex
import sys
import time
from pathlib import Path
from typing import Optional


# Map bot names to working directories — CUSTOMIZE for your fleet
BOT_WORKDIRS = {
    "work":        "WorkBot",
    "research":    "ResearchBot",
    "devops":      "DevOps",
    "engineering": "Engineering",
}

DEFAULT_TOOL_CLASSES = str(
    Path.home() / "DevOps" / "fleet" / "tool-classes.json"
)


def _home() -> Path:
    return Path(os.path.expanduser("~"))


def _state_dir(bot: str) -> Path:
    override = os.environ.get("BOT_LOCK_GATE_STATE_DIR_OVERRIDE")
    if override:
        return Path(override) / bot
    return _home() / ".claude" / "state" / bot


def _lock_path(bot: str) -> Path:
    return _state_dir(bot) / "resume-worker.lock"


def _guard_path(bot: str) -> Path:
    return _state_dir(bot) / ".stale-write-guard"


def _sentinel_log(bot: str) -> Path:
    log = _home() / ".claude" / "channels" / f"bot-lock-gate-{bot}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    return log


def _sentinel(bot: str, msg: str) -> None:
    try:
        with open(_sentinel_log(bot), "a", encoding="utf-8") as fh:
            fh.write(f"{int(time.time())} BOT-LOCK-GATE {msg}\n")
    except OSError:
        pass


def _load_classes() -> dict:
    path = os.environ.get(
        "BOT_LOCK_GATE_TOOL_CLASSES_OVERRIDE", DEFAULT_TOOL_CLASSES
    )
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def _allow() -> int:
    return 0


def _deny(reason: str) -> int:
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    sys.stdout.write(json.dumps(payload))
    sys.stdout.write("\n")
    sys.stdout.flush()
    return 0


def _lock_is_held(bot: str) -> tuple[bool, Optional[int]]:
    """Probe the lock file with a non-blocking flock."""
    lp = _lock_path(bot)
    if not lp.exists():
        return (False, None)
    try:
        fh = open(lp, "r+")
    except OSError:
        return (False, None)
    try:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            if e.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
                return (True, None)
            return (False, None)
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        return (False, None)
    finally:
        try:
            fh.close()
        except OSError:
            pass


def _read_guard(bot: str) -> set[str]:
    gp = _guard_path(bot)
    if not gp.exists():
        return set()
    try:
        with open(gp, "r", encoding="utf-8") as fh:
            return {ln.strip() for ln in fh if ln.strip()}
    except OSError:
        return set()


def _write_guard(bot: str, entries: set[str]) -> None:
    gp = _guard_path(bot)
    gp.parent.mkdir(parents=True, exist_ok=True)
    tmp = gp.with_suffix(gp.suffix + ".tmp")
    try:
        tmp.write_text("".join(f"{p}\n" for p in sorted(entries)),
                       encoding="utf-8")
        tmp.replace(gp)
    except OSError:
        pass


def _guard_add(bot: str, path: str) -> None:
    entries = _read_guard(bot)
    entries.add(path)
    _write_guard(bot, entries)


def _guard_remove(bot: str, path: str) -> None:
    entries = _read_guard(bot)
    if path in entries:
        entries.discard(path)
        _write_guard(bot, entries)


def _bash_is_read_only(command: str, classes: dict) -> bool:
    """Return True iff the bash command is safe to run under lock."""
    if not isinstance(command, str) or not command.strip():
        return False
    try:
        tokens = shlex.split(command)
    except ValueError:
        return False
    if not tokens:
        return False
    if any(op in tokens for op in ("&&", "||", ";", "|", ">", ">>", "<", "<<")):
        return False
    head = tokens[0]
    whitelist = set(classes.get("bash_read_only_whitelist", []))
    if head in whitelist:
        return True
    if head == "git" and len(tokens) >= 2:
        ro_sub = set(classes.get("bash_read_only_git_subcommands", []))
        for sub in ro_sub:
            sub_tokens = sub.split()
            if tokens[1:1 + len(sub_tokens)] == sub_tokens:
                return True
    return False


def _classify(tool_name: str, tool_input: dict, classes: dict) -> str:
    """Returns 'read_only', 'substantive', or 'unknown'."""
    if not tool_name:
        return "unknown"
    read_only = set(classes.get("read_only", []))
    substantive = set(classes.get("substantive", []))
    prefixes = list(classes.get("substantive_prefixes", []))
    if tool_name in read_only:
        return "read_only"
    if tool_name in substantive:
        return "substantive"
    for p in prefixes:
        if tool_name.startswith(p):
            return "substantive"
    if tool_name == "Bash":
        cmd = ""
        if isinstance(tool_input, dict):
            cmd = tool_input.get("command") or ""
        return "read_only" if _bash_is_read_only(cmd, classes) else "substantive"
    return "unknown"


def _target_path(tool_name: str, tool_input: dict) -> Optional[str]:
    if not isinstance(tool_input, dict):
        return None
    for key in ("file_path", "notebook_path", "path"):
        v = tool_input.get(key)
        if isinstance(v, str) and v:
            try:
                return str(Path(v).resolve())
            except OSError:
                return v
    return None


def mode_check(bot: str) -> int:
    try:
        raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        payload = json.loads(raw or "{}")
    except Exception:
        return _allow()

    # If we ARE the background worker, always allow
    if os.environ.get("BOT_RESUME_WORKER") == "1":
        return _allow()

    tool_name = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}
    if not tool_name:
        return _allow()

    classes = _load_classes()
    if not classes:
        return _allow()

    cls = _classify(tool_name, tool_input, classes)
    held, _ = _lock_is_held(bot)

    if held:
        if cls == "read_only":
            return _allow()
        tgt = _target_path(tool_name, tool_input)
        if tgt and tool_name in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
            _guard_add(bot, tgt)
        reason = (
            f"[LOCK-GATE] Background worker in progress (lock held); "
            f"retry after lock release. tool={tool_name} class={cls}"
        )
        _sentinel(bot, f"deny: held tool={tool_name} cls={cls}")
        return _deny(reason)

    # Lock not held — check stale-write guard for Write tool
    if tool_name == "Read":
        tgt = _target_path(tool_name, tool_input)
        if tgt:
            _guard_remove(bot, tgt)
        return _allow()

    if tool_name == "Write":
        tgt = _target_path(tool_name, tool_input)
        if tgt:
            guard = _read_guard(bot)
            if tgt in guard:
                reason = (
                    f"[LOCK-GATE] stale-write-guard: {tgt} was denied "
                    f"during background worker run; Read it first to clear "
                    f"the guard before Write."
                )
                return _deny(reason)

    return _allow()


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.stderr.write("usage: bot-lock-gate.py <bot> [--check]\n")
        return 2
    bot = argv[1]
    if bot not in BOT_WORKDIRS:
        sys.stderr.write(f"unknown bot: {bot}\n")
        return 2
    mode = argv[2] if len(argv) >= 3 else "--check"
    if mode != "--check":
        sys.stderr.write(f"unknown mode: {mode}\n")
        return 2
    return mode_check(bot)


if __name__ == "__main__":
    sys.exit(main(sys.argv))

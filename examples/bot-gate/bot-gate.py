#!/usr/bin/env python3
"""
bot-gate.py — Unified state-save enforcement gate (memory-stack v5).

Replaces simple "reminder" hooks with a hard gate that BLOCKS substantive
tool calls unless the bot has acknowledged new messages and periodically
updates its Active Conversation section in the state file.

Two invariants enforced:
  1. ACK invariant — after a new Telegram message arrives, the bot MUST
     update ## Active Conversation before any substantive tool call.
  2. COUNTER invariant — after 10 substantive tool calls without updating
     ## Active Conversation, the gate blocks until the bot updates.

Three modes:
  --arm        UserPromptSubmit hook. Arms the marker on inbound message.
  --check      PreToolUse hook. Enforces both invariants.
  --stop-warn  Stop hook. Emits stderr if marker still live at session end.

Exit contract:
  Arm mode always exits 0 (never blocks inbound).
  Check mode exits 0 with deny JSON on block, plain 0 on allow.
  Stop-warn mode always exits 0.

Tool classification:
  - "exempt" tools (Read, Grep, Glob, etc.) always pass — they don't change state
  - "substantive" tools (Bash, Edit, Write, WebSearch, etc.) are counted/gated
  - Edits to the bot's own state file always pass (that's the escape hatch)

Usage in settings.local.json:
  UserPromptSubmit: bot-gate.py mybot --arm
  PreToolUse:       bot-gate.py mybot --check
  Stop:             bot-gate.py mybot --stop-warn

Requires:
  - gate-lists.sh (tool classification source of truth)
  - active-conversation-hash (helper that hashes ## Active Conversation)
"""
from __future__ import annotations

import contextlib
import errno
import fcntl
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional


# ----- paths ------------------------------------------------------

# Map bot names to their working directories and state file names.
# Customize these for your fleet.
BOT_WORKDIRS = {
    "mybot":   "MyProject",
    "devops":  "DevOps",
    # Add your bots here
}

STATE_FILENAMES = {
    "mybot":   "mybot-state.md",
    "devops":  "devops-state.md",
    # Add your bots here
}


def _home() -> Path:
    return Path(os.path.expanduser("~"))


def _state_dir(bot: str) -> Path:
    override = os.environ.get("BOT_GATE_STATE_DIR_OVERRIDE")
    if override:
        return Path(override) / bot
    return _home() / ".claude" / "state" / bot


def _state_file(bot: str) -> Path:
    override = os.environ.get("BOT_GATE_STATE_FILE_OVERRIDE")
    if override:
        return Path(override)
    return _home() / BOT_WORKDIRS[bot] / STATE_FILENAMES[bot]


def _lock_path(bot: str) -> Path:
    return _state_dir(bot) / ".bot-gate.lock"


def _marker_path(bot: str) -> Path:
    return _state_dir(bot) / "bot-gate-pending-ack.v1"


def _counter_path(bot: str) -> Path:
    return _state_dir(bot) / "bot-gate-counter.v2"


def _sentinel_log(bot: str) -> Path:
    return _home() / ".claude" / "channels" / f"bot-gate-{bot}.log"


# ----- classification lists (sourced from gate-lists.sh) ----------

_LISTS_CACHE: Optional[dict] = None


def _load_gate_lists() -> dict:
    """Source gate-lists.sh via bash and capture the three exported lists.
    Single source of truth shared with the audit script."""
    global _LISTS_CACHE
    if _LISTS_CACHE is not None:
        return _LISTS_CACHE

    script = (
        'source "$HOME/bin/gate-lists.sh" >/dev/null && '
        'printf "%s\\n---\\n%s\\n---\\n%s\\n" '
        '"$GATE_EXEMPT_EXACT" '
        '"$GATE_SUBSTANTIVE_EXACT" '
        '"$GATE_SUBSTANTIVE_PREFIXES"'
    )
    try:
        out = subprocess.check_output(
            ["bash", "-c", script],
            stderr=subprocess.DEVNULL,
            timeout=3,
        ).decode("utf-8", errors="replace")
    except Exception as e:
        raise RuntimeError(f"cannot source gate-lists.sh: {e}") from e

    parts = out.split("\n---\n")
    if len(parts) < 3:
        raise RuntimeError("gate-lists.sh returned unexpected shape")
    exempt       = set(tok for tok in parts[0].split() if tok)
    substantive  = set(tok for tok in parts[1].split() if tok)
    sub_prefixes = [tok for tok in parts[2].split() if tok]
    _LISTS_CACHE = {
        "exempt": exempt,
        "substantive_exact": substantive,
        "substantive_prefixes": sub_prefixes,
    }
    return _LISTS_CACHE


def classify(name: str) -> str:
    if not isinstance(name, str) or not name:
        return "UNCLASSIFIED"
    lists = _load_gate_lists()
    if name in lists["exempt"]:
        return "exempt"
    if name in lists["substantive_exact"]:
        return "substantive"
    for p in lists["substantive_prefixes"]:
        if name.startswith(p):
            return "substantive"
    return "UNCLASSIFIED"


# ----- hash helper ------------------------------------------------

def _hash_ac(bot: str) -> tuple[int, str]:
    """Hash the ## Active Conversation section. Returns (rc, hash).
    rc: 0=ok, 1=helper error, 2=section malformed/missing."""
    helper = _home() / "bin" / "active-conversation-hash"
    if not helper.exists():
        return 1, ""
    state = _state_file(bot)
    if not state.exists():
        return 2, ""
    try:
        p = subprocess.run(
            [str(helper), str(state)],
            capture_output=True, timeout=5,
        )
    except Exception:
        return 1, ""
    if p.returncode == 0:
        return 0, p.stdout.decode().strip()
    if p.returncode == 2:
        return 2, ""
    return 1, ""


# ----- flock ------------------------------------------------------

@contextlib.contextmanager
def _flock(path: Path, timeout: float = 2.0):
    """Acquire an exclusive flock with timeout."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fh = open(path, "w")
    deadline = time.monotonic() + timeout
    acquired = False
    while time.monotonic() < deadline:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired = True
            break
        except OSError as e:
            if e.errno not in (errno.EWOULDBLOCK, errno.EAGAIN):
                raise
            time.sleep(0.05)
    try:
        yield fh if acquired else None
    finally:
        if acquired:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
        try:
            fh.close()
        except OSError:
            pass


# ----- marker + counter file I/O ----------------------------------

def _read_marker(bot: str) -> Optional[tuple[str, int]]:
    mp = _marker_path(bot)
    if not mp.exists():
        return None
    try:
        line = mp.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    parts = line.split("|")
    if len(parts) != 3 or parts[0] != "v1":
        return None
    try:
        return parts[1], int(parts[2])
    except ValueError:
        return None


def _write_marker(bot: str, live_hash: str) -> None:
    mp = _marker_path(bot)
    mp.parent.mkdir(parents=True, exist_ok=True)
    tmp = mp.with_suffix(mp.suffix + ".tmp")
    tmp.write_text(f"v1|{live_hash}|{int(time.time())}\n", encoding="utf-8")
    tmp.replace(mp)


def _clear_marker(bot: str) -> None:
    try:
        _marker_path(bot).unlink()
    except FileNotFoundError:
        pass


def _read_counter(bot: str) -> tuple[int, str, int]:
    cp = _counter_path(bot)
    if not cp.exists():
        return 0, "", 0
    try:
        line = cp.read_text(encoding="utf-8").strip()
    except OSError:
        return 0, "", 0
    parts = line.split("|")
    if len(parts) != 4 or parts[0] != "v2":
        return 0, "", 0
    try:
        count = int(parts[1])
    except ValueError:
        return 0, "", 0
    if count < 0:
        return 0, "", 0
    last_hash = parts[2]
    try:
        changed_at = int(parts[3])
    except ValueError:
        changed_at = 0
    return count, last_hash, changed_at


def _write_counter(bot: str, count: int, last_hash: str, changed_at: int) -> None:
    cp = _counter_path(bot)
    cp.parent.mkdir(parents=True, exist_ok=True)
    tmp = cp.with_suffix(cp.suffix + ".tmp")
    tmp.write_text(f"v2|{count}|{last_hash}|{changed_at}\n", encoding="utf-8")
    tmp.replace(cp)


def _sentinel(bot: str, msg: str) -> None:
    log = _sentinel_log(bot)
    log.parent.mkdir(parents=True, exist_ok=True)
    with open(log, "a", encoding="utf-8") as fh:
        fh.write(f"{int(time.time())} BOT-GATE-SENTINEL {msg}\n")


# ----- mode: arm --------------------------------------------------

ARM_CONTEXT_TEMPLATE = (
    "[BOT-GATE: NEW INBOUND — ACK REQUIRED] A new Telegram "
    "message just arrived. Before calling any substantive work "
    "tool, update the ## Active Conversation section of {state_file} "
    "to reflect what was requested. The gate will hard-deny "
    "work-tool calls until that section changes."
)


def mode_arm(bot: str) -> int:
    rc_hash, live_hash = _hash_ac(bot)
    if rc_hash != 0:
        _sentinel(bot, f"arm: hash helper rc={rc_hash} (fail-open)")
        _emit_arm_json(bot)
        return 0

    try:
        with _flock(_lock_path(bot), timeout=2.0) as lk:
            if lk is None:
                _sentinel(bot, "arm: flock timeout (fail-open)")
            else:
                _write_marker(bot, live_hash)
    except Exception as e:
        _sentinel(bot, f"arm: exception {e!r} (fail-open)")

    _emit_arm_json(bot)
    return 0


def _emit_arm_json(bot: str) -> None:
    ctx = ARM_CONTEXT_TEMPLATE.format(state_file=str(_state_file(bot)))
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": ctx,
        }
    }
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


# ----- mode: check ------------------------------------------------

MARKER_DENY_REASON = (
    "[BOT-GATE] Active Conversation has not been updated since the "
    "latest inbound Telegram message. Update the ## Active "
    "Conversation section of {state_file} BEFORE running any "
    "substantive work tool. This is a hard gate, not a reminder."
)

COUNTER_DENY_REASON = (
    "[BOT-GATE] 10 substantive tool calls since the last update to "
    "## Active Conversation in {state_file}. Update that section "
    "now. This is a hard gate, not a reminder."
)

MALFORMED_DENY_REASON = (
    "[BOT-GATE] ## Active Conversation section in {state_file} is "
    "malformed, empty, duplicated, or missing. Repair it via "
    "Edit/Write on the state file, then retry."
)


def _deny_json(reason: str) -> int:
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()
    return 0


def _allow() -> int:
    return 0


def _is_state_file_edit(tool_name: str, tool_input: dict, bot: str) -> bool:
    """Edits to the bot's own state file are always allowed (escape hatch)."""
    if tool_name not in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        return False
    if not isinstance(tool_input, dict):
        return False
    path = tool_input.get("file_path")
    if not isinstance(path, str):
        return False
    try:
        return Path(path).resolve() == _state_file(bot).resolve()
    except OSError:
        return False


def mode_check(bot: str) -> int:
    try:
        raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
        payload = json.loads(raw or "{}")
    except (json.JSONDecodeError, ValueError, TypeError):
        _sentinel(bot, "check: malformed stdin JSON (fail-open)")
        return _allow()

    tool_name = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}

    # Escape hatch: bot can always edit its own state file
    if _is_state_file_edit(tool_name, tool_input, bot):
        return _allow()

    # Classify tool
    try:
        cls = classify(tool_name)
    except RuntimeError as e:
        _sentinel(bot, f"check: classify failed {e!r} (fail-open)")
        return _allow()

    if cls == "exempt":
        return _allow()
    if cls == "UNCLASSIFIED":
        _sentinel(bot, f"check: UNCLASSIFIED tool={tool_name!r}")
        return _deny_json(
            f"[BOT-GATE] tool '{tool_name}' is not classified in "
            f"gate-lists.sh. Add it and re-run the audit before retrying."
        )

    # --- substantive: enforce both invariants under flock ---
    rc_hash, live_hash = _hash_ac(bot)
    if rc_hash == 2:
        return _deny_json(MALFORMED_DENY_REASON.format(state_file=_state_file(bot)))
    if rc_hash == 1:
        return _allow()

    with _flock(_lock_path(bot), timeout=2.0) as lk:
        if lk is None:
            _sentinel(bot, "check: flock timeout (fail-closed)")
            return _deny_json(
                "[BOT-GATE] gate lock timeout — retry. If persistent, "
                "check the sentinel log."
            )

        # Re-hash inside critical section (TOCTOU prevention)
        rc2, live_hash2 = _hash_ac(bot)
        if rc2 == 2:
            return _deny_json(MALFORMED_DENY_REASON.format(state_file=_state_file(bot)))
        if rc2 == 0:
            live_hash = live_hash2

        # Marker check (ack invariant)
        marker = _read_marker(bot)
        if marker is not None:
            marker_hash, _arm_epoch = marker
            if live_hash == marker_hash:
                return _deny_json(
                    MARKER_DENY_REASON.format(state_file=_state_file(bot))
                )
            _clear_marker(bot)

        # Counter check (periodic update invariant)
        count, last_hash, changed_at = _read_counter(bot)
        now = int(time.time())
        if live_hash != last_hash:
            count = 0
            last_hash = live_hash
            changed_at = now
        count += 1

        if count >= 10:
            _write_counter(bot, count, last_hash, changed_at)
            return _deny_json(
                COUNTER_DENY_REASON.format(state_file=_state_file(bot))
            )

        if count >= 5:
            sys.stderr.write(
                f"[BOT-GATE WARN] {count} substantive tool calls since "
                f"the last ## Active Conversation edit. Save soon.\n"
            )

        _write_counter(bot, count, last_hash, changed_at)

    return _allow()


# ----- mode: stop-warn --------------------------------------------

def mode_stop_warn(bot: str) -> int:
    marker = _read_marker(bot)
    if marker is not None:
        sys.stderr.write(
            f"[BOT-GATE WARN] Stop: pending-ack marker still live "
            f"for {bot}. Active Conversation was not updated.\n"
        )
    return 0


# ----- entry point ------------------------------------------------

def main() -> int:
    args = sys.argv[1:]
    if len(args) < 2:
        sys.stderr.write("usage: bot-gate.py <bot> --arm|--check|--stop-warn\n")
        return 2
    bot, mode = args[0], args[1]
    if bot not in BOT_WORKDIRS:
        sys.stderr.write(f"bot-gate.py: unknown bot: {bot}\n")
        return 2

    _state_dir(bot).mkdir(parents=True, exist_ok=True)

    if mode == "--arm":
        return mode_arm(bot)
    if mode == "--check":
        return mode_check(bot)
    if mode == "--stop-warn":
        return mode_stop_warn(bot)
    sys.stderr.write(f"bot-gate.py: unknown mode: {mode}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())

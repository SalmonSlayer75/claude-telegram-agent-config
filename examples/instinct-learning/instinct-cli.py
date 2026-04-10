#!/usr/bin/env python3
"""
instinct-cli.py — Instinct lifecycle management CLI.

Commands:
  instinct-cli.py <bot> list              # list all instincts with confidence
  instinct-cli.py <bot> show <name>       # show full instinct details
  instinct-cli.py <bot> apply             # output high-confidence instincts for context injection
  instinct-cli.py <bot> prune             # remove instincts with confidence <= 0
  instinct-cli.py <bot> reset             # delete all instincts and observations

The 'apply' command is used by the session start hook to inject learned
instincts into the bot's context at the beginning of each session.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any

APPLY_THRESHOLD = 0.5   # minimum confidence for context injection
MAX_APPLY_CHARS = 1500  # budget for injection text

# Map bot names to working directories — customize for your fleet
BOT_WORKDIRS = {
    "mybot":  "MyProject",
    "devops": "DevOps",
}


def _home() -> Path:
    return Path(os.environ.get("HOME", os.path.expanduser("~")))


def _instinct_dir(bot: str) -> Path:
    workdir = BOT_WORKDIRS.get(bot, bot)
    return _home() / workdir / "instincts"


def _parse_yaml(text: str) -> dict[str, Any]:
    """Minimal YAML parser for instinct format."""
    result: dict[str, Any] = {}
    current_list_key = None
    for line in text.splitlines():
        if line.startswith("---"):
            continue
        if line.startswith("  - ") and current_list_key:
            result.setdefault(current_list_key, []).append(line.strip("- ").strip())
            continue
        current_list_key = None
        m = re.match(r'^(\w[\w_]*)\s*:\s*(.*)', line)
        if m:
            key, val = m.group(1), m.group(2).strip()
            if val == "":
                current_list_key = key
                result[key] = []
            elif val.replace(".", "").replace("-", "").isdigit():
                try:
                    result[key] = float(val) if "." in val else int(val)
                except ValueError:
                    result[key] = val
            else:
                result[key] = val
    return result


def _load_instincts(bot: str) -> list[dict]:
    inst_dir = _instinct_dir(bot)
    if not inst_dir.exists():
        return []
    instincts = []
    for f in inst_dir.glob("instinct-*.yaml"):
        try:
            data = _parse_yaml(f.read_text(encoding="utf-8"))
            data["_path"] = str(f)
            data["_file"] = f.name
            instincts.append(data)
        except OSError:
            continue
    return sorted(instincts, key=lambda x: -float(x.get("confidence", 0)))


def cmd_list(bot: str) -> int:
    instincts = _load_instincts(bot)
    if not instincts:
        print(f"No instincts for {bot}.")
        return 0
    print(f"{'Confidence':>10}  {'Type':<18}  {'Name'}")
    print(f"{'─'*10}  {'─'*18}  {'─'*40}")
    for inst in instincts:
        conf = inst.get("confidence", "?")
        marker = " *" if float(conf) >= APPLY_THRESHOLD else ""
        print(f"{conf:>10}  {inst.get('type', '?'):<18}  {inst.get('name', '?')}{marker}")
    above = sum(1 for i in instincts if float(i.get("confidence", 0)) >= APPLY_THRESHOLD)
    print(f"\n{len(instincts)} instincts, {above} above apply threshold ({APPLY_THRESHOLD})")
    return 0


def cmd_show(bot: str, name: str) -> int:
    for inst in _load_instincts(bot):
        if inst.get("name") == name or name in inst.get("_file", ""):
            for key, val in inst.items():
                if key.startswith("_"):
                    continue
                if isinstance(val, list):
                    print(f"{key}:")
                    for item in val:
                        print(f"  - {item}")
                else:
                    print(f"{key}: {val}")
            return 0
    print(f"Instinct '{name}' not found.")
    return 1


def cmd_apply(bot: str) -> int:
    """Output high-confidence instincts as context injection text."""
    instincts = _load_instincts(bot)
    applicable = [i for i in instincts if float(i.get("confidence", 0)) >= APPLY_THRESHOLD]
    if not applicable:
        return 0
    lines = ["[LEARNED INSTINCTS — apply these patterns during this session]"]
    total_chars = len(lines[0])
    for inst in applicable:
        line = f"- [{inst.get('type', '?')}] {inst.get('pattern', '')} → {inst.get('action', '')}"
        if total_chars + len(line) > MAX_APPLY_CHARS:
            break
        lines.append(line)
        total_chars += len(line)
    print("\n".join(lines))
    return 0


def cmd_prune(bot: str) -> int:
    pruned = 0
    for inst in _load_instincts(bot):
        if float(inst.get("confidence", 0)) <= 0:
            path = inst.get("_path")
            if path:
                try:
                    Path(path).unlink()
                    pruned += 1
                    print(f"  Pruned: {inst.get('name', '?')}")
                except OSError:
                    pass
    print(f"Pruned {pruned} instincts.")
    return 0


def cmd_reset(bot: str) -> int:
    inst_dir = _instinct_dir(bot)
    removed = 0
    for f in inst_dir.glob("instinct-*.yaml"):
        try:
            f.unlink()
            removed += 1
        except OSError:
            pass
    for obs_file in ["observations.jsonl", "observations.jsonl.1"]:
        p = inst_dir / obs_file
        if p.exists():
            p.unlink()
            print(f"Removed {obs_file}")
    print(f"Reset: removed {removed} instincts.")
    return 0


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 1
    bot, cmd = sys.argv[1], sys.argv[2]
    if bot not in BOT_WORKDIRS:
        print(f"Unknown bot: {bot}", file=sys.stderr)
        return 1
    if cmd == "list":
        return cmd_list(bot)
    elif cmd == "show":
        return cmd_show(bot, sys.argv[3]) if len(sys.argv) > 3 else 1
    elif cmd == "apply":
        return cmd_apply(bot)
    elif cmd == "prune":
        return cmd_prune(bot)
    elif cmd == "reset":
        return cmd_reset(bot)
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

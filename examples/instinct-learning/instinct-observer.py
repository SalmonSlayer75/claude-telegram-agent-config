#!/usr/bin/env python3
"""
instinct-observer.py — Pattern detector for the instinct learning system.

Reads observations.jsonl, detects recurring patterns, and writes/updates
instinct YAML files with confidence scoring.

Runs on-demand or via cron. Pattern types detected:
  1. repeated_flow  — same tool sequence used 3+ times across sessions
  2. error_resolve  — bot hits an error, then resolves it via specific tool
  3. tool_preference — consistent choice of one tool over alternatives
  4. correction     — approach changes after user interaction

Instinct format (YAML):
  name: short-descriptive-name
  type: correction|error_resolve|repeated_flow|tool_preference
  confidence: 0.3-0.85
  scope: project|fleet
  pattern: description of what was observed
  action: what the bot should do differently
  evidence:
    - observation timestamps/summaries
  created: ISO timestamp
  last_seen: ISO timestamp
  hit_count: N

Usage:
  instinct-observer.py <bot-name>              # analyze and update instincts
  instinct-observer.py <bot-name> --dry-run    # show what would be created
  instinct-observer.py <bot-name> --stats      # show observation stats
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

# --- config ---

MIN_REPEAT_COUNT = 3       # repeated_flow threshold
MIN_CONFIDENCE = 0.3       # minimum confidence for new instinct
MAX_CONFIDENCE = 0.85      # cap — never fully trust automated learning
CONFIDENCE_BUMP = 0.05     # per additional observation
CONFIDENCE_DECAY = 0.01    # per day since last_seen
MIN_OBSERVATIONS = 20      # don't analyze until enough data

# Map bot names to working directories — customize for your fleet
BOT_WORKDIRS = {
    "mybot":  "MyProject",
    "devops": "DevOps",
}


def _home() -> Path:
    return Path(os.environ.get("HOME", os.path.expanduser("~")))


def _instinct_dir(bot: str) -> Path:
    workdir = BOT_WORKDIRS.get(bot, bot)
    d = _home() / workdir / "instincts"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _obs_log(bot: str) -> Path:
    return _instinct_dir(bot) / "observations.jsonl"


def _load_observations(bot: str) -> list[dict]:
    path = _obs_log(bot)
    if not path.exists():
        return []
    obs = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obs.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return obs


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
            elif val.replace(".", "").isdigit():
                try:
                    result[key] = float(val) if "." in val else int(val)
                except ValueError:
                    result[key] = val
            else:
                result[key] = val
    return result


def _load_instincts(bot: str) -> dict[str, dict]:
    instincts = {}
    inst_dir = _instinct_dir(bot)
    for f in inst_dir.glob("instinct-*.yaml"):
        try:
            data = _parse_yaml(f.read_text(encoding="utf-8"))
            if data and "name" in data:
                instincts[data["name"]] = data
                instincts[data["name"]]["_path"] = str(f)
        except OSError:
            continue
    return instincts


def _write_instinct(bot: str, data: dict) -> Path:
    name = data["name"]
    safe_name = re.sub(r'[^a-z0-9_-]', '-', name.lower())[:60]
    path = _instinct_dir(bot) / f"instinct-{safe_name}.yaml"
    lines = ["---"]
    for key in ["name", "type", "confidence", "scope", "pattern", "action",
                "created", "last_seen", "hit_count"]:
        if key in data:
            lines.append(f"{key}: {data[key]}")
    if "evidence" in data:
        lines.append("evidence:")
        for e in data["evidence"][-5:]:
            lines.append(f"  - {e}")
    lines.append("---")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


# --- pattern detectors ---

def detect_repeated_flows(obs: list[dict]) -> list[dict]:
    """Detect tool sequences used 3+ times across sessions."""
    instincts = []
    if len(obs) < MIN_REPEAT_COUNT * 3:
        return instincts

    sessions: dict[int, list[str]] = defaultdict(list)
    for o in obs:
        sessions[o.get("session_epoch", 0)].append(o.get("tool", ""))

    seq_counts: Counter[tuple[str, ...]] = Counter()
    for tools in sessions.values():
        seen: set[tuple[str, ...]] = set()
        for i in range(len(tools) - 2):
            seq = tuple(tools[i:i+3])
            if seq not in seen:
                seen.add(seq)
                seq_counts[seq] += 1

    for seq, count in seq_counts.most_common(5):
        if count >= MIN_REPEAT_COUNT:
            confidence = min(MIN_CONFIDENCE + CONFIDENCE_BUMP * (count - MIN_REPEAT_COUNT),
                           MAX_CONFIDENCE)
            instincts.append({
                "name": f"repeated-flow-{'-'.join(seq).lower()[:40]}",
                "type": "repeated_flow",
                "confidence": round(confidence, 2),
                "scope": "project",
                "pattern": f"Tool sequence [{' -> '.join(seq)}] used {count} times",
                "action": f"When starting with {seq[0]}, follow with {seq[1]} then {seq[2]}",
                "evidence": [f"Seen {count} times across {len(sessions)} sessions"],
                "hit_count": count,
            })
    return instincts


def detect_error_resolutions(obs: list[dict]) -> list[dict]:
    """Detect error-then-fix patterns."""
    instincts = []
    error_patterns: Counter[str] = Counter()

    for i, o in enumerate(obs):
        output = o.get("output_summary", "")
        if not any(kw in output.lower() for kw in ["error", "failed", "denied", "exception"]):
            continue
        for j in range(i+1, min(i+4, len(obs))):
            next_out = obs[j].get("output_summary", "")
            if not any(kw in next_out.lower() for kw in ["error", "failed", "denied"]):
                tool = o.get("tool", "unknown")
                fix_tool = obs[j].get("tool", "unknown")
                error_patterns[f"{tool}-error-then-{fix_tool}"] += 1
                break

    for pattern_key, count in error_patterns.most_common(5):
        if count >= 2:
            parts = pattern_key.split("-error-then-")
            confidence = min(MIN_CONFIDENCE + CONFIDENCE_BUMP * count, MAX_CONFIDENCE)
            instincts.append({
                "name": f"error-resolve-{pattern_key[:40]}",
                "type": "error_resolve",
                "confidence": round(confidence, 2),
                "scope": "project",
                "pattern": f"Errors from {parts[0]} resolved by {parts[1]} ({count} times)",
                "action": f"When {parts[0]} fails, try {parts[1]} as resolution",
                "evidence": [f"Observed {count} error-resolution cycles"],
                "hit_count": count,
            })
    return instincts


def detect_tool_preferences(obs: list[dict]) -> list[dict]:
    """Detect dominant tool usage patterns."""
    instincts = []
    tool_counts = Counter(o.get("tool", "") for o in obs if o.get("tool"))
    total = sum(tool_counts.values())
    if total < MIN_OBSERVATIONS:
        return instincts

    for tool, count in tool_counts.most_common(3):
        ratio = count / total
        if ratio > 0.3:
            confidence = min(MIN_CONFIDENCE + ratio * 0.5, MAX_CONFIDENCE)
            instincts.append({
                "name": f"tool-preference-{tool.lower()[:40]}",
                "type": "tool_preference",
                "confidence": round(confidence, 2),
                "scope": "project",
                "pattern": f"{tool} used {count}/{total} times ({ratio:.0%})",
                "action": f"{tool} is the preferred tool for this bot's workload",
                "evidence": [f"{count}/{total} tool calls ({ratio:.0%})"],
                "hit_count": count,
            })
    return instincts


# --- main ---

def run_observer(bot: str, dry_run: bool = False) -> int:
    obs = _load_observations(bot)
    if not obs:
        print(f"No observations for {bot} yet.", file=sys.stderr)
        return 0

    print(f"Analyzing {len(obs)} observations for {bot}...", file=sys.stderr)
    if len(obs) < MIN_OBSERVATIONS:
        print(f"Need at least {MIN_OBSERVATIONS} observations. Skipping.", file=sys.stderr)
        return 0

    existing = _load_instincts(bot)
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    candidates = []
    candidates.extend(detect_repeated_flows(obs))
    candidates.extend(detect_error_resolutions(obs))
    candidates.extend(detect_tool_preferences(obs))

    created = updated = 0
    for candidate in candidates:
        name = candidate["name"]
        candidate["last_seen"] = now

        if name in existing:
            old = existing[name]
            old_conf = float(old.get("confidence", MIN_CONFIDENCE))
            candidate["confidence"] = round(min(old_conf + CONFIDENCE_BUMP, MAX_CONFIDENCE), 2)
            candidate["created"] = old.get("created", now)
            candidate["evidence"] = (old.get("evidence", []) + candidate.get("evidence", []))[-5:]
            if dry_run:
                print(f"  [UPDATE] {name}: confidence {old_conf} -> {candidate['confidence']}")
            else:
                _write_instinct(bot, candidate)
                updated += 1
        else:
            candidate["created"] = now
            if dry_run:
                print(f"  [CREATE] {name}: confidence {candidate['confidence']}")
            else:
                _write_instinct(bot, candidate)
                created += 1

    # Decay instincts not seen this run
    for name, data in existing.items():
        if name not in {c["name"] for c in candidates}:
            old_conf = float(data.get("confidence", MIN_CONFIDENCE))
            new_conf = max(old_conf - CONFIDENCE_DECAY, 0)
            if new_conf <= 0:
                path = data.get("_path")
                if path and not dry_run:
                    try:
                        Path(path).unlink()
                    except OSError:
                        pass
            elif abs(new_conf - old_conf) > 0.001:
                data["confidence"] = round(new_conf, 2)
                if not dry_run:
                    _write_instinct(bot, data)

    action = "Would create" if dry_run else "Created"
    print(f"{action} {created} new, updated {updated}, from {len(obs)} observations.", file=sys.stderr)
    return 0


def show_stats(bot: str) -> int:
    obs = _load_observations(bot)
    if not obs:
        print(f"No observations for {bot}.")
        return 0

    tool_counts = Counter(o.get("tool", "?") for o in obs)
    sessions = len(set(o.get("session_epoch", 0) for o in obs))

    print(f"Observations: {len(obs)}")
    print(f"Sessions: {sessions}")
    print(f"Time range: {obs[0].get('ts', '?')} to {obs[-1].get('ts', '?')}")
    print(f"\nTop tools:")
    for tool, count in tool_counts.most_common(10):
        print(f"  {tool}: {count}")

    instincts = _load_instincts(bot)
    if instincts:
        print(f"\nInstincts: {len(instincts)}")
        for name, data in sorted(instincts.items(), key=lambda x: -float(x[1].get("confidence", 0))):
            print(f"  [{data.get('type', '?')}] {name} (confidence: {data.get('confidence', '?')})")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: instinct-observer.py <bot-name> [--dry-run|--stats]", file=sys.stderr)
        return 1
    bot = sys.argv[1]
    if bot not in BOT_WORKDIRS:
        print(f"Unknown bot: {bot}", file=sys.stderr)
        return 1
    if "--stats" in sys.argv:
        return show_stats(bot)
    return run_observer(bot, dry_run="--dry-run" in sys.argv)


if __name__ == "__main__":
    sys.exit(main())

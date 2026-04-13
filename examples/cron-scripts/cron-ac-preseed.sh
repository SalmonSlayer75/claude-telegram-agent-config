#!/usr/bin/env bash
# cron-ac-preseed.sh — Pre-seed the ## Active Conversation section
# in a bot's state file before a `claude -p` one-shot cron run.
#
# Problem: If your bot uses a "bot-gate" hook that requires an Active
# Conversation section to be present before allowing tool calls, cron
# one-shots (claude -p) will fail because no AC section exists yet.
#
# Solution: Source this file in your cron scripts and call cron_ac_preseed
# before running claude -p. It writes a minimal AC section to the state
# file, and sets CLAUDE_CRON=1 so death-rattle.sh knows to suppress the
# "session ended" notification (since the session ending is expected).
#
# Usage:
#   source ~/bin/cron-ac-preseed.sh
#   cron_ac_preseed "$STATE_FILE" "Daily briefing"
#   claude -p "Generate the daily briefing" | curl ... # your cron task
#   cron_ac_complete "$STATE_FILE"                      # mark done
#
# Both functions are best-effort — failures are logged but never fatal.
# Uses flock + atomic rename to avoid races with the interactive bot.

cron_ac_preseed() {
    local state_file="$1"
    local topic="$2"

    # Mark this as a cron one-shot so death-rattle.sh suppresses
    # the "session ended" notification (the session ending is expected).
    export CLAUDE_CRON=1

    if [ -z "$state_file" ] || [ -z "$topic" ]; then
        echo "cron-ac-preseed: usage: cron_ac_preseed <state-file> <topic>" >&2
        return 0  # best-effort
    fi

    if [ ! -f "$state_file" ]; then
        echo "cron-ac-preseed: state file not found: $state_file" >&2
        return 0  # best-effort
    fi

    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")

    python3 - "$state_file" "$topic" "$ts" << 'PYEOF'
import fcntl, os, re, sys, tempfile

state_file = sys.argv[1]
topic = sys.argv[2]
ts = sys.argv[3]

ac_block = f"""## Active Conversation
**Topic:** {topic}
**Status:** in-progress
**Started:** {ts}
**Last checkpoint:** {ts}
**Step:** 1 of 1
**Steps completed:**
- [ ] Step 1: {topic} [safety: safe]
**Resumption context:** Cron one-shot task in progress.
**Auto-resume:** no
**Resume-count:** 0"""

lock_path = state_file + ".lock"

try:
    lock_fd = open(lock_path, "w")
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    with open(state_file, "r", encoding="utf-8") as f:
        text = f.read()

    text = text.replace("\r\n", "\n").replace("\r", "\n")

    # Strip fenced code blocks before finding section boundaries
    stripped = re.sub(
        r"^```.*?^```",
        lambda m: "\n" * (m.group(0).count("\n")),
        text,
        flags=re.MULTILINE | re.DOTALL,
    )

    target_re = re.compile(
        r"^##[ \t]+Active Conversation[ \t]*$",
        re.MULTILINE,
    )
    matches = list(target_re.finditer(stripped))

    if len(matches) == 0:
        # No AC section — append after first line
        lines = text.split("\n", 1)
        if len(lines) == 2:
            text = lines[0] + "\n\n" + ac_block + "\n\n" + lines[1]
        else:
            text = text + "\n\n" + ac_block + "\n"
    else:
        start = matches[0].start()
        header_end = matches[0].end()
        next_h2 = re.search(r"(?m)^##[ \t]+\S", stripped[header_end:])
        if next_h2:
            end = header_end + next_h2.start()
        else:
            end = len(text)
        text = text[:start] + ac_block + "\n" + text[end:]

    # Atomic write: temp file + rename
    dir_name = os.path.dirname(state_file)
    fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp_path, state_file)
    except:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()

except Exception as e:
    print(f"cron-ac-preseed: preseed failed: {e}", file=sys.stderr)
PYEOF
    return 0  # always best-effort
}

cron_ac_complete() {
    local state_file="$1"

    if [ -z "$state_file" ] || [ ! -f "$state_file" ]; then
        return 0  # best-effort
    fi

    python3 - "$state_file" << 'PYEOF'
import fcntl, os, re, sys, tempfile

state_file = sys.argv[1]
lock_path = state_file + ".lock"

try:
    lock_fd = open(lock_path, "w")
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    with open(state_file, "r", encoding="utf-8") as f:
        text = f.read()

    text = text.replace("\r\n", "\n").replace("\r", "\n")

    stripped = re.sub(
        r"^```.*?^```",
        lambda m: "\n" * (m.group(0).count("\n")),
        text,
        flags=re.MULTILINE | re.DOTALL,
    )
    target_re = re.compile(
        r"^##[ \t]+Active Conversation[ \t]*$",
        re.MULTILINE,
    )
    matches = list(target_re.finditer(stripped))
    if not matches:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()
        sys.exit(0)

    start = matches[0].start()
    header_end = matches[0].end()
    next_h2 = re.search(r"(?m)^##[ \t]+\S", stripped[header_end:])
    end = header_end + next_h2.start() if next_h2 else len(text)

    ac_section = text[start:end]
    ac_section = re.sub(
        r"(\*\*Status:\*\*) in-progress",
        r"\1 completed",
        ac_section,
        count=1,
    )
    ac_section = re.sub(
        r"- \[ \] Step 1:",
        r"- [x] Step 1:",
        ac_section,
        count=1,
    )
    text = text[:start] + ac_section + text[end:]

    dir_name = os.path.dirname(state_file)
    fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp_path, state_file)
    except:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()

except Exception as e:
    print(f"cron-ac-preseed: complete failed: {e}", file=sys.stderr)
PYEOF
    return 0  # always best-effort
}

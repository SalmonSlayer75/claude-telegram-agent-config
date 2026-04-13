#!/usr/bin/env bash

# Full PATH — must include claude's location and bun's location.
# Adjust these paths to match where claude and bun are installed on this system.
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"

# Be explicit about HOME — systemd doesn't always set it
export HOME="/home/yourusername"    # <-- CHANGE THIS

# Points to the state directory with .env (bot token) and access.json (allowlist)
export TELEGRAM_STATE_DIR="$HOME/.claude/channels/telegram-work"

# Working directory = bot's identity (CLAUDE.md, state file, settings)
cd ~/AgentWorkspace                 # <-- CHANGE THIS

# Kill any zombie Telegram pollers left from a previous session.
# This prevents "409 Conflict" errors where two pollers fight over messages.
# Use the first few digits of your bot token as a unique identifier.
BOT_TOKEN_PREFIX="1234567890"       # <-- First digits of your bot token
pkill -f "telegram.*${BOT_TOKEN_PREFIX}" 2>/dev/null || true
sleep 1

# Touch heartbeat so watchdog knows we're alive from the start.
# Without this, a freshly started bot has no heartbeat file and the
# watchdog's stale-connection check might fire before the first tool call.
touch /tmp/work-heartbeat           # <-- Match BOT_HEARTBEAT name in watchdog

# --add-dir grants access to additional directories without changing working dir
# Add as many as needed for your use case
exec claude --channels plugin:telegram@claude-plugins-official \
  --add-dir ~/other-repo \
  --add-dir ~/shared-docs

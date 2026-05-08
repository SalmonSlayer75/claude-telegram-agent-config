# GPU Queue — Local LLM Dispatch Daemon

A journal-based queue daemon that manages dispatch to local LLM backends (llama.cpp servers). Handles priority scheduling, on-demand model lifecycle, and crash recovery.

## The Problem

Multiple cron jobs, hooks, and bots need local inference. Without coordination:
- Concurrent requests to the same GPU cause OOM or slow everything down
- On-demand models stay loaded forever, wasting VRAM
- Crashed requests are silently lost

## The Solution

A single-instance daemon reads an append-only JSONL journal, dispatches requests to backends by priority, and manages model lifecycle (start on first request, unload after idle timeout).

### Architecture

```
Clients (cron, hooks, bots)
    |  enqueue via gpu-queue-client.sh
    v
[queue.jsonl]  <-- append-only journal
    |
gpu-queue-daemon.py (single instance via flock)
    |  dispatch by priority
    |-- :8080  model-a  (always-on, resident)
    |-- :8081  model-b  (on-demand, LRU unload after 15 min idle)
    +-- :8082  embed    (always-on, resident)
```

### Priority System

| Priority | Soft Timeout | Hard Deadline | Use Case |
|----------|-------------|---------------|----------|
| interactive | 10s | 30s | Live user-facing requests |
| inbox-digest | 60s | 120s | Email/message classification |
| evidence-pack | 600s | 900s | Research compilation |
| eod-digest | 1800s | 3600s | End-of-day summaries |
| index-rebuild | 7200s | 14400s | Background reindexing |

Every 5th dispatch picks the oldest-enqueued request regardless of priority (fairness).

### On-Demand Lifecycle

For expensive models that shouldn't stay loaded:
1. First request: `systemctl --user start model-server.service`
2. Wait for health check to pass
3. Dispatch request
4. After 15 min idle: `systemctl --user stop model-server.service`

### Crash Recovery

On startup, the daemon replays the journal:
- Requests dispatched under a previous lease_epoch without completion: `daemon-restart`
- Requests past their hard deadline: `queue-stale`
- Requests past soft timeout without dispatch: `queue-timeout`

## Setup

1. Start your llama.cpp servers (or configure systemd services for on-demand)
2. Initialize: `mkdir -p ~/state/gpu-queue && echo 1 > ~/state/gpu-queue/lease_epoch`
3. Run daemon: `python3 gpu-queue-daemon.py`
4. Enqueue: `gpu-queue-client.sh enqueue <id> <priority> <backend> '<payload>'`

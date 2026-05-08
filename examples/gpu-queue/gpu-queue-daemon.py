#!/usr/bin/env python3
"""
GPU queue daemon — simplified reference implementation.

Single-instance daemon that manages dispatch to local LLM backends.
Features: priority scheduling, journal-based state, on-demand model
lifecycle, crash recovery via lease_epoch.

This is a simplified version for reference. A production deployment
would add: admission RPC server, dedupe LRU, mid-file corruption
quarantine, concurrent dispatch, and journal compaction.
"""
from __future__ import annotations

import calendar
import fcntl
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

# --- Configuration (CUSTOMIZE these) ---

STATE_DIR = Path.home() / "state" / "gpu-queue"
JOURNAL = STATE_DIR / "queue.jsonl"
LEASE_EPOCH_FILE = STATE_DIR / "lease_epoch"
PID_FILE = STATE_DIR / "daemon.pid"
HEARTBEAT_FILE = STATE_DIR / "heartbeat"
LOG_FILE = Path.home() / "logs" / "gpu-queue-daemon.log"

BACKENDS = {
    "model-a": {"host": "127.0.0.1", "port": 8080, "path": "/completion", "kind": "llama"},
    "embed":   {"host": "127.0.0.1", "port": 8082, "path": "/embedding", "kind": "embed"},
    "model-b": {"host": "127.0.0.1", "port": 8081, "path": "/completion", "kind": "llama"},
}

PRIORITY_ORDER = {
    "interactive":    0,
    "inbox-digest":   1,
    "evidence-pack":  2,
    "eod-digest":     3,
    "index-rebuild":  4,
}

SOFT_TIMEOUT_SEC = {
    "interactive": 10, "inbox-digest": 60, "evidence-pack": 600,
    "eod-digest": 1800, "index-rebuild": 7200,
}
HARD_DEADLINE_SEC = {
    "interactive": 30, "inbox-digest": 120, "evidence-pack": 900,
    "eod-digest": 3600, "index-rebuild": 14400,
}

POLL_INTERVAL_SEC = 0.5
FAIRNESS_EVERY = 5

# On-demand model-b lifecycle
ONDEMAND_SERVICE = "llama-server-model-b.service"    # <-- CHANGE THIS
ONDEMAND_HEALTH_URL = "http://127.0.0.1:8081/health"
ONDEMAND_WARMUP_SEC = 45
ONDEMAND_UNLOAD_SEC = 15 * 60  # 15 min idle


# --- Logging / Time ---

def log(msg: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(LOG_FILE, "a") as f:
        f.write(f"{ts} pid={os.getpid()} {msg}\n")


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def parse_iso(ts: str) -> float:
    try:
        return float(calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")))
    except (ValueError, TypeError):
        return 0.0


# --- Single-instance + lease_epoch ---

def acquire_pid_lock() -> int:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fd = os.open(PID_FILE, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("another gpu-queue-daemon is running; aborting")
    os.ftruncate(fd, 0)
    os.write(fd, f"{os.getpid()}\n".encode())
    os.fsync(fd)
    return fd


def bump_lease_epoch() -> int:
    if not LEASE_EPOCH_FILE.exists():
        raise SystemExit(
            f"lease_epoch missing at {LEASE_EPOCH_FILE}; "
            "bootstrap with `echo 1 > lease_epoch`"
        )
    current = int(LEASE_EPOCH_FILE.read_text().strip())
    if current <= 0:
        raise SystemExit(f"lease_epoch must be > 0; got {current}")
    new = current + 1
    tmp = LEASE_EPOCH_FILE.with_suffix(".tmp")
    tmp.write_text(f"{new}\n")
    os.replace(tmp, LEASE_EPOCH_FILE)
    return new


def write_heartbeat(pid: int, lease_epoch: int, loop_iter: int) -> None:
    payload = json.dumps({
        "ts": now_iso(), "pid": pid,
        "lease_epoch": lease_epoch, "loop_iter": loop_iter,
    }, separators=(",", ":")) + "\n"
    tmp = HEARTBEAT_FILE.with_suffix(".tmp")
    tmp.write_text(payload)
    os.replace(tmp, HEARTBEAT_FILE)


# --- Journal I/O ---

def journal_append(record: dict) -> None:
    line = json.dumps(record, separators=(",", ":")) + "\n"
    fd = os.open(JOURNAL, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, line.encode())
        os.fsync(fd)
    finally:
        os.close(fd)


def journal_read() -> list[dict]:
    if not JOURNAL.exists():
        return []
    records = []
    with open(JOURNAL, "r") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    log(f"skipping malformed journal line: {line[:80]}")
    return records


# --- State ---

class RequestState:
    __slots__ = ("id", "priority", "backend_hint", "enqueued_at", "payload",
                 "dispatched_at", "dispatch_lease", "completed")

    def __init__(self, rec: dict):
        self.id = rec["id"]
        self.priority = rec.get("priority", "eod-digest")
        self.backend_hint = rec.get("backend_hint", "model-a")
        self.enqueued_at = rec.get("enqueued_at", now_iso())
        self.payload = rec.get("payload", {})
        self.dispatched_at: Optional[str] = None
        self.dispatch_lease: Optional[int] = None
        self.completed = False


def replay_and_recover(records: list[dict], lease: int) -> list[RequestState]:
    by_id: dict[str, RequestState] = {}
    for r in records:
        rid, k = r.get("id"), r.get("kind")
        if not rid or not k:
            continue
        if k == "enqueue" and rid not in by_id:
            by_id[rid] = RequestState(r)
        elif k == "dispatch" and rid in by_id:
            by_id[rid].dispatched_at = r.get("dispatched_at")
            by_id[rid].dispatch_lease = r.get("lease_epoch")
        elif k == "complete" and rid in by_id:
            by_id[rid].completed = True

    pending = []
    now_epoch = time.time()
    for rid, st in by_id.items():
        if st.completed:
            continue
        enq = parse_iso(st.enqueued_at)
        hard = HARD_DEADLINE_SEC.get(st.priority, 3600)
        soft = SOFT_TIMEOUT_SEC.get(st.priority, 1800)
        if enq <= 0 or (now_epoch - enq) > hard:
            journal_append({"kind": "complete", "id": rid,
                            "completed_at": now_iso(), "outcome": "queue-stale"})
            continue
        if st.dispatched_at and st.dispatch_lease and st.dispatch_lease < lease:
            journal_append({"kind": "complete", "id": rid,
                            "completed_at": now_iso(), "outcome": "daemon-restart"})
            continue
        if (now_epoch - enq) > soft and not st.dispatched_at:
            journal_append({"kind": "complete", "id": rid,
                            "completed_at": now_iso(), "outcome": "queue-timeout"})
            continue
        pending.append(st)
    return pending


# --- Selector with fairness ---

class PendingQueue:
    def __init__(self, initial: list[RequestState]):
        self._by_id = {s.id: s for s in initial}
        self._counter: dict[str, int] = {b: 0 for b in BACKENDS}

    def add(self, st: RequestState) -> None:
        self._by_id.setdefault(st.id, st)

    def remove(self, rid: str) -> None:
        self._by_id.pop(rid, None)

    def any_pending(self) -> bool:
        return bool(self._by_id)

    def select(self, backend: str) -> Optional[RequestState]:
        pool = [s for s in self._by_id.values() if s.backend_hint == backend]
        if not pool:
            return None
        c = self._counter[backend]
        if c % FAIRNESS_EVERY == (FAIRNESS_EVERY - 1):
            pool.sort(key=lambda s: s.enqueued_at)
        else:
            pool.sort(key=lambda s: (PRIORITY_ORDER.get(s.priority, 99), s.enqueued_at))
        return pool[0]

    def advance(self, backend: str) -> None:
        self._counter[backend] += 1


# --- On-demand lifecycle ---

class OnDemandLifecycle:
    def __init__(self):
        self._lock = threading.Lock()
        self.status = "stopped"
        self.active = 0
        self._timer: Optional[threading.Timer] = None

    def acquire(self) -> tuple[bool, str]:
        with self._lock:
            if self._timer:
                self._timer.cancel()
                self._timer = None
            self.active += 1
            if self.status == "ready":
                return True, ""
            if self.status == "stopped":
                self.status = "warming"
            else:
                return self._wait_ready()
        try:
            subprocess.run(["systemctl", "--user", "start", ONDEMAND_SERVICE],
                           check=True, timeout=10,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as e:
            with self._lock:
                self.active -= 1
                self.status = "stopped"
            return False, f"start-failed:{e}"
        return self._wait_ready()

    def _wait_ready(self) -> tuple[bool, str]:
        deadline = time.time() + ONDEMAND_WARMUP_SEC
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(ONDEMAND_HEALTH_URL, timeout=2) as r:
                    if 200 <= r.status < 300:
                        with self._lock:
                            self.status = "ready"
                        return True, ""
            except Exception:
                pass
            time.sleep(1)
        with self._lock:
            self.active -= 1
            self.status = "stopped"
        return False, "unavailable"

    def release(self) -> None:
        with self._lock:
            self.active = max(0, self.active - 1)
            if self.active == 0 and self.status == "ready":
                t = threading.Timer(ONDEMAND_UNLOAD_SEC, self._unload)
                t.daemon = True
                self._timer = t
                t.start()

    def _unload(self) -> None:
        with self._lock:
            if self.active > 0 or self.status != "ready":
                return
            self.status = "stopped"
        subprocess.run(["systemctl", "--user", "stop", ONDEMAND_SERVICE],
                       check=False, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log("on-demand model unloaded (idle timeout)")


# --- HTTP dispatch ---

def dispatch_http(backend: str, payload: dict, timeout: float) -> dict:
    cfg = BACKENDS.get(backend)
    if not cfg:
        return {"ok": False, "error": f"unknown-backend:{backend}"}
    url = f"http://{cfg['host']}:{cfg['port']}{cfg['path']}"
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data,
                                headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return {"ok": True, "body": resp.read().decode()}
    except urllib.error.URLError as e:
        return {"ok": False, "error": f"urlerror:{e.reason}"}
    except socket.timeout:
        return {"ok": False, "error": "http-timeout"}
    except Exception as e:
        return {"ok": False, "error": f"{type(e).__name__}:{e}"}


# --- Main loop ---

def main() -> int:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    _pid_fd = acquire_pid_lock()
    lease = bump_lease_epoch()
    log(f"daemon start lease_epoch={lease}")

    records = journal_read()
    initial = replay_and_recover(records, lease)
    pq = PendingQueue(initial)
    seen = {s.id for s in initial}
    for r in records:
        if r.get("kind") == "complete" and r.get("id"):
            seen.add(r["id"])
    log(f"replay: {len(initial)} pending")

    ondemand = OnDemandLifecycle()
    running = True

    def handle_sig(signum, _):
        nonlocal running
        log(f"signal {signum}; shutting down")
        running = False

    signal.signal(signal.SIGTERM, handle_sig)
    signal.signal(signal.SIGINT, handle_sig)

    last_hb = 0.0
    loop_iter = 0

    while running:
        loop_iter += 1
        if time.monotonic() - last_hb >= 5.0:
            try:
                write_heartbeat(os.getpid(), lease, loop_iter)
                last_hb = time.monotonic()
            except OSError:
                pass

        fresh = journal_read()
        completed = {r["id"] for r in fresh if r.get("kind") == "complete" and r.get("id")}
        for r in fresh:
            if r.get("kind") != "enqueue":
                continue
            rid = r.get("id")
            if not rid or rid in seen or rid in completed:
                continue
            seen.add(rid)
            pq.add(RequestState(r))

        if not pq.any_pending():
            time.sleep(POLL_INTERVAL_SEC)
            continue

        dispatched_any = False
        for backend in BACKENDS:
            if not running:
                break
            nxt = pq.select(backend)
            if not nxt:
                continue

            journal_append({"kind": "dispatch", "id": nxt.id,
                            "dispatched_at": now_iso(), "lease_epoch": lease,
                            "backend": backend})

            timeout = HARD_DEADLINE_SEC.get(nxt.priority, 3600)

            if backend == "model-b":
                ok, err = ondemand.acquire()
                if not ok:
                    outcome = {"ok": False, "error": err}
                else:
                    try:
                        outcome = dispatch_http(backend, nxt.payload, timeout)
                    finally:
                        ondemand.release()
            else:
                outcome = dispatch_http(backend, nxt.payload, timeout)

            kind = "ok" if outcome.get("ok") else "error"
            if outcome.get("error") == "http-timeout":
                kind = "timeout"

            journal_append({"kind": "complete", "id": nxt.id,
                            "completed_at": now_iso(), "outcome": kind})
            pq.remove(nxt.id)
            pq.advance(backend)
            log(f"dispatched id={nxt.id} backend={backend} outcome={kind}")
            dispatched_any = True

        if not dispatched_any:
            time.sleep(POLL_INTERVAL_SEC)

    log("daemon exit")
    return 0


if __name__ == "__main__":
    sys.exit(main())

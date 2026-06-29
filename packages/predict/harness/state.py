"""File-locked slot/port registry for parallel-safe localnet allocation.

Each run reserves a slot -> port offset -> (rpc_port, faucet_port). The whole
read-modify-write is serialized with an exclusive flock so concurrent harness
processes never pick the same ports. Slots whose owning process is gone are
reclaimed on the next reservation or via `cleanup --stale`.
"""

from __future__ import annotations

import fcntl
import json
import os
import time
from contextlib import contextmanager
from typing import Any

from . import config


def _ensure_dirs() -> None:
    config.LOCALNETS_DIR.mkdir(parents=True, exist_ok=True)


@contextmanager
def _locked():
    _ensure_dirs()
    fh = open(config.LOCK_FILE, "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fh, fcntl.LOCK_UN)
        fh.close()


def _read() -> dict[str, Any]:
    if not config.STATE_FILE.exists():
        return {"slots": {}}
    try:
        return json.loads(config.STATE_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return {"slots": {}}


def _write(state: dict[str, Any]) -> None:
    tmp = config.STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(config.STATE_FILE)


def _alive(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def reserve(run_id: str) -> dict[str, Any]:
    """Reserve the lowest free slot; reclaim dead slots while we hold the lock."""
    with _locked():
        state = _read()
        slots = {k: v for k, v in state.get("slots", {}).items() if _alive(v.get("pid"))}
        used = {v["offset"] for v in slots.values()}
        for i in range(1, config.SLOT_COUNT + 1):
            offset = i * 100
            if offset not in used:
                slot = {
                    "run_id": run_id,
                    "offset": offset,
                    "rpc_port": config.RPC_BASE + offset,
                    "faucet_port": config.FAUCET_BASE + offset,
                    "pid": os.getpid(),
                    "status": "reserved",
                    "started_at": time.time(),
                }
                slots[run_id] = slot
                state["slots"] = slots
                _write(state)
                return slot
        raise RuntimeError(f"no free localnet slot (all {config.SLOT_COUNT} in use)")


def update(run_id: str, **fields: Any) -> None:
    with _locked():
        state = _read()
        if run_id in state.get("slots", {}):
            state["slots"][run_id].update(fields)
            _write(state)


def release(run_id: str) -> None:
    with _locked():
        state = _read()
        if state.get("slots", {}).pop(run_id, None) is not None:
            _write(state)


def reap_stale() -> list[str]:
    """Drop slots whose owning process is gone. Returns the reclaimed run_ids."""
    with _locked():
        state = _read()
        dead = [k for k, v in state.get("slots", {}).items() if not _alive(v.get("pid"))]
        for k in dead:
            del state["slots"][k]
        if dead:
            _write(state)
        return dead


def snapshot() -> dict[str, Any]:
    with _locked():
        return _read()

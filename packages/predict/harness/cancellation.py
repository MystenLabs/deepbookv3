"""Cooperative cancellation for setup work and its child process groups."""

from __future__ import annotations

import os
import signal
import subprocess
import threading
import time
from collections.abc import Sequence
from pathlib import Path


class RunCancelled(RuntimeError):
    pass


def check(cancel_event: threading.Event | None) -> None:
    if cancel_event is not None and cancel_event.is_set():
        raise RunCancelled("run cancelled")


def _group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
        return True
    except ProcessLookupError:
        return False


def _stop_group(process: subprocess.Popen, process_group: int) -> None:
    try:
        os.killpg(process_group, signal.SIGTERM)
    except ProcessLookupError:
        process.wait()
        return

    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        # Reap the leader as soon as it exits. Otherwise its zombie keeps an
        # otherwise-empty process group visible for the entire grace period.
        process.poll()
        if not _group_exists(process_group):
            return
        time.sleep(0.05)

    if _group_exists(process_group):
        try:
            os.killpg(process_group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait()


def run(
    command: Sequence[str],
    *,
    cancel_event: threading.Event | None = None,
    check_result: bool = False,
    capture_output: bool = False,
    text: bool = False,
    cwd: str | Path | None = None,
    timeout: float | None = None,
) -> subprocess.CompletedProcess:
    """Run a command, terminating its whole process group when cancellation fires."""
    if cancel_event is None:
        return subprocess.run(
            command,
            check=check_result,
            capture_output=capture_output,
            text=text,
            cwd=str(cwd) if cwd else None,
            timeout=timeout,
        )

    check(cancel_event)
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE if capture_output else None,
        stderr=subprocess.PIPE if capture_output else None,
        text=text,
        cwd=str(cwd) if cwd else None,
        start_new_session=True,
    )
    # start_new_session makes the leader's PID the process-group ID. Preserve it
    # now: the leader may exit while a descendant keeps captured pipes open.
    process_group = process.pid
    started = time.monotonic()
    while True:
        if cancel_event.is_set():
            _stop_group(process, process_group)
            process.communicate()
            raise RunCancelled("run cancelled")
        if timeout is not None and time.monotonic() - started >= timeout:
            _stop_group(process, process_group)
            stdout, stderr = process.communicate()
            raise subprocess.TimeoutExpired(
                command,
                timeout,
                output=stdout,
                stderr=stderr,
            )
        try:
            stdout, stderr = process.communicate(timeout=0.1)
            break
        except subprocess.TimeoutExpired:
            continue

    completed = subprocess.CompletedProcess(
        command,
        process.returncode,
        stdout,
        stderr,
    )
    if check_result:
        completed.check_returncode()
    return completed

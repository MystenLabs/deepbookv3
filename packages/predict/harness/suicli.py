"""Thin wrapper around the `sui` CLI."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any, Sequence

from . import config


class SuiError(RuntimeError):
    pass


def run(
    args: Sequence[str],
    *,
    check: bool = True,
    cwd: Path | None = None,
    timeout: float | None = None,
) -> subprocess.CompletedProcess:
    """Run `sui <args>` capturing text stdout/stderr."""
    cmd = [config.sui_binary()] + [str(a) for a in args]
    cp = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        cwd=str(cwd) if cwd else None,
        timeout=timeout,
    )
    if check and cp.returncode != 0:
        raise SuiError(
            f"`sui {' '.join(str(a) for a in args[:3])} ...` failed "
            f"(exit {cp.returncode}):\n{cp.stderr.strip()[:2000]}"
        )
    return cp


def client(client_config: Path, args: Sequence[str], **kwargs) -> subprocess.CompletedProcess:
    return run(["client", "--client.config", str(client_config), *args], **kwargs)


def client_text(client_config: Path, args: Sequence[str]) -> str:
    return client(client_config, args).stdout.strip()


def parse_json_lenient(text: str) -> Any:
    """Parse JSON, tolerating leading/trailing non-JSON noise."""
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    start = text.find("{")
    arr = text.find("[")
    if arr != -1 and (start == -1 or arr < start):
        start = arr
    end = max(text.rfind("}"), text.rfind("]"))
    if start != -1 and end > start:
        return json.loads(text[start : end + 1])
    raise SuiError(f"could not parse sui JSON output:\n{text[:1000]}")

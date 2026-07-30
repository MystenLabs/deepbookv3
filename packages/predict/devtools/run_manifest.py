"""Reproducible run manifests shared by the localnet engines."""

from __future__ import annotations

import hashlib
import json
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "predict_run_manifest_v1"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_revision(repo: Path) -> dict[str, Any]:
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    status = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return {"commit": commit, "dirty": bool(status)}


def timestamp() -> str:
    return datetime.now(UTC).isoformat()


def write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    """Atomically replace a manifest so an interrupted run stays parseable."""
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_suffix(path.suffix + ".tmp")
    pending.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    pending.replace(path)


def new_manifest(
    *,
    engine: str,
    run_id: str,
    repo: Path,
    source: Path,
    scenario: Path,
    config: Path,
    seed: int,
    command: list[str],
    max_rows: int | None,
    deployment: dict[str, Any],
) -> dict[str, Any]:
    config_value = json.loads(config.read_text())
    return {
        "schema_version": SCHEMA_VERSION,
        "engine": engine,
        "run_id": run_id,
        "status": "running",
        "started_at": timestamp(),
        "completed_at": None,
        "error": None,
        "source_revision": source_revision(repo),
        "inputs": {
            "source": {
                "path": str(source.resolve()),
                "sha256": sha256_file(source),
            },
            "scenario": {
                "path": str(scenario.resolve()),
                "sha256": sha256_file(scenario),
            },
            "config": {
                "path": str(config.resolve()),
                "sha256": sha256_file(config),
                "value": config_value,
            },
            "seed": seed,
            "max_rows": max_rows,
        },
        "localnet": {
            "chain_id": deployment["meta"]["chain_id"],
            "rpc_port": deployment["meta"]["rpc_port"],
            "package_ids": deployment["packages"],
        },
        "command": command,
    }


def complete_manifest(
    manifest: dict[str, Any],
    *,
    error: BaseException | None = None,
) -> dict[str, Any]:
    manifest["status"] = "failed" if error is not None else "complete"
    manifest["completed_at"] = timestamp()
    manifest["error"] = (
        f"{type(error).__name__}: {error}" if error is not None else None
    )
    return manifest

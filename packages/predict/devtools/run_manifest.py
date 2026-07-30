"""Reproducible run manifests shared by the localnet engines."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "predict_run_manifest_v2"
TERMINAL_STATUSES = frozenset({"complete", "failed", "interrupted"})
_MANIFEST_FIELDS = frozenset(
    {
        "schema_version",
        "engine",
        "run_id",
        "status",
        "started_at",
        "completed_at",
        "termination",
        "source_revision",
        "arguments",
        "inputs",
        "localnets",
        "artifacts",
        "outcome",
    }
)
_LOCALNET_FIELDS = frozenset(
    {
        "role",
        "run_id",
        "instance_dir",
        "setup_duration_s",
        "deployment",
        "actors",
    }
)
_DEPLOYMENT_FIELDS = frozenset(
    {"chain_id", "rpc_port", "package_ids", "object_ids"}
)
_SOURCE_REVISION_FIELDS = frozenset({"commit", "dirty"})


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
    validate_manifest(manifest)
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_suffix(path.suffix + ".tmp")
    pending.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    pending.replace(path)


def new_manifest(
    *,
    engine: str,
    run_id: str,
    repo: Path,
    arguments: dict[str, Any],
) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "engine": engine,
        "run_id": run_id,
        "status": "running",
        "started_at": timestamp(),
        "completed_at": None,
        "termination": None,
        "source_revision": source_revision(repo),
        "arguments": arguments,
        "inputs": {},
        "localnets": [],
        "artifacts": {},
        "outcome": None,
    }


def file_input(path: Path, *, include_value: bool = False) -> dict[str, Any]:
    record: dict[str, Any] = {
        "path": str(path.resolve()),
        "sha256": sha256_file(path),
    }
    if include_value:
        record["value"] = json.loads(path.read_text())
    return record


def relative_path(path: Path, manifest_path: Path) -> str:
    return os.path.relpath(path.resolve(), manifest_path.parent.resolve())


def localnet_record(
    *,
    role: str,
    run_id: str,
    instance_dir: Path,
    manifest_path: Path,
    deployment: dict[str, Any],
    setup_duration_s: float | None,
    actors: list[str],
) -> dict[str, Any]:
    return {
        "role": role,
        "run_id": run_id,
        "instance_dir": relative_path(instance_dir, manifest_path),
        "setup_duration_s": setup_duration_s,
        "deployment": {
            "chain_id": deployment["meta"]["chain_id"],
            "rpc_port": deployment["meta"]["rpc_port"],
            "package_ids": deployment["packages"],
            "object_ids": deployment.get("objects", {}),
        },
        "actors": actors,
    }


def complete_manifest(
    manifest: dict[str, Any],
    *,
    status: str,
    reason: str,
    exit_code: int,
    error: BaseException | str | None = None,
) -> dict[str, Any]:
    if status not in TERMINAL_STATUSES:
        raise ValueError(f"invalid terminal manifest status: {status}")
    manifest["status"] = status
    manifest["completed_at"] = timestamp()
    if isinstance(error, BaseException):
        rendered_error = f"{type(error).__name__}: {error}"
    else:
        rendered_error = error
    manifest["termination"] = {
        "reason": reason,
        "error": rendered_error,
        "exit_code": exit_code,
    }
    return manifest


def _require_exact_fields(
    value: Any,
    fields: frozenset[str],
    label: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an object")
    missing = sorted(fields - set(value))
    unknown = sorted(set(value) - fields)
    if missing or unknown:
        details = []
        if missing:
            details.append(f"missing={','.join(missing)}")
        if unknown:
            details.append(f"unknown={','.join(unknown)}")
        raise ValueError(f"{label} schema mismatch; {'; '.join(details)}")
    return value


def validate_manifest(
    value: Any,
    *,
    require_terminal: bool = False,
) -> dict[str, Any]:
    manifest = _require_exact_fields(value, _MANIFEST_FIELDS, "run manifest")
    if manifest["schema_version"] != SCHEMA_VERSION:
        raise ValueError(
            f"unsupported run manifest schema_version: {manifest['schema_version']!r}"
        )
    if not isinstance(manifest["engine"], str) or not manifest["engine"]:
        raise ValueError("run manifest engine must be a non-empty string")
    if not isinstance(manifest["run_id"], str) or not manifest["run_id"]:
        raise ValueError("run manifest run_id must be a non-empty string")
    if not isinstance(manifest["status"], str) or manifest["status"] not in {
        "running",
        *TERMINAL_STATUSES,
    }:
        raise ValueError(f"unsupported run manifest status: {manifest['status']!r}")
    if require_terminal and manifest["status"] not in TERMINAL_STATUSES:
        raise ValueError(
            f"run manifest is incomplete with status {manifest['status']!r}"
        )
    revision = _require_exact_fields(
        manifest["source_revision"],
        _SOURCE_REVISION_FIELDS,
        "run manifest source_revision",
    )
    if not isinstance(revision["commit"], str) or not isinstance(
        revision["dirty"],
        bool,
    ):
        raise ValueError(
            "run manifest source_revision requires string commit and boolean dirty"
        )
    if not isinstance(manifest["started_at"], str):
        raise ValueError("run manifest started_at must be a string")
    for field in ("arguments", "inputs", "artifacts"):
        if not isinstance(manifest[field], dict):
            raise ValueError(f"run manifest {field} must be an object")
    if not all(
        isinstance(path, str) and path
        for path in manifest["artifacts"].values()
    ):
        raise ValueError("run manifest artifacts must map names to non-empty paths")
    if not isinstance(manifest["localnets"], list):
        raise ValueError("run manifest localnets must be an array")
    for index, localnet in enumerate(manifest["localnets"]):
        record = _require_exact_fields(
            localnet,
            _LOCALNET_FIELDS,
            f"run manifest localnets[{index}]",
        )
        if not isinstance(record["role"], str) or not record["role"]:
            raise ValueError(
                f"run manifest localnets[{index}].role must be a non-empty string"
            )
        if not isinstance(record["run_id"], str) or not record["run_id"]:
            raise ValueError(
                f"run manifest localnets[{index}].run_id must be a non-empty string"
            )
        if not isinstance(record["instance_dir"], str) or not record["instance_dir"]:
            raise ValueError(
                f"run manifest localnets[{index}].instance_dir must be a non-empty string"
            )
        if record["setup_duration_s"] is not None and not isinstance(
            record["setup_duration_s"],
            (int, float),
        ):
            raise ValueError(
                f"run manifest localnets[{index}].setup_duration_s must be numeric or null"
            )
        deployment = _require_exact_fields(
            record["deployment"],
            _DEPLOYMENT_FIELDS,
            f"run manifest localnets[{index}].deployment",
        )
        if not isinstance(deployment["package_ids"], dict) or not isinstance(
            deployment["object_ids"],
            dict,
        ):
            raise ValueError(
                f"run manifest localnets[{index}].deployment ids must be objects"
            )
        if not isinstance(deployment["chain_id"], str) or not isinstance(
            deployment["rpc_port"],
            int,
        ):
            raise ValueError(
                f"run manifest localnets[{index}].deployment requires string chain_id "
                "and integer rpc_port"
            )
        if not isinstance(record["actors"], list) or not all(
            isinstance(actor, str) and actor for actor in record["actors"]
        ):
            raise ValueError(
                f"run manifest localnets[{index}].actors must contain non-empty strings"
            )
    terminal = manifest["status"] in TERMINAL_STATUSES
    if terminal:
        if not isinstance(manifest["completed_at"], str):
            raise ValueError("terminal run manifest requires completed_at")
        termination = _require_exact_fields(
            manifest["termination"],
            frozenset({"reason", "error", "exit_code"}),
            "run manifest termination",
        )
        if not isinstance(termination["reason"], str) or not isinstance(
            termination["exit_code"], int
        ):
            raise ValueError(
                "run manifest termination requires string reason and integer exit_code"
            )
        if not termination["reason"]:
            raise ValueError("run manifest termination reason cannot be empty")
        if termination["error"] is not None and not isinstance(
            termination["error"],
            str,
        ):
            raise ValueError(
                "run manifest termination error must be a string or null"
            )
        if manifest["status"] == "complete" and (
            termination["exit_code"] != 0 or termination["error"] is not None
        ):
            raise ValueError(
                "complete run manifest requires exit_code 0 and no error"
            )
        if manifest["status"] != "complete" and termination["exit_code"] == 0:
            raise ValueError(
                "failed or interrupted run manifest requires a non-zero exit_code"
            )
    elif manifest["completed_at"] is not None or manifest["termination"] is not None:
        raise ValueError(
            "running run manifest cannot have completed_at or termination"
        )
    return manifest


def load_manifest(
    path: Path,
    *,
    require_terminal: bool = False,
) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: malformed run manifest JSON") from exc
    return validate_manifest(value, require_terminal=require_terminal)

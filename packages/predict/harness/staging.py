"""Stage the Predict package closure into a disposable scratch workspace.

Canonical Move.toml, Move.lock, and Published.toml files are read-only inputs.
Every file the ephemeral package manager may rewrite lives under ``workspace``.
"""

from __future__ import annotations

import hashlib
import io
import re
import shutil
import tarfile
import threading
import tomllib
from dataclasses import dataclass
from pathlib import Path

from . import cancellation, config

_IGNORE = shutil.ignore_patterns(*config.STAGE_IGNORE)
_FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
_SAFE_SUBDIR_PART = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._-]*$")


@dataclass(frozen=True)
class GitDependency:
    """A canonical, exact git dependency discovered from Move.toml."""

    name: str
    repo: str
    rev: str
    subdir: str

    def cache_root(self) -> Path:
        safe_repo = re.sub(r"[^A-Za-z0-9_-]", "_", self.repo)
        return Path.home() / ".move" / "git" / f"{safe_repo}_{self.rev}"


def _manifest(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


def _git_source(manifest: dict, name: str) -> dict:
    source = manifest.get("dependencies", {}).get(name)
    if source is None:
        source = manifest.get("dep-replacements", {}).get("testnet", {}).get(name)
    if not isinstance(source, dict):
        raise ValueError(f"canonical manifest does not declare git dependency {name}")
    required = {"git", "rev", "subdir"}
    missing = required - source.keys()
    if missing:
        raise ValueError(f"{name} dependency is missing {sorted(missing)}")
    return {field: str(source[field]) for field in required}


def validate_git_coordinate(repo: str, subdir: str) -> None:
    """Reject a git coordinate that is not a safe, allowlisted fetch target."""
    if _CONTROL.search(repo) or _CONTROL.search(subdir):
        raise ValueError("git dependency coordinate contains a control character")
    if repo not in config.ALLOWED_GIT_REPOS:
        raise ValueError(f"git dependency repository is not allowlisted: {repo}")
    parts = subdir.split("/")
    if (
        not subdir
        or subdir.startswith("/")
        or "\\" in subdir
        or ":" in subdir
        or any(part in {".", ".."} or part.startswith("-") for part in parts)
        or not all(_SAFE_SUBDIR_PART.fullmatch(part) for part in parts)
    ):
        raise ValueError(f"git dependency subdir is not a safe relative path: {subdir}")


def external_dependency_specs(
    packages_dir: Path = config.PACKAGES_DIR,
) -> dict[str, GitDependency]:
    """Read exact upstream sources from both canonical consumers and reject drift."""
    manifests = {
        "predict": _manifest(packages_dir / "predict" / "Move.toml"),
        "propbook": _manifest(packages_dir / "propbook" / "Move.toml"),
    }
    specs: dict[str, GitDependency] = {}
    for name in config.GIT_DEP_NAMES:
        consumers = ("propbook",) if name == "bs_sid" else tuple(manifests)
        sources = {
            consumer: _git_source(manifest, name)
            for consumer, manifest in manifests.items()
            if consumer in consumers
        }
        if len({tuple(sorted(source.items())) for source in sources.values()}) != 1:
            raise ValueError(
                f"{name} dependency drift between canonical consumers: {sources}"
            )
        source = next(iter(sources.values()))
        if not _FULL_SHA.fullmatch(source["rev"]):
            raise ValueError(f"{name} must use a full 40-character commit SHA")
        validate_git_coordinate(source["git"], source["subdir"])
        specs[name] = GitDependency(
            name=name,
            repo=source["git"],
            rev=source["rev"],
            subdir=source["subdir"],
        )
    return specs


def checkout_fingerprint(
    packages_dir: Path = config.PACKAGES_DIR,
    package_names: tuple[str, ...] | list[str] = config.LOCAL_CLOSURE,
) -> str:
    """Hash canonical package files plus any misplaced ephemeral artifacts."""
    h = hashlib.sha256()
    for name in sorted(package_names):
        package_dir = packages_dir / name
        for filename in ("Move.toml", "Move.lock", "Published.toml"):
            path = package_dir / filename
            h.update(f"{name}/{filename}\0".encode())
            h.update(path.read_bytes() if path.exists() else b"<missing>")
        artifacts = {
            path
            for pattern in ("Pub.*.toml", "*.bak", "*.tmp")
            for path in package_dir.glob(pattern)
        }
        for path in sorted(artifacts, key=lambda artifact: artifact.name):
            h.update(f"{name}/{path.name}\0".encode())
            h.update(path.read_bytes())
    return h.hexdigest()


def staged_package_paths(workspace: Path) -> dict[str, Path]:
    paths = {name: workspace / "packages" / name for name in config.LOCAL_CLOSURE}
    paths.update({name: workspace / "deps" / name for name in config.GIT_DEP_NAMES})
    return paths


def require_staged_path(workspace: Path, path: Path) -> Path:
    """Return a resolved path only when it is contained by the workspace."""
    root = workspace.resolve()
    resolved = path.resolve()
    if not resolved.is_relative_to(root):
        raise ValueError(f"publication path escapes disposable workspace: {resolved}")
    return resolved


def validate_workspace(workspace: Path) -> dict[str, Path]:
    """Validate the complete staged closure before any publication transaction."""
    paths = staged_package_paths(workspace)
    for name, path in paths.items():
        resolved = require_staged_path(workspace, path)
        manifest_path = resolved / "Move.toml"
        if not manifest_path.is_file():
            raise FileNotFoundError(f"staged package {name} has no Move.toml: {manifest_path}")
        manifest = _manifest(manifest_path)
        ephemeral_envs = {"sim", "localnet"} & (
            set(manifest.get("environments", {}))
            | set(manifest.get("dep-replacements", {}))
        )
        if ephemeral_envs:
            raise ValueError(
                f"staged package {name} declares ephemeral environments {sorted(ephemeral_envs)}"
            )
        dependency_tables = [manifest.get("dependencies", {})]
        dependency_tables.extend(manifest.get("dep-replacements", {}).values())
        for dependency_table in dependency_tables:
            for dependency, source in dependency_table.items():
                if not isinstance(source, dict) or "local" not in source:
                    continue
                dependency_path = require_staged_path(
                    workspace, manifest_path.parent / str(source["local"])
                )
                if not (dependency_path / "Move.toml").is_file():
                    raise FileNotFoundError(
                        f"{name}.{dependency} points to missing staged package "
                        f"{dependency_path}"
                    )
    return paths


def stage_closure(
    workspace: Path,
    cancel_event: threading.Event | None = None,
) -> dict[str, Path]:
    """Copy the canonical closure and its exact upstream sources into a fresh workspace."""
    cancellation.check(cancel_event)
    if workspace.exists() and any(workspace.iterdir()):
        raise FileExistsError(f"staging workspace must be empty: {workspace}")
    package_dir = workspace / "packages"
    dependency_dir = workspace / "deps"
    package_dir.mkdir(parents=True, exist_ok=True)
    dependency_dir.mkdir(parents=True, exist_ok=True)

    for name in config.LOCAL_CLOSURE:
        cancellation.check(cancel_event)
        source = config.PACKAGES_DIR / name
        if not source.is_dir():
            raise FileNotFoundError(f"local package not found: {source}")
        shutil.copytree(source, package_dir / name, ignore=_IGNORE)

    for name, spec in external_dependency_specs().items():
        cancellation.check(cancel_event)
        _stage_git_dep(spec, dependency_dir / name, cancel_event)

    cancellation.check(cancel_event)
    return validate_workspace(workspace)


def _stage_git_dep(
    spec: GitDependency,
    destination: Path,
    cancel_event: threading.Event | None = None,
) -> None:
    validate_git_coordinate(spec.repo, spec.subdir)
    cache = spec.cache_root()
    if _git_has_commit(cache, spec.rev, cancel_event):
        _export_git_tree(
            cache,
            spec.rev,
            spec.subdir,
            destination,
            cancel_event,
        )
        return

    checkout = destination.parent / f"{spec.name}_repo"
    cancellation.run(
        ["git", "init", "-q", str(checkout)],
        cancel_event=cancel_event,
        check_result=True,
        capture_output=True,
    )
    cancellation.run(
        [
            "git",
            "-C",
            str(checkout),
            "-c",
            "protocol.ext.allow=never",
            "fetch",
            "-q",
            "--depth",
            "1",
            "--",
            spec.repo,
            spec.rev,
        ],
        cancel_event=cancel_event,
        check_result=True,
        capture_output=True,
    )
    try:
        _export_git_tree(
            checkout,
            spec.rev,
            spec.subdir,
            destination,
            cancel_event,
        )
    finally:
        shutil.rmtree(checkout, ignore_errors=True)


def _git_has_commit(
    repository: Path,
    revision: str,
    cancel_event: threading.Event | None = None,
) -> bool:
    if not repository.is_dir():
        return False
    result = cancellation.run(
        [
            "git",
            "-C",
            str(repository),
            "cat-file",
            "-e",
            "--",
            f"{revision}^{{commit}}",
        ],
        cancel_event=cancel_event,
        capture_output=True,
    )
    return result.returncode == 0


def _export_git_tree(
    repository: Path,
    revision: str,
    subdir: str,
    destination: Path,
    cancel_event: threading.Event | None = None,
) -> None:
    """Export committed bytes only, ignoring cache working-tree state."""
    result = cancellation.run(
        [
            "git",
            "-C",
            str(repository),
            "-c",
            "protocol.ext.allow=never",
            "archive",
            "--format=tar",
            "--",
            f"{revision}:{subdir}",
        ],
        cancel_event=cancel_event,
        check_result=True,
        capture_output=True,
    )
    with tarfile.open(fileobj=io.BytesIO(result.stdout), mode="r:") as archive:
        for member in archive.getmembers():
            member_path = Path(member.name)
            if member_path.is_absolute() or ".." in member_path.parts:
                raise ValueError(f"unsafe path in dependency archive: {member.name}")
            if member.issym() or member.islnk():
                raise ValueError(f"links are not allowed in dependency archive: {member.name}")
        destination.mkdir(parents=True)
        archive.extractall(destination)

"""Stage the Predict package closure into a disposable scratch workspace.

The whole point of the harness: publish from staged copies so every write `sui`
makes (regenerated Move.lock pins, Published.toml, Pub.*.toml) lands here, never
in the real checkout. Local deps use relative `../foo` paths, so mirroring the
packages/ subtree makes them resolve unchanged; only the git deps need staging
plus explicit path injection (done later in publish.py).
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from . import config

_IGNORE = shutil.ignore_patterns(*config.STAGE_IGNORE)


def stage_closure(workspace: Path) -> None:
    pkgdir = workspace / "packages"
    depsdir = workspace / "deps"
    pkgdir.mkdir(parents=True, exist_ok=True)
    depsdir.mkdir(parents=True, exist_ok=True)

    for name in config.LOCAL_CLOSURE:
        src = config.PACKAGES_DIR / name
        if not src.is_dir():
            raise FileNotFoundError(f"local package not found: {src}")
        shutil.copytree(src, pkgdir / name, ignore=_IGNORE, dirs_exist_ok=True)

    for name, spec in config.GIT_DEPS.items():
        _stage_git_dep(name, spec, depsdir / name)


def _stage_git_dep(name: str, spec: dict, dest: Path) -> None:
    cache = Path(spec["cache"])
    if (cache / "Move.toml").is_file():
        shutil.copytree(cache, dest, ignore=_IGNORE, dirs_exist_ok=True)
        return
    # Fallback: shallow-clone the branch and copy the subdir.
    checkout = dest.parent / f"{name}_repo"
    subprocess.run(
        ["git", "clone", "--depth", "1", "--branch", spec["branch"], spec["repo"], str(checkout)],
        check=True,
        capture_output=True,
    )
    shutil.copytree(checkout / spec["subdir"], dest, ignore=_IGNORE, dirs_exist_ok=True)
    shutil.rmtree(checkout, ignore_errors=True)

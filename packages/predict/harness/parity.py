"""Localnet contract-parity and external gas-benchmark tasks."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from devtools.run_manifest import complete_manifest, new_manifest, write_manifest

from . import config
from .session import initialized_localnet


def _positive_int(value: str | int | None, name: str) -> int | None:
    if value in (None, ""):
        return None
    parsed = int(value)
    if parsed <= 0:
        raise ValueError(f"{name} must be a positive integer")
    return parsed


def _source_path(source: str | None) -> Path:
    configured = source or os.environ.get("SCENARIO_PATH")
    return (
        Path(configured).expanduser()
        if configured
        else config.SIMULATIONS_DIR / "data" / "scenario_dataset.csv"
    )


def _generate_scenario(source: Path, scenario: Path, seed: int) -> None:
    if not source.is_file():
        raise FileNotFoundError(
            f"scenario source dataset does not exist: {source}; "
            "pass --source or set SCENARIO_PATH"
        )
    subprocess.run(
        [
            "python3",
            "simulations/data/generate_scenario.py",
            "--source",
            str(source),
            "--config",
            str(config.SCENARIO_CONFIG),
            "--out",
            str(scenario),
            "--seed",
            str(seed),
        ],
        cwd=config.PREDICT_DIR,
        check=True,
    )


def _legacy_copy(instance_dir: Path, legacy_runs_dir: Path) -> Path:
    legacy_artifacts = legacy_runs_dir / instance_dir.name / "artifacts"
    legacy_artifacts.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(instance_dir / "artifacts", legacy_artifacts, dirs_exist_ok=True)
    return legacy_artifacts


def run(
    *,
    source: str | None = None,
    seed: int = 0,
    max_rows: int | None = None,
    benchmark: bool = False,
    legacy_runs_dir: str | None = None,
) -> int:
    source_path = _source_path(source)
    max_rows = _positive_int(
        max_rows if max_rows is not None else os.environ.get("SIM_MAX_ROWS"),
        "max rows",
    )
    engine = "benchmark" if benchmark else "parity"
    with initialized_localnet(engine, keep=True) as context:
        instance_dir = context["instance_dir"]
        artifacts_dir = instance_dir / "artifacts"
        scenario = artifacts_dir / "scenario.csv"
        manifest_path = artifacts_dir / "run-manifest.json"
        _generate_scenario(source_path, scenario, seed)

        command = ["npx", "tsx", "simulations/src/sim.ts"]
        if max_rows is not None:
            command.extend(["--max-rows", str(max_rows)])

        manifest = new_manifest(
            engine=engine,
            run_id=context["run_id"],
            repo=config.REPO_DIR,
            source=source_path,
            scenario=scenario,
            config=config.SCENARIO_CONFIG,
            seed=seed,
            command=command,
            max_rows=max_rows,
            deployment=context["deployment"],
        )
        write_manifest(manifest_path, manifest)

        error: BaseException | None = None
        try:
            subprocess.run(
                command,
                cwd=config.PREDICT_DIR,
                env={
                    **os.environ,
                    "INSTANCE_DIR": str(instance_dir),
                    "SCENARIO_PATH": str(scenario),
                },
                check=True,
            )
            subprocess.run(
                [
                    "python3",
                    "simulations/compare_parity.py",
                    str(artifacts_dir / "local_data.json"),
                    str(artifacts_dir / "python_data.json"),
                ],
                cwd=config.PREDICT_DIR,
                check=True,
            )
            if benchmark:
                subprocess.run(
                    [
                        "python3",
                        "simulations/write_benchmark_results.py",
                        str(artifacts_dir / "local_trace.json"),
                        str(artifacts_dir / "results.json"),
                    ],
                    cwd=config.PREDICT_DIR,
                    check=True,
                )
        except BaseException as exc:
            error = exc
            raise
        finally:
            complete_manifest(manifest, error=error)
            write_manifest(manifest_path, manifest)
            if legacy_runs_dir is not None:
                legacy = _legacy_copy(instance_dir, Path(legacy_runs_dir))
                print(f"benchmark artifacts: {legacy}")

        print(f"{engine} artifacts: {artifacts_dir}")
    return 0

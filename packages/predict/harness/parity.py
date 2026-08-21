"""Localnet contract-parity and external gas-benchmark tasks."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from .run_manifest import (
    complete_manifest,
    file_input,
    localnet_record,
    new_manifest,
    relative_path,
    write_manifest,
)

from . import config
from .session import initialized_localnet


SIMULATION_GAS_BUDGET = 1_000_000_000


def _positive_int(value: str | int | None, name: str) -> int | None:
    if value in (None, ""):
        return None
    parsed = int(value)
    if parsed <= 0:
        raise ValueError(f"{name} must be a positive integer")
    return parsed


def _generate_scenario(source: Path, scenario: Path, seed: int) -> None:
    if not source.is_file():
        raise FileNotFoundError(
            f"scenario source dataset does not exist: {source}; "
            "pass --source"
        )
    subprocess.run(
        [
            "python3",
            "simulations/generate_scenario.py",
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


def run(
    *,
    source: str,
    seed: int = 0,
    max_rows: int | None = None,
    benchmark: bool = False,
    results_output: str | None = None,
) -> int:
    if results_output is not None and not benchmark:
        raise ValueError("results_output is only valid for benchmark runs")
    source_path = Path(source).expanduser()
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

        command = [
            "npm",
            "exec",
            "--",
            "tsx",
            "simulations/src/sim.ts",
            "--scenario",
            str(scenario),
        ]
        if max_rows is not None:
            command.extend(["--max-rows", str(max_rows)])

        manifest = new_manifest(
            engine=engine,
            run_id=context["run_id"],
            repo=config.REPO_DIR,
            arguments={
                "source": str(source_path.resolve()),
                "seed": seed,
                "max_rows": max_rows,
                "results_output": results_output,
                "simulation_command": command,
            },
        )
        manifest["inputs"] = {
            "source": file_input(source_path),
            "config": file_input(config.SCENARIO_CONFIG, include_value=True),
        }
        manifest["localnets"] = [
            localnet_record(
                role=engine,
                run_id=context["run_id"],
                instance_dir=instance_dir,
                manifest_path=manifest_path,
                deployment=context["deployment"],
                setup_duration_s=None,
                actors=["simulation"],
            )
        ]
        manifest["artifacts"] = {
            "scenario": relative_path(scenario, manifest_path),
            "local_data": relative_path(
                artifacts_dir / "local_data.json",
                manifest_path,
            ),
            "python_data": relative_path(
                artifacts_dir / "python_data.json",
                manifest_path,
            ),
            "local_trace": relative_path(
                artifacts_dir / "local_trace.json",
                manifest_path,
            ),
            "state": relative_path(
                artifacts_dir / "state.json",
                manifest_path,
            ),
        }
        if benchmark:
            manifest["artifacts"]["results"] = relative_path(
                artifacts_dir / "results.json",
                manifest_path,
            )
        write_manifest(manifest_path, manifest)

        error: BaseException | None = None
        try:
            _generate_scenario(source_path, scenario, seed)
            manifest["inputs"]["scenario"] = file_input(scenario)
            write_manifest(manifest_path, manifest)
            subprocess.run(
                command,
                cwd=config.PREDICT_DIR,
                env={
                    **os.environ,
                    "INSTANCE_DIR": str(instance_dir),
                    "SIM_GAS_BUDGET": str(SIMULATION_GAS_BUDGET),
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
                results_path = artifacts_dir / "results.json"
                subprocess.run(
                    [
                        "python3",
                        "simulations/write_benchmark_results.py",
                        str(artifacts_dir / "local_trace.json"),
                        str(results_path),
                    ],
                    cwd=config.PREDICT_DIR,
                    check=True,
                )
                if results_output is not None:
                    output = Path(results_output).expanduser()
                    output.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(results_path, output)
                    print(f"benchmark results: {output}")
        except BaseException as exc:
            error = exc
            raise
        finally:
            complete_manifest(
                manifest,
                status=(
                    "interrupted"
                    if isinstance(error, KeyboardInterrupt)
                    else "failed" if error is not None else "complete"
                ),
                reason=(
                    "interrupted"
                    if isinstance(error, KeyboardInterrupt)
                    else "execution_failure" if error is not None else "completed"
                ),
                exit_code=(
                    130
                    if isinstance(error, KeyboardInterrupt)
                    else 1 if error is not None else 0
                ),
                error=error,
            )
            write_manifest(manifest_path, manifest)

        print(f"{engine} artifacts: {artifacts_dir}")
    return 0

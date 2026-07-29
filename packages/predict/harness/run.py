"""One run = one full localnet lifecycle (Phase 0).

reserve slot -> stage closure -> genesis -> start -> publish -> deployment.json
-> teardown. A checkout fingerprint is checked before/after to prove the run did
not mutate any package-management file in the real checkout.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import config, localnet, publish, staging, state


@dataclass
class RunResult:
    run_id: str
    offset: int
    rpc_port: int
    faucet_port: int
    ok: bool
    deployment: dict[str, Any] | None = None
    error: str | None = None
    checkout_clean: bool = True
    elapsed_s: float = 0.0
    instance_dir: Path | None = None


def _make_run_id(name: str | None) -> str:
    stamp = time.strftime("%b%d-%H%M%S").lower()
    base = f"{name}-{stamp}" if name else stamp
    return f"{base}-{os.getpid()}"


def _mk_instance(inst: Path) -> None:
    for sub in ("workspace", "localnet", "artifacts", "logs"):
        (inst / sub).mkdir(parents=True, exist_ok=True)


def _publish_localnet(run_id: str, slot: dict[str, Any], inst: Path) -> dict[str, Any]:
    """Stage the closure, start a fresh localnet, and publish into it.

    Returns {proc, client_config, deployment, active, chain}; the caller owns
    teardown (localnet.stop + state.release). Staging finishes before localnet
    startup. Any failure or interrupt after startup stops it before re-raising.
    """
    _mk_instance(inst)
    proc = None
    try:
        with publish.staged_closure(inst / "workspace"):
            config_dir = inst / "localnet"
            print(f"[{run_id}] genesis + starting localnet...")
            client_config = localnet.genesis(config_dir, slot["rpc_port"])
            proc = localnet.start(
                config_dir,
                slot["rpc_port"],
                slot["faucet_port"],
                inst / "logs" / "localnet.log",
            )
            # Keep slot.pid = the OWNER harness pid (set in reserve). Record the
            # localnet pid/pgid separately so a dead harness reclaims the slot
            # and kills the orphaned localnet by process group.
            state.update(
                run_id,
                localnet_pid=proc.pid,
                localnet_pgid=os.getpgid(proc.pid),
                status="running",
            )
            localnet.wait_for_rpc(slot["rpc_port"])
            localnet.wait_for_faucet(slot["faucet_port"])
            active = localnet.active_address(client_config)
            localnet.fund(slot["faucet_port"], active)
            chain = localnet.chain_id(slot["rpc_port"])
            print(
                f"[{run_id}] chain={chain} active={active[:10]}... "
                "publishing staged closure..."
            )
            deployment = publish.publish_closure(
                client_config,
                inst / "workspace",
                inst / config.PUBFILE_NAME,
                config.GAS_BUDGET,
            )
            deployment["meta"] = {
                "run_id": run_id,
                "offset": slot["offset"],
                "rpc_port": slot["rpc_port"],
                "faucet_port": slot["faucet_port"],
                "chain_id": chain,
                "active_address": active,
            }
            return {
                "proc": proc,
                "client_config": client_config,
                "deployment": deployment,
                "active": active,
                "chain": chain,
            }
    except BaseException:
        # The CLI translates SIGTERM into KeyboardInterrupt, so BaseException
        # covers both terminal interrupts during bring-up.
        localnet.stop(proc)
        raise


def run(name: str | None = None, keep: bool = False) -> RunResult:
    run_id = _make_run_id(name)
    fp0 = staging.checkout_fingerprint()
    try:
        slot = state.reserve(run_id)
    except Exception as exc:  # noqa: BLE001 - degrade gracefully when slots are exhausted
        return RunResult(run_id=run_id, offset=-1, rpc_port=-1, faucet_port=-1, ok=False,
                         error=f"slot reserve failed: {exc}")
    inst = config.INSTANCES_DIR / run_id
    result = RunResult(
        run_id=run_id,
        offset=slot["offset"],
        rpc_port=slot["rpc_port"],
        faucet_port=slot["faucet_port"],
        ok=False,
        instance_dir=inst,
    )
    started = time.time()
    proc = None
    print(
        f"[{run_id}] slot offset={slot['offset']} "
        f"rpc=:{slot['rpc_port']} faucet=:{slot['faucet_port']}"
    )
    try:
        ln = _publish_localnet(run_id, slot, inst)
        proc = ln["proc"]
        deployment = ln["deployment"]
        (inst / "deployment.json").write_text(json.dumps(deployment, indent=2))
        result.deployment = deployment
        result.ok = all(deployment["packages"].get(p) for p in config.LOCAL_CLOSURE) and bool(
            deployment["packages"].get("predict")
        )
        print(f"[{run_id}] published predict={deployment['packages'].get('predict')}")
    except Exception as exc:  # noqa: BLE001 - report, never crash the runner
        result.error = f"{type(exc).__name__}: {exc}"
        print(f"[{run_id}] ERROR {result.error}", file=sys.stderr)
    finally:
        localnet.stop(proc)
        state.release(run_id)
        result.elapsed_s = round(time.time() - started, 1)
        result.checkout_clean = staging.checkout_fingerprint() == fp0
        if not result.checkout_clean:
            print(
                f"[{run_id}] FATAL: checkout package files were mutated during the run",
                file=sys.stderr,
            )
        # Retain on failure (the evidence you want to inspect) or when forced with
        # --keep; auto-delete a clean success so disk stays tidy across sweeps.
        if keep or not result.ok or not result.checkout_clean:
            why = "--keep" if keep else "failure"
            print(f"[{run_id}] retained ({why}): {inst}")
        else:
            shutil.rmtree(inst, ignore_errors=True)
    return result

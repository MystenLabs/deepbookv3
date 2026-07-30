"""Single owner for published and initialized localnet lifecycles."""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Iterator

from . import cancellation, config, localnet, oracle_setup, publish, state, suicli

_ACTIVE_LOCALNETS: dict[str, subprocess.Popen] = {}
_ACTIVE_LOCALNETS_LOCK = threading.Lock()


def make_run_id(name: str | None) -> str:
    stamp = time.strftime("%b%d-%H%M%S").lower()
    base = f"{name}-{stamp}" if name else stamp
    return f"{base}-{os.getpid()}"


def _make_instance(instance_dir: Path) -> None:
    for subdirectory in ("workspace", "localnet", "artifacts", "logs"):
        (instance_dir / subdirectory).mkdir(parents=True, exist_ok=True)


def _register_localnet(run_id: str, process: subprocess.Popen) -> None:
    with _ACTIVE_LOCALNETS_LOCK:
        _ACTIVE_LOCALNETS[run_id] = process


def _unregister_localnet(
    run_id: str,
    process: subprocess.Popen | None,
) -> None:
    with _ACTIVE_LOCALNETS_LOCK:
        if run_id in _ACTIVE_LOCALNETS and _ACTIVE_LOCALNETS[run_id] is process:
            del _ACTIVE_LOCALNETS[run_id]


def stop_active_localnets() -> None:
    """Stop every validator owned by an active worker in this harness process."""
    with _ACTIVE_LOCALNETS_LOCK:
        active = list(_ACTIVE_LOCALNETS.items())
    for _, process in active:
        localnet.request_stop(process)
    for run_id, process in active:
        localnet.stop(process)
        _unregister_localnet(run_id, process)


def _start_published_localnet(
    run_id: str,
    slot: dict[str, Any],
    instance_dir: Path,
    cancel_event: threading.Event | None = None,
) -> dict[str, Any]:
    """Stage, start, and publish one localnet; the caller owns teardown."""
    _make_instance(instance_dir)
    process = None
    try:
        cancellation.check(cancel_event)
        with publish.staged_closure(instance_dir / "workspace", cancel_event):
            cancellation.check(cancel_event)
            config_dir = instance_dir / "localnet"
            print(f"[{run_id}] genesis + starting localnet...")
            client_config = localnet.genesis(
                config_dir,
                slot["rpc_port"],
                cancel_event,
            )
            cancellation.check(cancel_event)
            process = localnet.start(
                config_dir,
                slot["rpc_port"],
                slot["faucet_port"],
                instance_dir / "logs" / "localnet.log",
            )
            _register_localnet(run_id, process)
            state.update(
                run_id,
                localnet_pid=process.pid,
                localnet_pgid=os.getpgid(process.pid),
                status="running",
            )
            cancellation.check(cancel_event)
            localnet.wait_for_rpc(
                client_config,
                slot["rpc_port"],
                cancel_event=cancel_event,
            )
            cancellation.check(cancel_event)
            localnet.wait_for_faucet(
                slot["faucet_port"],
                cancel_event=cancel_event,
            )
            cancellation.check(cancel_event)
            active = localnet.active_address(client_config, cancel_event)
            localnet.fund(
                slot["faucet_port"],
                active,
                cancel_event=cancel_event,
            )
            cancellation.check(cancel_event)
            chain = localnet.chain_id(client_config, cancel_event)
            print(
                f"[{run_id}] chain={chain} active={active[:10]}... "
                "publishing staged closure..."
            )
            deployment = publish.publish_closure(
                client_config,
                instance_dir / "workspace",
                instance_dir / config.PUBFILE_NAME,
                config.GAS_BUDGET,
                cancel_event,
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
                "run_id": run_id,
                "instance_dir": instance_dir,
                "process": process,
                "client_config": client_config,
                "deployment": deployment,
                "rpc_port": slot["rpc_port"],
                "faucet_port": slot["faucet_port"],
                "active": active,
            }
    except BaseException:
        try:
            localnet.stop(process)
        finally:
            _unregister_localnet(run_id, process)
        raise


@contextlib.contextmanager
def published_localnet(
    name: str,
    *,
    keep: bool = True,
    cancel_event: threading.Event | None = None,
) -> Iterator[dict[str, Any]]:
    """Own one published localnet and retain only public evidence on teardown."""
    run_id = make_run_id(name)
    slot = state.reserve(run_id)
    instance_dir = config.INSTANCES_DIR / run_id
    process = None
    failed = False
    print(
        f"[{run_id}] slot offset={slot['offset']} "
        f"rpc=:{slot['rpc_port']} faucet=:{slot['faucet_port']}",
        flush=True,
    )
    try:
        context = _start_published_localnet(
            run_id,
            slot,
            instance_dir,
            cancel_event,
        )
        process = context["process"]
        cancellation.check(cancel_event)
        yield context
    except BaseException:
        failed = True
        raise
    finally:
        try:
            localnet.stop(process)
        finally:
            _unregister_localnet(run_id, process)
            try:
                state.release(run_id)
            finally:
                (instance_dir / ".env.localnet").unlink(missing_ok=True)
                if keep or failed:
                    for scratch in ("localnet", "workspace"):
                        shutil.rmtree(instance_dir / scratch, ignore_errors=True)
                    why = "--keep" if keep else "failure"
                    print(f"[{run_id}] retained ({why}): {instance_dir}")
                else:
                    shutil.rmtree(instance_dir, ignore_errors=True)


def smoke(keep: bool = False) -> int:
    """Publish the package closure once and report a process-friendly result."""
    started = time.time()
    try:
        with published_localnet("smoke", keep=keep) as context:
            deployment = context["deployment"]
            (context["instance_dir"] / "deployment.json").write_text(
                json.dumps(deployment, indent=2)
            )
            missing = [
                package
                for package in config.LOCAL_CLOSURE
                if not deployment["packages"].get(package)
            ]
            if missing or not deployment["packages"].get("predict"):
                raise RuntimeError(
                    f"publication omitted required packages: {missing or ['predict']}"
                )
            print(
                f"[{context['run_id']}] published "
                f"predict={deployment['packages']['predict']}"
            )
        print(f"\nOK [{context['run_id']}] {round(time.time() - started, 1)}s")
        return 0
    except Exception as exc:  # noqa: BLE001 - smoke reports a concise failure
        print(f"\nFAIL {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


def create_funded_address(
    client_config: Path,
    faucet_port: int,
    cancel_event: threading.Event | None = None,
) -> str:
    """Create a fresh ed25519 address in the session keystore and fund it."""
    result = suicli.client(
        client_config,
        ["new-address", "ed25519", "--json"],
        cancel_event=cancel_event,
    )
    data = suicli.parse_json_lenient(result.stdout)
    address = data.get("address") or data.get("Address")
    if not address:
        raise RuntimeError(f"could not parse new-address output: {result.stdout[:300]}")
    localnet.fund(
        faucet_port,
        address,
        times=2,
        cancel_event=cancel_event,
    )
    return address


@contextlib.contextmanager
def initialized_localnet(
    name: str,
    *,
    keep: bool = True,
    create_updater: bool = False,
    cancel_event: threading.Event | None = None,
) -> Iterator[dict[str, Any]]:
    """Publish and initialize one isolated Predict localnet."""
    with published_localnet(
        name,
        keep=keep,
        cancel_event=cancel_event,
    ) as context:
        deployment = context["deployment"]
        oracle_setup.initialize(
            context["client_config"],
            deployment,
            context["instance_dir"],
            context["rpc_port"],
            context["active"],
            cancel_event,
        )
        cancellation.check(cancel_event)
        updater_address = None
        if create_updater:
            updater_address = create_funded_address(
                context["client_config"],
                context["faucet_port"],
                cancel_event,
            )
            cancellation.check(cancel_event)
            deployment["updater_address"] = updater_address
        (context["instance_dir"] / "deployment.json").write_text(
            json.dumps(deployment, indent=2)
        )
        yield {**context, "updater_address": updater_address}

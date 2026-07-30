"""Shared initialized-localnet lifecycle for live campaigns and parity runs."""

from __future__ import annotations

import contextlib
import json
import shutil
from pathlib import Path

from . import config, localnet, oracle_setup, state, suicli
from .run import _make_run_id, _publish_localnet, _unregister_localnet


def create_funded_address(client_config: Path, faucet_port: int) -> str:
    """Create a fresh ed25519 address in the session keystore and fund it."""
    result = suicli.client(client_config, ["new-address", "ed25519", "--json"])
    data = suicli.parse_json_lenient(result.stdout)
    address = data.get("address") or data.get("Address")
    if not address:
        raise RuntimeError(f"could not parse new-address output: {result.stdout[:300]}")
    localnet.fund(faucet_port, address, times=2)
    return address


@contextlib.contextmanager
def initialized_localnet(
    name: str,
    *,
    keep: bool = True,
    create_updater: bool = False,
):
    """Publish and initialize one isolated Predict localnet.

    The yielded context owns no process beyond its scope. Heavy validator and
    staged-package state is trimmed on exit while retained artifacts, manifests,
    deployment ids, and failure diagnostics remain available.
    """
    run_id = _make_run_id(name)
    slot = state.reserve(run_id)
    instance_dir = config.INSTANCES_DIR / run_id
    process = None
    print(
        f"[{run_id}] slot offset={slot['offset']} "
        f"rpc=:{slot['rpc_port']} faucet=:{slot['faucet_port']}",
        flush=True,
    )
    try:
        localnet_context = _publish_localnet(run_id, slot, instance_dir)
        process = localnet_context["proc"]
        client_config = localnet_context["client_config"]
        deployment = localnet_context["deployment"]
        active = localnet_context["active"]
        oracle_setup.initialize(
            client_config,
            deployment,
            instance_dir,
            slot["rpc_port"],
            active,
        )
        updater_address = None
        if create_updater:
            updater_address = create_funded_address(
                client_config,
                slot["faucet_port"],
            )
            deployment["updater_address"] = updater_address
        (instance_dir / "deployment.json").write_text(
            json.dumps(deployment, indent=2)
        )
        yield {
            "run_id": run_id,
            "instance_dir": instance_dir,
            "client_config": client_config,
            "deployment": deployment,
            "rpc_port": slot["rpc_port"],
            "faucet_port": slot["faucet_port"],
            "active": active,
            "updater_address": updater_address,
        }
    finally:
        localnet.stop(process)
        _unregister_localnet(run_id, process)
        state.release(run_id)
        if keep:
            for scratch in ("localnet", "workspace"):
                shutil.rmtree(instance_dir / scratch, ignore_errors=True)
        else:
            shutil.rmtree(instance_dir, ignore_errors=True)

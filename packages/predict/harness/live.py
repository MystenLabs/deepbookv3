"""Oracle-ready, long-lived localnet sessions for the live-data simulation.

bring up (publish the closure) -> oracle/account init -> dedicated updater address
-> stream real Pyth+BS onto the propbook feeds -> hold the localnet alive. This is
the substrate the Predict layer (markets, trading, keepers) attaches to; it stays
up until the session exits.
"""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

from . import config, localnet, oracle_setup, state, suicli
from .run import _make_run_id, _publish_localnet


def _raise_keyboard_interrupt(*_) -> None:
    raise KeyboardInterrupt()


def _create_funded_address(client_config: Path, faucet_port: int) -> str:
    """Create a fresh ed25519 address in the keystore and fund it (the oracle updater)."""
    cp = suicli.client(client_config, ["new-address", "ed25519", "--json"])
    data = suicli.parse_json_lenient(cp.stdout)
    addr = data.get("address") or data.get("Address")
    if not addr:
        raise RuntimeError(f"could not parse new-address output: {cp.stdout[:300]}")
    localnet.fund(faucet_port, addr, times=2)
    return addr


@contextlib.contextmanager
def oracle_ready_localnet(name: str | None = None, keep: bool = True):
    """Bring up a localnet with the propbook oracle initialized and a funded updater
    address. Yields the run context; tears down the localnet on exit."""
    run_id = _make_run_id(name or "live")
    slot = state.reserve(run_id)
    inst = config.INSTANCES_DIR / run_id
    proc = None
    print(f"[{run_id}] slot offset={slot['offset']} rpc=:{slot['rpc_port']} faucet=:{slot['faucet_port']}")
    try:
        ln = _publish_localnet(run_id, slot, inst)
        proc = ln["proc"]
        client_config = ln["client_config"]
        deployment = ln["deployment"]
        active = ln["active"]
        print(f"[{run_id}] initializing wormhole + pyth + account, writing .env.localnet...")
        oracle_setup.initialize(client_config, deployment, inst, slot["rpc_port"], active)
        updater_address = _create_funded_address(client_config, slot["faucet_port"])
        deployment["updater_address"] = updater_address
        (inst / "deployment.json").write_text(json.dumps(deployment, indent=2))
        print(
            f"[{run_id}] ORACLE-READY  rpc=http://127.0.0.1:{slot['rpc_port']}  "
            f"updater={updater_address[:12]}  env={inst / '.env.localnet'}"
        )
        yield {
            "run_id": run_id, "instance_dir": inst, "client_config": client_config,
            "deployment": deployment, "rpc_port": slot["rpc_port"], "active": active,
            "updater_address": updater_address,
        }
    finally:
        localnet.stop(proc)
        state.release(run_id)
        if not keep:
            shutil.rmtree(inst, ignore_errors=True)


def spike_mint() -> int:
    """B1: oracle-ready localnet -> market + trader -> resolve + execute a semantic mint."""
    with oracle_ready_localnet(name="mint", keep=True) as ctx:
        env = {**os.environ, "INSTANCE_DIR": str(ctx["instance_dir"])}
        print(f"[{ctx['run_id']}] running B1 mint spike (resolve + execute against live data)...")
        cp = subprocess.run(["npx", "tsx", "mintSpike.ts"], cwd=str(config.TS_DIR), env=env)
        return cp.returncode


# Cadence id -> period ms (for the updater grid spec).
_CADENCE_PERIOD_MS = {0: 60_000, 1: 300_000, 2: 3_600_000, 3: 86_400_000, 4: 604_800_000, 5: 2_592_000_000}


def hold(name: str | None = None, seconds: int = 0, cadence: int = 0) -> int:
    """Bring up the full running sim: localnet + the Predict keeper + the oracle updater.

    The keeper is the single setup owner (publishes feeds.json) and runs the market
    lifecycle; the updater is the sole WS consumer (warms the keeper's cadence, writes
    snapshot.json). Holds until Ctrl-C/SIGTERM, or for `seconds` if > 0. Tears down both
    subprocesses and the localnet on exit.
    """
    signal.signal(signal.SIGTERM, _raise_keyboard_interrupt)
    period_ms = _CADENCE_PERIOD_MS.get(cadence, 60_000)
    with oracle_ready_localnet(name, keep=True) as ctx:
        base = {**os.environ, "INSTANCE_DIR": str(ctx["instance_dir"]), "DURATION_MS": "0"}
        keeper = subprocess.Popen(
            ["npx", "tsx", "keeperService.ts"],
            cwd=str(config.TS_DIR), env={**base, "KEEPER_CADENCE": str(cadence)},
        )
        updater = subprocess.Popen(
            ["npx", "tsx", "oracleService.ts"],
            cwd=str(config.TS_DIR),
            env={**base, "UPDATER_ADDRESS": ctx["updater_address"], "GRID_SPEC": f"{period_ms}:6"},
        )
        procs = [keeper, updater]
        print(f"\nharness up: keeper (pid {keeper.pid}) + updater (pid {updater.pid}); localnet held. Ctrl-C to tear down.")
        try:
            deadline = (time.time() + seconds) if seconds > 0 else None
            while all(p.poll() is None for p in procs):
                if deadline and time.time() >= deadline:
                    break
                time.sleep(2)
        except KeyboardInterrupt:
            print("tearing down...")
        finally:
            for p in procs:
                if p.poll() is None:
                    p.terminate()
                    try:
                        p.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        p.kill()
    return 0

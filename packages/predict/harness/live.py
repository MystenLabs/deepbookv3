"""Oracle-ready, long-lived localnet sessions for the live-data simulation.

bring up (publish the closure) -> oracle/account init -> dedicated updater address
-> stream real Pyth+BS onto the propbook feeds -> hold the localnet alive. This is
the substrate the Predict layer (markets, trading, keepers) attaches to; it stays
up until the session exits.
"""

from __future__ import annotations

import contextlib
import functools
import json
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

from . import config, localnet, oracle_setup, state, suicli
from .run import _make_run_id, _publish_localnet

# Flush every print so captured logs (autonomous/background runs) stay in chronological
# order with subprocess output, instead of being reordered by Python's block buffering on
# a pipe. Harmless on a terminal (already line-buffered).
print = functools.partial(print, flush=True)


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
            "deployment": deployment, "rpc_port": slot["rpc_port"], "faucet_port": slot["faucet_port"],
            "active": active, "updater_address": updater_address,
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


def _terminate_group(p: subprocess.Popen) -> None:
    """SIGTERM (then SIGKILL) the process's whole group so npx -> tsx -> node all die."""
    if p.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
    except ProcessLookupError:
        pass


def hold(name: str | None = None, seconds: int = 0, cadence: int = 0, traders: int = 0, replay: str | None = None) -> int:
    """Bring up the full running sim: localnet + Predict keeper + oracle updater + N fuzz
    traders.

    The keeper is the single setup owner (publishes feeds.json, funds the traders with
    DUSDC) and runs the market lifecycle; the updater is the sole WS consumer (warms the
    keeper's cadence, writes snapshot.json); the traders read those shared files and fuzz
    mints/redeems. The core (keeper + updater) is SUPERVISED: a dead one is restarted (it
    re-attaches via the idempotent setup + reconciles markets from chain), up to
    max_restarts, after which the run tears down. A crashing trader never kills the run.
    Every subprocess runs in its own process group; every gas address is auto-refilled.
    Holds until Ctrl-C/SIGTERM, or `seconds`.
    """
    signal.signal(signal.SIGTERM, _raise_keyboard_interrupt)
    period_ms = _CADENCE_PERIOD_MS.get(cadence, 60_000)
    max_restarts = 5
    with oracle_ready_localnet(name, keep=True) as ctx:
        trader_addrs = [_create_funded_address(ctx["client_config"], ctx["faucet_port"]) for _ in range(traders)]
        base = {**os.environ, "INSTANCE_DIR": str(ctx["instance_dir"]), "DURATION_MS": "0"}

        def launch_keeper() -> subprocess.Popen:
            return subprocess.Popen(
                ["npx", "tsx", "keeperService.ts"], cwd=str(config.TS_DIR),
                env={**base, "KEEPER_CADENCE": str(cadence), "TRADER_ADDRESSES": ",".join(trader_addrs)},
                start_new_session=True,
            )

        def launch_updater() -> subprocess.Popen:
            env = {**base, "UPDATER_ADDRESS": ctx["updater_address"], "GRID_SPEC": f"{period_ms}:6"}
            if replay:  # re-play a recorded hub stream instead of opening a live provider WS
                env["REPLAY_FILE"] = replay
            return subprocess.Popen(["npx", "tsx", "oracleService.ts"], cwd=str(config.TS_DIR), env=env, start_new_session=True)

        core = {"keeper": launch_keeper(), "updater": launch_updater()}
        launchers = {"keeper": launch_keeper, "updater": launch_updater}
        restarts = {"keeper": 0, "updater": 0}
        traders_procs = [
            subprocess.Popen(["npx", "tsx", "traderService.ts"], cwd=str(config.TS_DIR), env={**base, "TRADER_ADDRESS": a}, start_new_session=True)
            for a in trader_addrs
        ]
        gas_addrs = [ctx["active"], ctx["updater_address"], *trader_addrs]
        print(f"\nharness up: keeper + updater + {traders} trader(s); core supervised; localnet held. Ctrl-C to tear down.")
        deadline = (time.time() + seconds) if seconds > 0 else None
        last_gas = 0.0
        give_up = False
        try:
            while not give_up:
                if deadline and time.time() >= deadline:
                    break
                # Supervise the core: restart a dead keeper/updater (it re-attaches on start).
                for cname, proc in core.items():
                    if proc.poll() is None:
                        continue
                    restarts[cname] += 1
                    if restarts[cname] > max_restarts:
                        print(f"[supervise] {cname} exceeded {max_restarts} restarts; tearing down")
                        give_up = True
                        break
                    print(f"[supervise] {cname} died (exit {proc.returncode}); restart #{restarts[cname]}...")
                    time.sleep(3)
                    core[cname] = launchers[cname]()
                if give_up:
                    break
                now = time.time()
                if now - last_gas >= 30:  # keep all actors funded over long holds
                    last_gas = now
                    for addr in gas_addrs:
                        bal = localnet.balance(ctx["rpc_port"], addr)
                        if 0 <= bal < 2_000_000_000:  # < 2 SUI
                            print(f"[gas] refilling {addr[:10]} (bal {bal / 1e9:.2f} SUI)")
                            localnet.fund(ctx["faucet_port"], addr, times=1)
                time.sleep(2)
        except KeyboardInterrupt:
            print("tearing down...")
        finally:
            for p in (*core.values(), *traders_procs):
                _terminate_group(p)
    return 0


def up_many(n: int = 2, seconds: int = 0, cadence: int = 0, traders: int = 1) -> int:
    """Parallel: ONE shared market-data hub (a single WS pair) feeding N localnets, each
    with a keeper + a HubSource updater + `traders` fuzz traders. The hub writes a global
    snapshot the updaters read, so N localnets run off one stream instead of N. An
    ExitStack tears down every subprocess (LIFO) then every localnet on exit.
    """
    signal.signal(signal.SIGTERM, _raise_keyboard_interrupt)
    period_ms = _CADENCE_PERIOD_MS.get(cadence, 60_000)
    grid_spec = f"{period_ms}:6"
    hub_snapshot = config.LOCALNETS_DIR / "hub-snapshot.json"
    hub_record = config.LOCALNETS_DIR / "hub-record.jsonl"
    with contextlib.ExitStack() as stack:
        hub = subprocess.Popen(
            ["npx", "tsx", "hub.ts"], cwd=str(config.TS_DIR),
            env={**os.environ, "HUB_SNAPSHOT": str(hub_snapshot), "HUB_RECORD": str(hub_record), "GRID_SPEC": grid_spec, "DURATION_MS": "0"},
            start_new_session=True,
        )
        stack.callback(_terminate_group, hub)
        core = [hub]
        gas: list[tuple[int, int, str]] = []  # (rpc_port, faucet_port, address)
        print(f"hub started (pid {hub.pid}); bringing up {n} localnets...")
        for i in range(n):
            ctx = stack.enter_context(oracle_ready_localnet(name=f"par{i}", keep=True))
            trader_addrs = [_create_funded_address(ctx["client_config"], ctx["faucet_port"]) for _ in range(traders)]
            base = {**os.environ, "INSTANCE_DIR": str(ctx["instance_dir"]), "DURATION_MS": "0"}
            keeper = subprocess.Popen(
                ["npx", "tsx", "keeperService.ts"], cwd=str(config.TS_DIR),
                env={**base, "KEEPER_CADENCE": str(cadence), "TRADER_ADDRESSES": ",".join(trader_addrs)},
                start_new_session=True,
            )
            updater = subprocess.Popen(
                ["npx", "tsx", "oracleService.ts"], cwd=str(config.TS_DIR),
                env={**base, "UPDATER_ADDRESS": ctx["updater_address"], "GRID_SPEC": grid_spec, "HUB_SNAPSHOT": str(hub_snapshot)},
                start_new_session=True,
            )
            stack.callback(_terminate_group, keeper)
            stack.callback(_terminate_group, updater)
            core += [keeper, updater]
            for addr in trader_addrs:
                stack.callback(_terminate_group, subprocess.Popen(
                    ["npx", "tsx", "traderService.ts"], cwd=str(config.TS_DIR),
                    env={**base, "TRADER_ADDRESS": addr}, start_new_session=True,
                ))
            for a in (ctx["active"], ctx["updater_address"], *trader_addrs):
                gas.append((ctx["rpc_port"], ctx["faucet_port"], a))
        print(f"up-many: hub + {n} localnets (keeper + HubSource updater + {traders} trader each); held. Ctrl-C to tear down.")
        deadline = (time.time() + seconds) if seconds > 0 else None
        last_gas = 0.0
        try:
            while all(p.poll() is None for p in core):  # hub + keepers + updaters are the core
                if deadline and time.time() >= deadline:
                    break
                now = time.time()
                if now - last_gas >= 30:
                    last_gas = now
                    for rpc_port, faucet_port, addr in gas:
                        if 0 <= localnet.balance(rpc_port, addr) < 2_000_000_000:
                            localnet.fund(faucet_port, addr, times=1)
                time.sleep(2)
        except KeyboardInterrupt:
            print("tearing down...")
    return 0

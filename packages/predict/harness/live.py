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
import subprocess
import threading
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from devtools.run_manifest import (
    complete_manifest,
    localnet_record,
    new_manifest,
    relative_path,
    write_manifest,
)

from . import cancellation, config, localnet
from .session import (
    create_funded_address,
    initialized_localnet,
    make_run_id,
    stop_active_localnets,
)

# Flush every print so captured logs (autonomous/background runs) stay in chronological
# order with subprocess output, instead of being reordered by Python's block buffering on
# a pipe. Harmless on a terminal (already line-buffered).
print = functools.partial(print, flush=True)

# The keeper's per-tx gas budget (mirrors keeperService FLUSH_GAS_BUDGET). Set explicitly for the
# keeper process so its cheap settle/liquidate/rebalance/roll txs don't inherit a large trader
# SIM_GAS_BUDGET (batch strategies need 50e9) and each demand a 50e9 gas coin.
KEEPER_GAS_BUDGET = 15_000_000_000
# Refill an actor's aggregate gas below this floor. It exceeds the keeper and
# trader budgets so the gRPC executor can merge fresh faucet coins into its
# exact-version pinned payment before that coin drops below the next budget.
GAS_REFILL_FLOOR = 60_000_000_000


def _refill_gas(client_config: Path, faucet_port: int, address: str) -> int | None:
    balance = localnet.balance(client_config, address)
    if 0 <= balance < GAS_REFILL_FLOOR:
        localnet.fund(faucet_port, address, times=1)
        return balance
    return None


def _launch_actor(script: str, env: dict[str, str]) -> subprocess.Popen:
    return subprocess.Popen(
        ["npx", "tsx", script],
        cwd=str(config.TS_DIR),
        env=env,
        start_new_session=True,
    )


@contextlib.contextmanager
def oracle_ready_localnet(
    name: str | None = None,
    keep: bool = True,
    cancel_event: threading.Event | None = None,
):
    with initialized_localnet(
        name or "live",
        keep=keep,
        create_updater=True,
        cancel_event=cancel_event,
    ) as context:
        updater_address = context["updater_address"]
        print(
            f"[{context['run_id']}] ORACLE-READY  "
            f"rpc=http://127.0.0.1:{context['rpc_port']}  "
            f"updater={updater_address[:12]}  "
            f"env={context['instance_dir'] / '.env.localnet'}"
        )
        yield context


def _read_meta() -> dict:
    """Read the TS registry — { strategies: {...}, cadences: [{id, windowSize, periodMs}] } — by running
    strategies/meta.ts, the single source of truth for runner config + the enabled cadence set."""
    run = subprocess.run(
        ["npx", "tsx", "strategies/meta.ts"], cwd=str(config.TS_DIR), capture_output=True, text=True
    )
    line = next((ln for ln in reversed(run.stdout.splitlines()) if ln.strip().startswith("{")), None)
    if run.returncode != 0 or not line:
        raise RuntimeError(f"could not read TS meta:\n{run.stderr.strip()}")
    return json.loads(line)


def _grid_spec(meta: dict) -> str:
    """Oracle GRID_SPEC ('periodMs:count,...') from the enabled cadence set — each cadence's
    windowSize-period time horizon, partitioned by cadence rank (prod 1m/5m/1h)."""
    return ",".join(f"{c['periodMs']}:{c['windowSize']}" for c in meta["cadences"])


def _validate_hub_metrics(value: object) -> dict:
    if not isinstance(value, dict):
        raise ValueError("hub metrics must be an object")
    expected = {"schema_version", "elapsed_ms", "snapshots", "source"}
    missing = sorted(expected - value.keys())
    unknown = sorted(value.keys() - expected)
    if missing or unknown:
        details = []
        if missing:
            details.append(f"missing={','.join(missing)}")
        if unknown:
            details.append(f"unknown={','.join(unknown)}")
        raise ValueError("hub metrics schema mismatch; " + "; ".join(details))
    if value["schema_version"] != 1:
        raise ValueError(
            f"unsupported hub metrics schema {value['schema_version']!r}"
        )
    if type(value["elapsed_ms"]) is not int or value["elapsed_ms"] < 0:
        raise ValueError("hub metrics elapsed_ms must be a non-negative integer")
    if type(value["snapshots"]) is not int or value["snapshots"] <= 0:
        raise ValueError("hub metrics snapshots must be a positive integer")
    source = value["source"]
    if not isinstance(source, dict):
        raise ValueError("hub metrics source must be an object")
    source_expected = {
        "provider_profile",
        "provider_network",
        "provider_pkg_ver",
        "verifier_package_id",
        "signer_registry_id",
        "authenticated",
        "acknowledged_subscriptions",
        "pending_acknowledgements",
        "verified_value_batches",
        "verified_svi_batches",
        "invalid_batches",
        "unknown_sids",
        "retired_sid_updates",
        "pre_ack_updates",
        "fatal",
    }
    source_missing = sorted(source_expected - source.keys())
    source_unknown = sorted(source.keys() - source_expected)
    if source_missing or source_unknown:
        details = []
        if source_missing:
            details.append(f"missing={','.join(source_missing)}")
        if source_unknown:
            details.append(f"unknown={','.join(source_unknown)}")
        raise ValueError(
            "hub metrics source schema mismatch; " + "; ".join(details)
        )
    for field in (
        "provider_profile",
        "provider_network",
        "verifier_package_id",
        "signer_registry_id",
    ):
        if not isinstance(source[field], str) or not source[field]:
            raise ValueError(f"hub metrics source {field} must be a non-empty string")
    if type(source["provider_pkg_ver"]) is not int or source["provider_pkg_ver"] <= 0:
        raise ValueError("hub metrics source provider_pkg_ver must be a positive integer")
    counters = (
        "acknowledged_subscriptions",
        "pending_acknowledgements",
        "verified_value_batches",
        "verified_svi_batches",
        "invalid_batches",
        "unknown_sids",
        "retired_sid_updates",
        "pre_ack_updates",
    )
    for field in counters:
        if type(source[field]) is not int or source[field] < 0:
            raise ValueError(
                f"hub metrics source {field} must be a non-negative integer"
            )
    if source["authenticated"] is not True:
        raise ValueError("hub metrics source must be authenticated")
    if source["acknowledged_subscriptions"] <= 0:
        raise ValueError("hub metrics source has no acknowledged subscriptions")
    if source["verified_value_batches"] <= 0 or source["verified_svi_batches"] <= 0:
        raise ValueError("hub metrics source has no verified value/SVI evidence")
    if source["invalid_batches"] != 0:
        raise ValueError("hub metrics source recorded invalid provider batches")
    if source["fatal"] is not None:
        raise ValueError(f"hub metrics source failed: {source['fatal']}")
    return value


def hold(name: str | None = None, seconds: int = 0, traders: int = 0) -> int:
    """Bring up the full running sim: localnet + Predict keeper + oracle updater + N fuzz
    traders.

    The keeper is the single setup owner (publishes feeds.json, funds the traders with
    DUSDC) and runs the market lifecycle; the updater is the sole WS consumer (warms the
    keeper's cadence set, writes snapshot.json); the traders read those shared files and fuzz
    mints/redeems. The core (keeper + updater) is SUPERVISED: a dead one is restarted (it
    re-attaches via the idempotent setup + reconciles markets from chain), up to
    max_restarts, after which the run tears down. A crashing trader never kills the run.
    Every subprocess runs in its own process group; every gas address is auto-refilled.
    Holds until Ctrl-C/SIGTERM, or `seconds`.
    """
    meta = _read_meta()
    grid_spec = _grid_spec(meta)
    max_restarts = 5
    with oracle_ready_localnet(name, keep=True) as ctx:
        trader_addrs = [create_funded_address(ctx["client_config"], ctx["faucet_port"]) for _ in range(traders)]
        base = {**os.environ, "INSTANCE_DIR": str(ctx["instance_dir"]), "DURATION_MS": "0"}

        def launch_keeper() -> subprocess.Popen:
            return _launch_actor(
                "keeperService.ts",
                {
                    **base,
                    "TRADER_ADDRESSES": ",".join(trader_addrs),
                    "TRADER_DUSDC": meta["strategies"]["fuzz"]["fund"],
                    "SIM_GAS_BUDGET": str(KEEPER_GAS_BUDGET),
                },
            )

        def launch_updater() -> subprocess.Popen:
            env = {**base, "UPDATER_ADDRESS": ctx["updater_address"], "GRID_SPEC": grid_spec}
            return _launch_actor("oracleService.ts", env)

        core = {"keeper": launch_keeper(), "updater": launch_updater()}
        launchers = {"keeper": launch_keeper, "updater": launch_updater}
        restarts = {"keeper": 0, "updater": 0}
        restart_at = {"keeper": 0.0, "updater": 0.0}
        healthy_window = 120  # a core proc alive this long since its last restart has recovered
        traders_procs = [
            _launch_actor(
                "traderService.ts",
                {**base, "TRADER_ADDRESS": a, "STRATEGY": "fuzz"},
            )
            for a in trader_addrs
        ]
        gas_addrs = [ctx["active"], ctx["updater_address"], *trader_addrs]
        print(f"\nharness live: keeper + updater + {traders} trader(s); core supervised; localnet held. Ctrl-C to tear down.")
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
                    if time.time() - restart_at[cname] > healthy_window:
                        restarts[cname] = 0  # recovered: only CONSECUTIVE rapid restarts trip the cap
                    restarts[cname] += 1
                    restart_at[cname] = time.time()
                    if restarts[cname] > max_restarts:
                        print(f"[supervise] {cname} exceeded {max_restarts} consecutive restarts; tearing down")
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
                        bal = _refill_gas(
                            ctx["client_config"],
                            ctx["faucet_port"],
                            addr,
                        )
                        if bal is not None:
                            print(f"[gas] refilling {addr[:10]} (bal {bal / 1e9:.2f} SUI)")
                time.sleep(2)
        finally:
            for p in (*core.values(), *traders_procs):
                cancellation.stop_process_group(p, p.pid)
    return 1 if give_up else 0  # non-zero so a supervised give-up is a programmatic failure


class _CampaignLocalnetLease:
    """Idempotent ownership wrapper for a context entered by a setup worker."""

    def __init__(self, manager):
        self._manager = manager
        self._lock = threading.Lock()
        self._closed = False

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
        self._manager.__exit__(None, None, None)


def _campaign_capacity(concurrency: int | None) -> int:
    return max(1, min(concurrency or config.default_concurrency(), config.SLOT_COUNT))


def _campaign_validation_error(
    strategies: list[str],
    timeout: int,
    strat_meta: dict,
    capacity: int,
) -> str | None:
    if timeout < 0:
        return "--timeout must be non-negative"
    unknown = [strategy for strategy in strategies if strategy not in strat_meta]
    if unknown:
        return "unknown strategies: " + ", ".join(unknown)
    duplicates = [
        strategy
        for strategy in dict.fromkeys(strategies)
        if strategies.count(strategy) > 1
    ]
    if duplicates:
        return "duplicate strategies require ambiguous instance ownership: " + ", ".join(
            duplicates
        )
    if len(strategies) > capacity:
        return (
            f"{len(strategies)} strategies require {len(strategies)} simultaneous localnets, "
            f"above the configured capacity {capacity}; split the campaign or pass an explicit "
            "--concurrency override"
        )
    duration_only = [
        strategy
        for strategy in strategies
        if strat_meta[strategy]["requiresTimeout"]
    ]
    if timeout == 0 and duration_only:
        return (
            "--timeout is required for unbounded strategies: "
            + ", ".join(duration_only)
        )
    return None


def _setup_campaign_localnets(
    strategies: list[str],
    stack: contextlib.ExitStack,
    setup_concurrency: int,
    on_ready: Callable[[str, dict, float], None] | None = None,
) -> dict[str, dict]:
    """Enter localnets concurrently and give ExitStack teardown ownership.

    A worker records its lease immediately after __enter__ succeeds. If setup is
    interrupted before the main thread consumes that future, the finally block
    still closes the lease rather than leaving its validator to GC.
    """

    contexts: dict[str, dict] = {}
    leases: list[_CampaignLocalnetLease] = []
    leases_lock = threading.Lock()
    cancel_event = threading.Event()
    setup_complete = False

    def enter_localnet(strategy: str):
        started = time.time()
        manager = oracle_ready_localnet(
            name=strategy,
            keep=True,
            cancel_event=cancel_event,
        )
        ctx = manager.__enter__()
        lease = _CampaignLocalnetLease(manager)
        with leases_lock:
            leases.append(lease)
        return lease, ctx, round(time.time() - started, 1)

    executor = ThreadPoolExecutor(
        max_workers=setup_concurrency,
        thread_name_prefix="predict-campaign",
    )
    futures = {executor.submit(enter_localnet, strategy): strategy for strategy in strategies}
    setup_errors: list[str] = []
    try:
        for future in as_completed(futures):
            strategy = futures[future]
            try:
                lease, ctx, setup_duration_s = future.result()
                # close() is idempotent: if an interrupt lands while this callback
                # is being registered, the exceptional cleanup below can safely
                # close the same lease and ExitStack's later callback becomes a no-op.
                stack.callback(lease.close)
                contexts[strategy] = ctx
                if on_ready is not None:
                    on_ready(strategy, ctx, setup_duration_s)
                print(
                    f"campaign: {strategy} localnet ready in "
                    f"{setup_duration_s:.1f}s ({len(contexts)}/{len(strategies)})"
                )
            except Exception as exc:
                setup_errors.append(f"{strategy}: {type(exc).__name__}: {exc}")
                break
        if setup_errors:
            raise RuntimeError("localnet setup failed: " + " | ".join(setup_errors))
        setup_complete = True
        return contexts
    finally:
        if not setup_complete:
            cancel_event.set()
            # Stop validators immediately so a worker blocked in RPC/publication
            # returns before executor shutdown waits for it.
            stop_active_localnets()
        for future in futures:
            future.cancel()
        executor.shutdown(wait=True, cancel_futures=True)
        if not setup_complete:
            with leases_lock:
                entered = list(leases)
            for lease in entered:
                try:
                    lease.close()
                except BaseException as exc:
                    print(f"campaign: localnet cleanup failed: {type(exc).__name__}: {exc}")


def campaign(
    strategies: list[str],
    timeout: int = 0,
    concurrency: int | None = None,
) -> int:
    """Run each named strategy on its OWN localnet (keeper + HubSource updater + one trader),
    all off ONE shared market-data hub. Each strategy runs to completion (its maxOps) or until
    `timeout` seconds; then everything is torn down and `analyze` prints a per-strategy report.
    Instances are named by strategy so analyze labels each block. Returns non-zero for an
    operational failure, a completion-required strategy that times out, or a bug-oracle signal.
    """
    from . import analyze  # local import to avoid any import cycle

    # Per-strategy runner config + the enabled cadence set from the TS registry (single source).
    try:
        meta = _read_meta()
    except RuntimeError as e:
        print(f"campaign: {e}")
        return 1
    strat_meta = meta["strategies"]
    localnet_capacity = _campaign_capacity(concurrency)
    validation_error = _campaign_validation_error(
        strategies,
        timeout,
        strat_meta,
        localnet_capacity,
    )
    if validation_error:
        print(f"campaign: {validation_error}")
        return 1
    setup_concurrency = min(len(strategies), localnet_capacity)

    # One hub grid for all localnets — the full prod cadence set (every keeper runs all of it).
    grid_spec = _grid_spec(meta)
    campaign_id = make_run_id("campaign")
    campaign_dir = config.CAMPAIGNS_DIR / campaign_id
    runtime_dir = campaign_dir / "runtime"
    manifest_path = campaign_dir / "manifest.json"
    hub_snapshot = runtime_dir / "hub-snapshot.json"
    hub_metrics_path = campaign_dir / "hub-metrics.json"
    campaign_started = time.time()
    termination_reason = "setup"
    fatal_error: str | None = None
    operational_failed = False
    timed_out = False
    interrupted = False
    trader_exit_codes: dict[str, int | None] = {}
    support_exit_codes: dict[str, int | None] = {}
    strategy_progress = dict.fromkeys(strategies, False)
    strategy_results: dict[str, str] = {}
    contexts: dict[str, dict] = {}
    manifest = new_manifest(
        engine="campaign",
        run_id=campaign_id,
        repo=config.REPO_DIR,
        arguments={
            "strategies": strategies,
            "timeout_s": timeout,
            "concurrency": concurrency,
            "setup_concurrency": setup_concurrency,
            "localnet_capacity": localnet_capacity,
        },
    )
    manifest["inputs"] = {
        "strategy_metadata": {
            strategy: strat_meta[strategy]
            for strategy in strategies
        },
        "cadences": meta["cadences"],
        "grid_spec": grid_spec,
    }
    campaign_dir.mkdir(parents=True)
    runtime_dir.mkdir()
    manifest["artifacts"] = {
        "hub_metrics": relative_path(hub_metrics_path, manifest_path),
    }
    write_manifest(manifest_path, manifest)

    def record_ready_localnet(
        strategy: str,
        context: dict,
        setup_duration_s: float,
    ) -> None:
        manifest["localnets"].append(
            localnet_record(
                role=strategy,
                run_id=context["run_id"],
                instance_dir=context["instance_dir"],
                manifest_path=manifest_path,
                deployment=context["deployment"],
                setup_duration_s=setup_duration_s,
                actors=[],
            )
        )
        write_manifest(manifest_path, manifest)

    try:
        with contextlib.ExitStack() as stack:
            hub = _launch_actor(
                "hub.ts",
                {
                    **os.environ,
                    "HUB_SNAPSHOT": str(hub_snapshot),
                    "HUB_METRICS": str(hub_metrics_path),
                    "GRID_SPEC": grid_spec,
                    "DURATION_MS": "0",
                },
            )
            stack.callback(cancellation.stop_process_group, hub, hub.pid)
            support: list[tuple[str, subprocess.Popen]] = [("hub", hub)]
            traders_procs: list[tuple[str, subprocess.Popen]] = []
            gas: list[tuple[Path, int, str]] = []
            print(
                f"hub started (pid {hub.pid}); bringing up {len(strategies)} "
                f"strategy localnet(s) with capacity {localnet_capacity}..."
            )
            contexts = _setup_campaign_localnets(
                strategies,
                stack,
                setup_concurrency,
                record_ready_localnet,
            )

            for strategy in strategies:
                ctx = contexts[strategy]
                addr = create_funded_address(ctx["client_config"], ctx["faucet_port"])
                manifest_localnet = next(
                    localnet
                    for localnet in manifest["localnets"]
                    if localnet["role"] == strategy
                )
                base = {
                    **os.environ,
                    "INSTANCE_DIR": str(ctx["instance_dir"]),
                    "DURATION_MS": "0",
                }
                keeper = _launch_actor(
                    "keeperService.ts",
                    {
                        **base,
                        "TRADER_DUSDC": strat_meta[strategy]["fund"],
                        "TRADER_ADDRESSES": addr,
                        "SIM_GAS_BUDGET": str(KEEPER_GAS_BUDGET),
                    },
                )
                stack.callback(cancellation.stop_process_group, keeper, keeper.pid)
                manifest_localnet["actors"].append("keeper")
                write_manifest(manifest_path, manifest)
                updater = _launch_actor(
                    "oracleService.ts",
                    {
                        **base,
                        "UPDATER_ADDRESS": ctx["updater_address"],
                        "GRID_SPEC": grid_spec,
                        "HUB_SNAPSHOT": str(hub_snapshot),
                    },
                )
                stack.callback(cancellation.stop_process_group, updater, updater.pid)
                manifest_localnet["actors"].append("updater")
                write_manifest(manifest_path, manifest)
                support.extend([
                    (f"{strategy}:keeper", keeper),
                    (f"{strategy}:updater", updater),
                ])
                trader = _launch_actor(
                    "traderService.ts",
                    {
                        **base,
                        "TRADER_ADDRESS": addr,
                        "STRATEGY": strategy,
                        "SIM_GAS_BUDGET": str(strat_meta[strategy]["gasBudget"]),
                    },
                )
                stack.callback(cancellation.stop_process_group, trader, trader.pid)
                traders_procs.append((strategy, trader))
                manifest_localnet["actors"].append("trader")
                write_manifest(manifest_path, manifest)
                for actor in (ctx["active"], ctx["updater_address"], addr):
                    gas.append((ctx["client_config"], ctx["faucet_port"], actor))

            def capture_exit_codes() -> None:
                trader_exit_codes.update(
                    (name, proc.poll()) for name, proc in traders_procs
                )
                support_exit_codes.update(
                    (name, proc.poll()) for name, proc in support
                )

            # Registered last so it snapshots codes before actor teardown callbacks run.
            stack.callback(capture_exit_codes)

            print(
                f"campaign: running {', '.join(strategies)} in parallel; "
                f"{'bounded to ' + str(timeout) + 's' if timeout > 0 else 'run-to-completion'}. "
                "Ctrl-C to stop early."
            )
            termination_reason = "completed"
            deadline = (time.time() + timeout) if timeout > 0 else None
            last_gas = 0.0
            while any(trader.poll() is None for _, trader in traders_procs):
                dead_support = [
                    (name, proc.returncode)
                    for name, proc in support
                    if proc.poll() is not None
                ]
                if dead_support:
                    termination_reason = "support_failure"
                    operational_failed = True
                    print(f"campaign: support process died: {dead_support}; stopping.")
                    break
                if deadline and time.time() >= deadline:
                    termination_reason = "timeout"
                    timed_out = True
                    print("campaign: timeout reached; stopping.")
                    break
                now = time.time()
                if now - last_gas >= 30:
                    last_gas = now
                    for client_config, faucet_port, addr in gas:
                        _refill_gas(client_config, faucet_port, addr)
                time.sleep(2)

            capture_exit_codes()
        dead_support = [
            (name, code)
            for name, code in support_exit_codes.items()
            if code is not None
        ]
        if dead_support:
            termination_reason = "support_failure"
            operational_failed = True
            print(f"campaign: support process died: {dead_support}; stopping.")
    except KeyboardInterrupt:
        termination_reason = "interrupted"
        operational_failed = True
        interrupted = True
        fatal_error = "KeyboardInterrupt"
        print("tearing down...")
    except Exception as exc:
        termination_reason = "setup_failure" if termination_reason == "setup" else "harness_failure"
        operational_failed = True
        fatal_error = f"{type(exc).__name__}: {exc}"
        print(f"campaign: {fatal_error}")

    try:
        strategy_progress.update(
            {
                strategy: analyze.has_strategy_progress(
                    Path(contexts[strategy]["instance_dir"]),
                    strategy,
                )
                for strategy in strategies
                if strategy in trader_exit_codes and strategy in contexts
            }
        )
    except Exception as exc:
        if not interrupted:
            termination_reason = "setup_failure" if termination_reason == "setup" else "harness_failure"
            operational_failed = True
            fatal_error = f"{type(exc).__name__}: {exc}"
            print(f"campaign: {fatal_error}")

    for strategy in strategies:
        code = trader_exit_codes.get(strategy)
        if code == 0:
            result = "completed"
        elif code is not None:
            result = "failed"
        elif timed_out and strat_meta[strategy]["requiresTimeout"] and strategy_progress[strategy]:
            result = "bounded_stop"
        elif interrupted:
            result = "incomplete"
        elif timed_out and strat_meta[strategy]["requiresTimeout"]:
            result = "no_progress"
        else:
            result = "incomplete"
        strategy_results[strategy] = result

    by_result = {
        result: [name for name, actual in strategy_results.items() if actual == result]
        for result in ("completed", "failed", "bounded_stop", "incomplete", "no_progress")
    }
    if not operational_failed:
        if by_result["failed"]:
            termination_reason = "trader_failure"
            operational_failed = True
        elif by_result["incomplete"]:
            termination_reason = "incomplete"
            operational_failed = True
        elif by_result["no_progress"]:
            termination_reason = "no_progress"
            operational_failed = True
    print(
        "campaign: "
        + " ".join(
            f"{result}={by_result[result] or 'none'}"
            for result in by_result
        )
        + "."
    )

    campaign_finished = time.time()
    runtime_cleanup_error: str | None = None
    try:
        shutil.rmtree(runtime_dir)
    except OSError as exc:
        runtime_cleanup_error = f"{type(exc).__name__}: {exc}"
        if not operational_failed:
            termination_reason = "cleanup_failure"
            operational_failed = True
            fatal_error = runtime_cleanup_error
    hub_metrics_error: str | None = None
    try:
        _validate_hub_metrics(
            json.loads(hub_metrics_path.read_text())
        )
    except (FileNotFoundError, json.JSONDecodeError, ValueError) as exc:
        hub_metrics_error = f"{type(exc).__name__}: {exc}"
        if not operational_failed:
            termination_reason = "evidence_failure"
            operational_failed = True
            fatal_error = hub_metrics_error
    manifest["outcome"] = {
        "wall_duration_s": round(campaign_finished - campaign_started, 1),
        "runtime_cleanup_error": runtime_cleanup_error,
        "hub_metrics_error": hub_metrics_error,
        "support_exit_codes_before_teardown": support_exit_codes,
        "strategies": [
            {
                "strategy": strategy,
                "trader_exit_code_before_teardown": trader_exit_codes.get(strategy),
                "progressed": strategy_progress.get(strategy, False),
                "result": strategy_results[strategy],
            }
            for strategy in strategies
        ],
        "analysis_exit_code": None,
        "analysis_error": None,
    }
    write_manifest(manifest_path, manifest)
    print(f"campaign: machine manifest retained at {manifest_path}")

    # ExitStack has torn everything down; aggregate the per-strategy report scoped to THIS run's
    # instance dirs (never every retained instance) so an old trace can't fail — or falsely
    # satisfy `expect` for — the current verdict. `expect` flags a strategy that produced no trace.
    print("\n=== campaign report ===")
    analysis_error: str | None = None
    try:
        analysis_result = analyze.analyze_manifest(
            manifest_path,
            require_terminal=False,
        )
    except KeyboardInterrupt:
        analysis_result = 1
        analysis_error = "KeyboardInterrupt"
        termination_reason = "interrupted"
        operational_failed = True
        interrupted = True
        fatal_error = analysis_error
    except Exception as exc:
        analysis_result = 1
        analysis_error = f"{type(exc).__name__}: {exc}"
        if not operational_failed:
            termination_reason = "analysis_failure"
            operational_failed = True
            fatal_error = analysis_error

    manifest["outcome"]["analysis_exit_code"] = analysis_result
    manifest["outcome"]["analysis_error"] = analysis_error
    exit_code = 130 if interrupted else (1 if operational_failed else analysis_result)
    if termination_reason == "interrupted":
        status = "interrupted"
    elif exit_code:
        status = "failed"
    else:
        status = "complete"
    complete_manifest(
        manifest,
        status=status,
        reason=termination_reason if operational_failed else (
            "analysis_failure" if analysis_result else termination_reason
        ),
        exit_code=exit_code,
        error=fatal_error or analysis_error,
    )
    write_manifest(manifest_path, manifest)
    if interrupted:
        raise KeyboardInterrupt
    return exit_code

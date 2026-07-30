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
import signal
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from devtools.run_manifest import source_revision

from . import config, localnet
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
LIVE_TRADER_DUSDC = "1000000000000"


def _raise_keyboard_interrupt(*_) -> None:
    raise KeyboardInterrupt()


def _refill_gas(client_config: Path, faucet_port: int, address: str) -> int | None:
    balance = localnet.balance(client_config, address)
    if 0 <= balance < GAS_REFILL_FLOOR:
        localnet.fund(faucet_port, address, times=1)
        return balance
    return None


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


# Cadence id -> period ms (for the updater grid spec).
_CADENCE_PERIOD_MS = {0: 60_000, 1: 300_000, 2: 3_600_000, 3: 86_400_000, 4: 604_800_000, 5: 2_592_000_000}


def _read_meta() -> dict:
    """Read the TS registry — { strategies: {...}, cadences: [{id, windowSize}] } — by running
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
    return ",".join(f"{_CADENCE_PERIOD_MS[c['id']]}:{c['windowSize']}" for c in meta["cadences"])


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
    signal.signal(signal.SIGTERM, _raise_keyboard_interrupt)
    grid_spec = _grid_spec(_read_meta())
    max_restarts = 5
    with oracle_ready_localnet(name, keep=True) as ctx:
        trader_addrs = [create_funded_address(ctx["client_config"], ctx["faucet_port"]) for _ in range(traders)]
        base = {**os.environ, "INSTANCE_DIR": str(ctx["instance_dir"]), "DURATION_MS": "0"}

        def launch_keeper() -> subprocess.Popen:
            return subprocess.Popen(
                ["npx", "tsx", "keeperService.ts"], cwd=str(config.TS_DIR),
                env={
                    **base,
                    "TRADER_ADDRESSES": ",".join(trader_addrs),
                    "TRADER_DUSDC": LIVE_TRADER_DUSDC,
                    "SIM_GAS_BUDGET": str(KEEPER_GAS_BUDGET),
                },
                start_new_session=True,
            )

        def launch_updater() -> subprocess.Popen:
            env = {**base, "UPDATER_ADDRESS": ctx["updater_address"], "GRID_SPEC": grid_spec}
            return subprocess.Popen(["npx", "tsx", "oracleService.ts"], cwd=str(config.TS_DIR), env=env, start_new_session=True)

        core = {"keeper": launch_keeper(), "updater": launch_updater()}
        launchers = {"keeper": launch_keeper, "updater": launch_updater}
        restarts = {"keeper": 0, "updater": 0}
        restart_at = {"keeper": 0.0, "updater": 0.0}
        healthy_window = 120  # a core proc alive this long since its last restart has recovered
        traders_procs = [
            subprocess.Popen(
                ["npx", "tsx", "traderService.ts"],
                cwd=str(config.TS_DIR),
                env={**base, "TRADER_ADDRESS": a, "STRATEGY": "fuzz"},
                start_new_session=True,
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
        except KeyboardInterrupt:
            print("tearing down...")
        finally:
            for p in (*core.values(), *traders_procs):
                _terminate_group(p)
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
        if bool(
            strat_meta[strategy].get(
                "requiresTimeout",
                int(strat_meta[strategy]["maxOps"]) == 0,
            )
        )
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
) -> tuple[dict[str, dict], dict[str, dict]]:
    """Enter localnets concurrently and give ExitStack teardown ownership.

    A worker records its lease immediately after __enter__ succeeds. If setup is
    interrupted before the main thread consumes that future, the finally block
    still closes the lease rather than leaving its validator to GC.
    """

    contexts: dict[str, dict] = {}
    setup_rows: dict[str, dict] = {}
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
                deployment = ctx["deployment"]
                setup_rows[strategy] = {
                    "run_id": ctx["run_id"],
                    "instance_dir": str(ctx["instance_dir"]),
                    "setup_duration_s": setup_duration_s,
                    "rpc_port": ctx["rpc_port"],
                    "chain_id": deployment["meta"]["chain_id"],
                    "package_ids": deployment["packages"],
                    "object_ids": deployment["objects"],
                }
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
        return contexts, setup_rows
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

    signal.signal(signal.SIGTERM, _raise_keyboard_interrupt)
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
    hub_snapshot = config.LOCALNETS_DIR / f"{campaign_id}-hub-snapshot.json"
    hub_metrics_path = config.LOCALNETS_DIR / f"{campaign_id}-hub-metrics.json"
    report_path = config.LOCALNETS_DIR / f"{campaign_id}-report.json"
    campaign_started = time.time()
    termination_reason = "setup"
    fatal_error: str | None = None
    operational_failed = False
    timed_out = False
    instance_dirs: list[str] = []
    setup_rows: dict[str, dict] = {}
    trader_exit_codes: dict[str, int | None] = {}
    support_exit_codes: dict[str, int | None] = {}
    strategy_progress: dict[str, bool] = {}

    try:
        with contextlib.ExitStack() as stack:
            hub = subprocess.Popen(
                ["npx", "tsx", "hub.ts"], cwd=str(config.TS_DIR),
                env={
                    **os.environ,
                    "HUB_SNAPSHOT": str(hub_snapshot),
                    "HUB_METRICS": str(hub_metrics_path),
                    "GRID_SPEC": grid_spec,
                    "DURATION_MS": "0",
                },
                start_new_session=True,
            )
            stack.callback(_terminate_group, hub)
            support: list[tuple[str, subprocess.Popen]] = [("hub", hub)]
            traders_procs: list[tuple[str, subprocess.Popen]] = []
            gas: list[tuple[Path, int, str]] = []
            print(
                f"hub started (pid {hub.pid}); bringing up {len(strategies)} "
                f"strategy localnet(s) with capacity {localnet_capacity}..."
            )
            contexts, setup_rows = _setup_campaign_localnets(
                strategies,
                stack,
                setup_concurrency,
            )

            for strategy in strategies:
                ctx = contexts[strategy]
                instance_dirs.append(str(ctx["instance_dir"]))
                addr = create_funded_address(ctx["client_config"], ctx["faucet_port"])
                base = {
                    **os.environ,
                    "INSTANCE_DIR": str(ctx["instance_dir"]),
                    "DURATION_MS": "0",
                }
                keeper = subprocess.Popen(
                    ["npx", "tsx", "keeperService.ts"], cwd=str(config.TS_DIR),
                    env={
                        **base,
                        "TRADER_DUSDC": strat_meta[strategy]["fund"],
                        "TRADER_ADDRESSES": addr,
                        "SIM_GAS_BUDGET": str(KEEPER_GAS_BUDGET),
                    },
                    start_new_session=True,
                )
                updater = subprocess.Popen(
                    ["npx", "tsx", "oracleService.ts"], cwd=str(config.TS_DIR),
                    env={
                        **base,
                        "UPDATER_ADDRESS": ctx["updater_address"],
                        "GRID_SPEC": grid_spec,
                        "HUB_SNAPSHOT": str(hub_snapshot),
                    },
                    start_new_session=True,
                )
                stack.callback(_terminate_group, keeper)
                stack.callback(_terminate_group, updater)
                support.extend([
                    (f"{strategy}:keeper", keeper),
                    (f"{strategy}:updater", updater),
                ])
                trader = subprocess.Popen(
                    ["npx", "tsx", "traderService.ts"], cwd=str(config.TS_DIR),
                    env={
                        **base,
                        "TRADER_ADDRESS": addr,
                        "STRATEGY": strategy,
                        "SIM_GAS_BUDGET": str(strat_meta[strategy]["gasBudget"]),
                    },
                    start_new_session=True,
                )
                stack.callback(_terminate_group, trader)
                traders_procs.append((strategy, trader))
                for actor in (ctx["active"], ctx["updater_address"], addr):
                    gas.append((ctx["client_config"], ctx["faucet_port"], actor))

            print(
                f"campaign: running {', '.join(strategies)} in parallel; "
                f"{'bounded to ' + str(timeout) + 's' if timeout > 0 else 'run-to-completion'}. "
                "Ctrl-C to stop early."
            )
            termination_reason = "completed"
            deadline = (time.time() + timeout) if timeout > 0 else None
            last_gas = 0.0
            while any(trader.poll() is None for _, trader in traders_procs):
                if deadline and time.time() >= deadline:
                    termination_reason = "timeout"
                    timed_out = True
                    print("campaign: timeout reached; stopping.")
                    break
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
                now = time.time()
                if now - last_gas >= 30:
                    last_gas = now
                    for client_config, faucet_port, addr in gas:
                        _refill_gas(client_config, faucet_port, addr)
                time.sleep(2)

            trader_exit_codes = {name: proc.poll() for name, proc in traders_procs}
            support_exit_codes = {name: proc.poll() for name, proc in support}
            strategy_progress = {
                name: analyze.has_strategy_progress(
                    Path(contexts[name]["instance_dir"]),
                    name,
                )
                for name, _ in traders_procs
            }
            completed = [name for name, code in trader_exit_codes.items() if code == 0]
            failed = [name for name, code in trader_exit_codes.items() if code not in (None, 0)]
            bounded = [
                name
                for name, code in trader_exit_codes.items()
                if (
                    code is None
                    and timed_out
                    and strat_meta[name]["requiresTimeout"]
                    and strategy_progress[name]
                )
            ]
            incomplete = [
                name
                for name, code in trader_exit_codes.items()
                if code is None and timed_out and not strat_meta[name]["requiresTimeout"]
            ]
            no_progress = [
                name
                for name, code in trader_exit_codes.items()
                if (
                    code is None
                    and timed_out
                    and strat_meta[name]["requiresTimeout"]
                    and not strategy_progress[name]
                )
            ]
            if failed:
                termination_reason = "trader_failure"
                operational_failed = True
            elif incomplete:
                termination_reason = "incomplete"
                operational_failed = True
            elif no_progress:
                termination_reason = "no_progress"
                operational_failed = True
            print(
                f"campaign: completed={completed or 'none'} failed={failed or 'none'} "
                f"bounded_stop={bounded or 'none'} incomplete={incomplete or 'none'} "
                f"no_progress={no_progress or 'none'}."
            )
    except KeyboardInterrupt:
        termination_reason = "interrupted"
        operational_failed = True
        fatal_error = "KeyboardInterrupt"
        print("tearing down...")
    except BaseException as exc:
        termination_reason = "setup_failure" if termination_reason == "setup" else "harness_failure"
        operational_failed = True
        fatal_error = f"{type(exc).__name__}: {exc}"
        print(f"campaign: {fatal_error}")

    campaign_finished = time.time()
    try:
        hub_metrics = json.loads(hub_metrics_path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        hub_metrics = None
    report = {
        "schema_version": "predict_campaign_v1",
        "campaign_id": campaign_id,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(campaign_started)),
        "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(campaign_finished)),
        "wall_duration_s": round(campaign_finished - campaign_started, 1),
        "setup_concurrency": setup_concurrency,
        "localnet_capacity": localnet_capacity,
        "timeout_s": timeout,
        "source_revision": source_revision(config.REPO_DIR),
        "strategy_metadata": {
            strategy: strat_meta[strategy]
            for strategy in strategies
            if strategy in strat_meta
        },
        "cadences": meta["cadences"],
        "termination_reason": termination_reason,
        "fatal_error": fatal_error,
        "hub_metrics": hub_metrics,
        "support_exit_codes_before_teardown": support_exit_codes,
        "strategies": [
            {
                "strategy": strategy,
                **setup_rows.get(strategy, {}),
                "trader_exit_code_before_teardown": trader_exit_codes.get(strategy),
                "completed": trader_exit_codes.get(strategy) == 0,
                "progressed": strategy_progress.get(strategy, False),
                "bounded_stop": (
                    trader_exit_codes.get(strategy) is None
                    and timed_out
                    and strat_meta[strategy]["requiresTimeout"]
                    and strategy_progress.get(strategy, False)
                ),
                "incomplete": (
                    trader_exit_codes.get(strategy) is None
                    and timed_out
                    and not strat_meta[strategy]["requiresTimeout"]
                ),
                "no_progress": (
                    trader_exit_codes.get(strategy) is None
                    and timed_out
                    and strat_meta[strategy]["requiresTimeout"]
                    and not strategy_progress.get(strategy, False)
                ),
            }
            for strategy in strategies
        ],
    }
    report_path.write_text(json.dumps(report, indent=2))
    print(f"campaign: machine report retained at {report_path}")

    # ExitStack has torn everything down; aggregate the per-strategy report scoped to THIS run's
    # instance dirs (never every retained instance) so an old trace can't fail — or falsely
    # satisfy `expect` for — the current verdict. `expect` flags a strategy that produced no trace.
    print("\n=== campaign report ===")
    analysis_result = (
        analyze.analyze(instances=instance_dirs, expect=list(strategies))
        if instance_dirs
        else 1
    )
    return 1 if operational_failed else analysis_result

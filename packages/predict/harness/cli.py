"""One task router for Predict local development."""

from __future__ import annotations

import argparse
import json
import signal
import sys
from collections.abc import Callable

from . import analyze, live, parity, run as run_mod, state


def _raise_keyboard_interrupt(_signum, _frame) -> None:
    raise KeyboardInterrupt()


def _run_with_sigterm_handler(command: Callable[[], int]) -> int:
    """Let command cleanup run on SIGTERM, then report the conventional exit code."""
    previous = signal.getsignal(signal.SIGTERM)
    signal.signal(signal.SIGTERM, _raise_keyboard_interrupt)
    try:
        try:
            return command()
        except KeyboardInterrupt:
            run_mod.stop_active_localnets()
            return 130
    finally:
        signal.signal(signal.SIGTERM, previous)


def _cmd_run(args: argparse.Namespace) -> int:
    result = run_mod.run(keep=args.keep)
    status = "OK" if result.ok else "FAIL"
    clean = "clean" if result.checkout_clean else "MUTATED"
    print(
        f"\n{status} [{result.run_id}] {result.elapsed_s}s  checkout={clean}"
        + (f"  error={result.error}" if result.error else "")
    )
    return 0 if (result.ok and result.checkout_clean) else 1


def _cmd_status(_args: argparse.Namespace) -> int:
    print(json.dumps(state.snapshot(), indent=2))
    return 0


def _cmd_cleanup(args: argparse.Namespace) -> int:
    reaped = state.reap_stale()
    print(f"reclaimed stale slots: {reaped or 'none'}")
    if args.instances:
        import shutil

        if config.INSTANCES_DIR.exists():
            for d in config.INSTANCES_DIR.iterdir():
                if d.name not in state.snapshot().get("slots", {}):
                    shutil.rmtree(d, ignore_errors=True)
            print("removed orphan instance dirs")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="harness", description="Predict localnet harness")
    sub = parser.add_subparsers(dest="command", required=True)

    p_run = sub.add_parser("smoke", help="publish the package closure on one localnet")
    p_run.add_argument(
        "--keep", action="store_true", help="retain the instance dir even on a clean success"
    )
    p_run.set_defaults(func=_cmd_run)

    p_up = sub.add_parser("live", help="hold one live localnet with keeper and oracle updater")
    p_up.add_argument("--name", default=None)
    p_up.add_argument("--seconds", type=int, default=0, help="hold for N seconds then tear down (0 = until Ctrl-C)")
    p_up.add_argument("--traders", type=int, default=0, help="number of fuzz trader actors (default 0)")
    p_up.add_argument("--replay", default=None, help="replay a recorded hub stream (path) instead of live data")
    p_up.set_defaults(func=lambda a: live.hold(a.name, a.seconds, a.traders, a.replay))

    p_campaign = sub.add_parser("campaign", help="run named strategies in parallel (one localnet each) to completion, then analyze")
    p_campaign.add_argument("strategies", nargs="+", help="strategy names, e.g. mint-only mixed-churn liq-churn")
    p_campaign.add_argument(
        "--timeout",
        type=int,
        default=0,
        help="safety cap in seconds (required for strategies with no maxOps or semantic done)",
    )
    p_campaign.add_argument(
        "--concurrency",
        type=int,
        default=None,
        help="simultaneous localnet capacity (default: auto from cores/RAM)",
    )
    p_campaign.set_defaults(
        func=lambda a: live.campaign(a.strategies, a.timeout, a.concurrency)
    )

    p_parity = sub.add_parser(
        "parity",
        help="run deterministic TypeScript/localnet and Python model parity",
    )
    p_parity.add_argument("--source", default=None, help="oracle snapshot CSV")
    p_parity.add_argument("--seed", type=int, default=0)
    p_parity.add_argument("--max-rows", type=int, default=None)
    p_parity.set_defaults(
        func=lambda a: parity.run(
            source=a.source,
            seed=a.seed,
            max_rows=a.max_rows,
        )
    )

    p_benchmark = sub.add_parser(
        "benchmark",
        help="external benchmark adapter task",
    )
    p_benchmark.add_argument("--source", default=None)
    p_benchmark.add_argument("--seed", type=int, default=0)
    p_benchmark.add_argument("--max-rows", type=int, default=None)
    p_benchmark.add_argument("--legacy-runs-dir", default=None)
    p_benchmark.set_defaults(
        func=lambda a: parity.run(
            source=a.source,
            seed=a.seed,
            max_rows=a.max_rows,
            benchmark=True,
            legacy_runs_dir=a.legacy_runs_dir,
        )
    )

    p_status = sub.add_parser("status", help="show the slot registry")
    p_status.set_defaults(func=_cmd_status)

    p_analyze = sub.add_parser("analyze", help="analyze a run's trace (gas/moneyness, NAV, bug oracle)")
    p_analyze.add_argument("instance", nargs="?", default=None, help="instance dir (default: latest)")
    p_analyze.set_defaults(func=lambda a: analyze.analyze([a.instance] if a.instance else None))

    p_clean = sub.add_parser("cleanup", help="reclaim stale slots / orphan instances")
    p_clean.add_argument("--instances", action="store_true", help="also delete orphan instance dirs")
    p_clean.set_defaults(func=_cmd_cleanup)

    args = parser.parse_args(argv)
    return _run_with_sigterm_handler(lambda: args.func(args))


if __name__ == "__main__":
    sys.exit(main())

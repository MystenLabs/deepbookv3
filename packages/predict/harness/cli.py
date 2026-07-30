"""CLI:  python3 -m harness <run|run-many|up|status|cleanup>"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import signal
import sys
import threading
from collections.abc import Callable

from . import analyze, config, live, run as run_mod, state


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


def _cmd_run_many(args: argparse.Namespace) -> int:
    """Drain `count` runs through a rolling pool of `concurrency` localnets.

    The pool keeps `concurrency` localnets alive; as each finishes it frees its
    slot and the next queued run starts in it.
    """
    count = args.count
    concurrency = max(1, min(args.concurrency or config.default_concurrency(), config.SLOT_COUNT))
    print(f"draining {count} runs through a pool of {concurrency} (slot cap {config.SLOT_COUNT})\n")
    results = []
    cancel_event = threading.Event()
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=concurrency)
    futures: set[concurrent.futures.Future] = set()
    next_run = 0
    try:
        while next_run < count and len(futures) < concurrency:
            futures.add(
                executor.submit(
                    run_mod.run,
                    name=f"p{next_run}",
                    keep=args.keep,
                    cancel_event=cancel_event,
                )
            )
            next_run += 1
        while futures:
            done, futures = concurrent.futures.wait(
                futures,
                return_when=concurrent.futures.FIRST_COMPLETED,
            )
            for fut in done:
                r = fut.result()
                results.append(r)
                mark = "OK  " if (r.ok and r.checkout_clean) else "FAIL"
                extra = "" if r.checkout_clean else " MUTATED"
                print(
                    f"  [{len(results)}/{count}] {mark} offset={r.offset:<5} {r.elapsed_s:>5}s"
                    + extra + (f"  {r.error}" if r.error else "")
                )
            while next_run < count and len(futures) < concurrency:
                futures.add(
                    executor.submit(
                        run_mod.run,
                        name=f"p{next_run}",
                        keep=args.keep,
                        cancel_event=cancel_event,
                    )
                )
                next_run += 1
    except KeyboardInterrupt:
        cancel_event.set()
        for future in futures:
            future.cancel()
        run_mod.stop_active_localnets()
        raise
    finally:
        executor.shutdown(wait=True, cancel_futures=True)
    ok = sum(1 for r in results if r.ok and r.checkout_clean)
    print(f"\n=== {ok}/{count} OK (pool {concurrency}) ===")
    return 0 if ok == count else 1


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

    p_run = sub.add_parser("run", help="one full localnet lifecycle")
    p_run.add_argument(
        "--keep", action="store_true", help="retain the instance dir even on a clean success"
    )
    p_run.set_defaults(func=_cmd_run)

    p_many = sub.add_parser("run-many", help="drain N runs through a rolling localnet pool")
    p_many.add_argument("count", type=int)
    p_many.add_argument(
        "--concurrency", type=int, default=None,
        help="localnets alive at once (default: auto from cores/RAM)",
    )
    p_many.add_argument("--keep", action="store_true")
    p_many.set_defaults(func=_cmd_run_many)

    p_up = sub.add_parser("up", help="bring up the full running sim (localnet + keeper + updater) and hold it")
    p_up.add_argument("--name", default=None)
    p_up.add_argument("--seconds", type=int, default=0, help="hold for N seconds then tear down (0 = until Ctrl-C)")
    p_up.add_argument("--traders", type=int, default=0, help="number of fuzz trader actors (default 0)")
    p_up.add_argument("--replay", default=None, help="replay a recorded hub stream (path) instead of live data")
    p_up.set_defaults(func=lambda a: live.hold(a.name, a.seconds, a.traders, a.replay))

    p_up_many = sub.add_parser("up-many", help="parallel: one shared hub feeding N localnets")
    p_up_many.add_argument("n", type=int, help="number of parallel localnets")
    p_up_many.add_argument("--seconds", type=int, default=0)
    p_up_many.add_argument("--traders", type=int, default=1, help="fuzz traders per localnet")
    p_up_many.set_defaults(func=lambda a: live.up_many(a.n, a.seconds, a.traders))

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

    p_spike_mint = sub.add_parser("spike-mint", help="B1: resolve + execute a semantic mint against live data")
    p_spike_mint.set_defaults(func=lambda a: live.spike_mint())

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

"""CLI:  python3 -m harness <run|run-many|up|status|cleanup>"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import sys

from . import config, live, run as run_mod, state


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
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as ex:
        futures = [ex.submit(run_mod.run, name=f"p{i}", keep=args.keep) for i in range(count)]
        for fut in concurrent.futures.as_completed(futures):
            r = fut.result()
            results.append(r)
            mark = "OK  " if (r.ok and r.checkout_clean) else "FAIL"
            extra = "" if r.checkout_clean else " MUTATED"
            print(
                f"  [{len(results)}/{count}] {mark} offset={r.offset:<5} {r.elapsed_s:>5}s"
                + extra + (f"  {r.error}" if r.error else "")
            )
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

    p_up = sub.add_parser("up", help="bring up the oracle substrate (localnet + live updater) and hold it")
    p_up.add_argument("--name", default=None)
    p_up.add_argument("--seconds", type=int, default=0, help="hold for N seconds then tear down (0 = until Ctrl-C)")
    p_up.set_defaults(func=lambda a: live.hold(a.name, a.seconds))

    p_status = sub.add_parser("status", help="show the slot registry")
    p_status.set_defaults(func=_cmd_status)

    p_clean = sub.add_parser("cleanup", help="reclaim stale slots / orphan instances")
    p_clean.add_argument("--instances", action="store_true", help="also delete orphan instance dirs")
    p_clean.set_defaults(func=_cmd_cleanup)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

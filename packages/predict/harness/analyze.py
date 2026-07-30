"""Analyze a harness run's JSONL trace(s).

Reports op counts, gas-vs-moneyness, the pool-NAV trend (drain heuristic), keeper liveness,
and the BUG ORACLE. Classification is code-aware: a Move abort from an INVARIANT module
(arithmetic / accounting / index / custody) or a non-package module is FLAGGED as a likely
contract bug; aborts from GUARD modules are expected business preconditions; submission /
external-data (HTTP, rate-limit) failures are transient.

Exit status is non-zero when the oracle flags an abort, an adversarial probe was wrongly
accepted, or an instance has no keeper trace — so background/autonomous runs have a
programmatic signal, not just the banner. Aggregates across ALL instance dirs of a run, so
parallel campaigns are not single-instance blind.
"""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

from . import config, measurements, verdict

# The Sui per-tx COMPUTATION cap: max_gas_computation_bucket = 5,000,000 units (a protocol constant,
# verified identical localnet/testnet/mainnet) x the reference gas price. Localnet/testnet RGP 1000 ->
# 5e9 MIST; mainnet RGP 100 -> 5e8 MIST — but the binding limit is the 5M UNITS of work, so an OOG book
# size is network-independent. Capacity measurements compare compGas against this.
COMP_CAP = 5_000_000_000

# The shortest keeper cadence (1m). A run shorter than this has produced no expected flush, so a
# "never flushed" keeper is not yet a brick; a keeper that has NOT flushed past ~2x this (bootstrap +
# one expiry) despite non-transient fails IS bricked. (M1: the old `stuck` heuristic false-FAILed a
# transient blip before the first expiry and MISSED a stall that began after the first flush.)
SHORTEST_CADENCE_MS = 60_000
KEEPER_BRICK_MIN_ELAPSED_MS = 2 * SHORTEST_CADENCE_MS


def _instances() -> list[Path]:
    if not config.INSTANCES_DIR.exists():
        return []
    return [d for d in config.INSTANCES_DIR.iterdir() if (d / "trace").exists()]


def _load(trace_dir: Path) -> list[dict]:
    records: list[dict] = []
    for f in sorted(trace_dir.glob("*.jsonl")):
        actor = f.stem  # actor-aware: keeper operational fails vs trader probes
        for line in f.read_text().splitlines():
            try:
                r = json.loads(line)
                r["_actor"] = actor
                records.append(r)
            except json.JSONDecodeError:
                pass
    return records


def _analyze_one(inst: Path) -> list[str]:
    """Print one instance's report; return the list of bug-signal tags (empty = clean)."""
    recs = _load(inst / "trace")
    # Label the block by the strategy the trader ran (tagged on every trace record); fall back
    # to the instance dir name (older traces / keeper-only).
    strat_tags = Counter(r.get("strategy") for r in recs if r.get("strategy"))
    label = strat_tags.most_common(1)[0][0] if strat_tags else inst.name
    print(f"=== strategy: {label} — {len(recs)} ops [{inst.name}] ===\n")
    print("op counts:", dict(Counter(r.get("type") for r in recs)))

    # gas vs moneyness (mints), bucketed by distance from ATM (|strike/spot - 1|).
    buckets = measurements.gas_by_moneyness(recs)
    if buckets:
        print("\ngas vs moneyness (mint):")
        for k in measurements.MONEYNESS_BUCKETS:
            gs = buckets.get(k)
            if gs:
                print(f"  {k:14} n={len(gs):>3}  avg={sum(gs) // len(gs):>11,} gas")

    # pool NAV trend (flushes) -> drain heuristic.
    flushes = sorted((r for r in recs if r.get("type") == "flush" and r.get("poolValue")), key=lambda r: r["ts"])
    nav = measurements.nav_summary(recs)
    if nav:
        print(
            f"\npool NAV (flush, n={nav['count']}): first=${nav['first']:,.0f} "
            f"last=${nav['last']:,.0f} min=${nav['min']:,.0f} max=${nav['max']:,.0f}"
        )
        if nav["max_drawdown"] > 0.01:
            print(f"  WARN NAV drew down {nav['max_drawdown'] * 100:.2f}% from a prior peak (inspect for PLP drain)")
        else:
            print("  NAV stable (no >1% drawdown)")

    # keeper liveness: a healthy keeper settles + flushes. Two brick shapes (M1): (a) a mid-run STALL —
    # the keeper flushed, then settlement outaged (a `keeper-stall` trace past the defer threshold); the
    # never-flushed check MISSES this. (b) never flushed at all despite HARD (non-transient) fails, once
    # enough time has elapsed for the shortest cadence to have produced an expiry (a transient RPC blip
    # before the first expiry must NOT false-FAIL).
    keeper_flushes = sum(1 for r in recs if r.get("type") == "flush" and r.get("_actor") == "keeper")
    keeper_fails = [r for r in recs if r.get("type") == "fail" and r.get("_actor") == "keeper"]
    keeper_stalls = [r for r in recs if r.get("type") == "keeper-stall"]

    def _transient_tag(tag: str) -> bool:  # a transient RPC/history blip, not an operational brick
        return verdict.is_transient(tag)

    hard_keeper_fails = [r for r in keeper_fails if not _transient_tag(str(r.get("tag", "")))]
    ts_all = [r["ts"] for r in recs if r.get("ts")]
    elapsed_ms = (max(ts_all) - min(ts_all)) if len(ts_all) >= 2 else 0
    print(f"\nkeeper: {keeper_flushes} flush(es), {len(keeper_fails)} fail(s) "
          f"({len(hard_keeper_fails)} non-transient), {len(keeper_stalls)} stall(s)")
    stall_brick = len(keeper_stalls) > 0
    never_flushed_brick = (
        bool(hard_keeper_fails) and keeper_flushes == 0 and elapsed_ms > KEEPER_BRICK_MIN_ELAPSED_MS
    )
    stuck = stall_brick or never_flushed_brick
    if stuck:
        why = ("settlement STALLED after prior progress" if stall_brick
               else f"no successful flush in {elapsed_ms // 1000}s despite non-transient fails")
        print(f"  *** WARN: keeper settlement/LP lifecycle stuck — {why} ***")

    # Capacity: flush gas vs leverage-book size. Capacity profiles trace {type:"book", size}; join
    # that with the keeper flush gas to find the book
    # size at which the NAV calc can no longer be valued in one PTB. The flush deferral at the
    # breakpoint is the MEASUREMENT, not a bug, so it is excluded from the oracle below.
    nav_break: list[dict] = []
    books = sorted([r for r in recs if r.get("type") == "book" and "size" in r], key=lambda r: r.get("ts", 0))
    if books:
        # The wall is the per-tx COMPUTATION cap, NOT the gas budget: max_gas_computation_bucket =
        # 5,000,000 units (a protocol constant — verified identical on localnet/testnet/mainnet) x the
        # reference gas price. Localnet/testnet RGP 1000 -> 5e9 MIST; mainnet RGP 100 -> 5e8 MIST — but
        # the binding limit is the 5M UNITS of work, so the OOG book size is network-independent.
        # Compare the flush's COMPUTATION cost (compGas), not net gas (gasOf folds in storage/rebate,
        # which the computation cap ignores). COMP_CAP is the module-level per-tx computation cap.
        succ = sorted(
            [r for r in recs if r.get("type") == "flush" and r.get("_actor") == "keeper" and r.get("ts")
             and (r.get("compGas") or r.get("gas"))],
            key=lambda r: r["ts"],
        )

        def _book_at(ts: int) -> int:
            sz = 0
            for b in books:
                if b.get("ts", 0) <= ts:
                    sz = b["size"]
                else:
                    break
            return sz

        def _comp(r: dict) -> int:
            return int(r.get("compGas") or r.get("gas") or 0)  # computation cost (fallback to net gas)

        pts = [(s, c) for s, c in ((_book_at(f["ts"]), _comp(f)) for f in succ) if s > 0]
        peak = books[-1]["size"]
        print(f"\ncapacity — flush computation vs leverage-book size (peak book {peak}):")
        if len(pts) >= 2:
            lo, hi = min(pts, key=lambda p: p[0]), max(pts, key=lambda p: p[0])
            print(f"  {lo[0]} orders -> {lo[1]:,} comp  ...  {hi[0]} orders -> {hi[1]:,} comp")
            n = len(pts)
            sx = sum(s for s, _ in pts)
            sy = sum(c for _, c in pts)
            denom = n * sum(s * s for s, _ in pts) - sx * sx
            if denom:
                slope = (n * sum(s * c for s, c in pts) - sx * sy) / denom
                base = (sy - slope * sx) / n
                cross = int((COMP_CAP - base) / slope) if slope > 0 else 0
                print(f"  ~{int(slope):,} comp/order (+{int(base):,} base) -> hits the {COMP_CAP:,} computation cap at ~{cross:,} orders")
        else:
            print("  (only one flush at a non-empty book — run longer to grow the curve)")
        max_ok = max((s for s, _ in pts), default=0)
        max_c = max((c for _, c in pts), default=0)
        # A real NAV breakpoint = flush computation approached the cap, THEN the flush OOG'd. A deferral
        # while computation is far below the cap is an ordinary settlement race (pricing:4 etc., already
        # an expected guard), NOT the breakpoint — so only treat late fails as the break near the cap.
        near_cap = max_c > COMP_CAP * 0.5

        # Only a GAS-EXHAUSTION keeper fail near the cap is the capacity breakpoint; a module:code
        # invariant abort at the wall is a real bug and MUST reach the oracle (don't mask it as _navbreak).
        def _is_gas_oog(f: dict) -> bool:
            t = str(f.get("tag", ""))
            return "InsufficientGas" in t or "OUT_OF_GAS" in t or "computation" in t.lower()

        nav_break = [f for f in keeper_fails if _book_at(f.get("ts", 0)) >= max_ok and _is_gas_oog(f)] if (near_cap and max_ok > 0) else []
        for f in nav_break:
            f["_navbreak"] = True
        pct = f"{max_c / COMP_CAP * 100:.0f}%"
        if nav_break:
            print(f"  EMPIRICAL breakpoint: flush last valued ~{max_ok} orders (~{max_c:,} comp = {pct} of the {COMP_CAP:,} cap), then OOG'd — below the 5000 per-market cap")
        elif peak >= 4900:
            print(f"  flush valued the full book ({peak}) at ~{max_c:,} comp ({pct} of the {COMP_CAP:,} cap) — the 5000 order cap binds, not NAV computation")
        else:
            print(f"  no breakpoint (computation peaked at {max_c:,} = {pct} of the {COMP_CAP:,} cap); grow the book further for the empirical limit")

    # Batched transaction measurements shared by the capacity and cleanup families.
    batch_samples, batch_oogs = measurements.batch_computation(recs)
    if batch_samples or batch_oogs:
        print("\nbatched mint computation:")
        for profile, size, mean, sample_count in batch_samples:
            print(
                f"  {profile:>12} N={size:>3}: {mean:>14,} comp "
                f"({mean // size:>12,}/mint, samples={sample_count})"
            )
        if batch_oogs:
            print(
                "  OOG profiles/sizes: "
                + ", ".join(f"{profile}:N={size}" for profile, size in batch_oogs)
            )

    # Bug oracle (code-aware; tags are module:code). Capacity breakpoint deferrals are excluded above.
    fails = [r for r in recs if r.get("type") == "fail" and not r.get("_navbreak")]
    expected, transient, flagged = verdict.classify_failures(fails)
    # B — per-strategy declared terminal wall (the `expect` trace record). A stress strategy's declared
    # wall is EXPECTED for THIS run only (not a bug oracle hit): the object-cache limit bricks a normal
    # flush, so it must never be a global whitelist. A declared wall NEVER reached fails the run as
    # VACUOUS (a stress that did not stress — Antithesis "sometimes" reachability).
    declared = verdict.declared_terminals(recs)
    if declared:
        vm_msgs = list(verdict.vm_errors(inst))  # the run's real VM-error summaries (framework aborts' true cause)
        undeclared_vm = [m for m in vm_msgs if not any(d in m for d in declared)]
        package_modules = verdict.GUARD_MODULES | verdict.INVARIANT_MODULES

        def _declared_package_abort(tag: str) -> bool:
            module = tag.split(":", 1)[0]
            return (
                bool(verdict.MOVE_ABORT.match(tag))
                and module in package_modules
                and any(d in tag for d in declared)
            )

        reached = {d for d in declared
                   if any(d in m for m in vm_msgs)
                   or any(_declared_package_abort(t) and d in t for t in flagged + list(expected))}
        kept: list[str] = []
        for t in flagged:
            if _declared_package_abort(t):
                expected[f"declared:{t[:32]}"] += 1            # package abort itself names a declared wall
            elif t.split(":", 1)[0] not in package_modules and reached and not undeclared_vm:
                expected["declared-wall (framework)"] += 1     # framework tag whose real cause IS a declared VM wall
            else:
                kept.append(t)                                 # a clean module:code abort, or an UNdeclared framework error
        flagged = kept
        for d in declared:
            if d not in reached:
                flagged.append(f"VACUOUS: declared wall '{d[:48]}' never reached")
    print(f"\nfailures: {len(fails)} ({sum(expected.values())} expected guards, {sum(transient.values())} transient)")
    if expected:
        print("  expected guards:", dict(expected.most_common(6)))
    if transient:
        print("  transient:", dict(transient.most_common(6)))
    if flagged:
        print(f"  *** BUG ORACLE: {len(flagged)} invariant/non-package abort(s) ***")
        for tag, n in Counter(flagged).most_common(10):
            print(f"     {n}x  {tag}")
        # A framework-level tag (dynamic_field::borrow_child_object etc.) names only the framework fn.
        # Surface the dry-run's executionErrorSource from the saved artifacts — the plain-English VM
        # cause the tag hides (e.g. "Object runtime cached objects limit (1000 entries) reached").
        for msg, n in verdict.vm_errors(inst).most_common(6):
            print(f"       -> {n}x  {msg}")
    else:
        print("  bug oracle clean (no invariant/non-package aborts)")

    # adversarial probes: rejection-path coverage (guards firing is the healthy outcome).
    adv_rejected = sum(1 for r in recs if r.get("type") == "fail" and r.get("adversarial"))
    adv_accepted = [r for r in recs if r.get("type") == "adversarial-accepted"]
    if adv_rejected or adv_accepted:
        print(f"\nadversarial probes: {adv_rejected} rejected (guards fired), {len(adv_accepted)} wrongly accepted")
        if adv_accepted:
            print(f"  *** {len(adv_accepted)} adversarial order(s) WRONGLY ACCEPTED — guard gap ***")
            for mode, n in Counter(r.get("mode") for r in adv_accepted).most_common():
                print(f"     {n}x  {mode}")

    signals = list(flagged)
    signals += [f"adversarial-accepted:{r.get('mode')}" for r in adv_accepted]
    if stuck:
        signals.append("keeper-stuck")  # (1) a bricked settlement/LP lifecycle must fail the run
    if any(r.get("fatal") for r in recs):
        signals.append("fatal-crash")  # (2) a top-level actor crash (fatal trace) must fail the run
        print("  *** BUG ORACLE: fatal actor crash (setup or main loop) — see the fatal trace ***")
    if not any(r.get("_actor") == "keeper" for r in recs):
        signals.append("no-keeper-trace")  # keeper never started / crashed in setup
        print("  *** WARN: no keeper trace — keeper never started or crashed in setup ***")
    nav_note = f"NAV ${flushes[-1]['poolValue']:,.0f}" if flushes else "no flush"
    print(f"\nsummary [{label}]: {len(recs)} ops, {len(fails)} fail(s) ({len(flagged)} flagged), {len(adv_accepted)} adv-accepted, {nav_note}")
    return signals


def analyze(instances: list[str] | None = None, expect: list[str] | None = None) -> int:
    # `instances`: the exact dirs to analyze — a campaign/run scopes to ITS OWN dirs so an OLD
    # retained trace can't fail (or falsely satisfy `expect` for) the current verdict. None =
    # every retained instance dir (the explicit "aggregate everything" mode of a bare `analyze`).
    # `expect` (a campaign's strategy names) flags any that produced NO trace among `instances`
    # — a fully-dead localnet is otherwise silently absent from the verdict.
    insts = [Path(p) for p in instances] if instances else _instances()
    insts = [i for i in insts if (i / "trace").exists()]
    signals: list[str] = []
    if expect:
        present = [i.name for i in insts]
        for name in expect:
            if not any(n.startswith(f"{name}-") for n in present):
                signals.append(f"missing-trace:{name}")
                print(f"*** WARN: strategy '{name}' produced no trace — its localnet/keeper never started ***")
    if not insts:
        print("no trace found (run `python3 -m harness live --traders N` first)")
        return 1
    if len(insts) > 1:
        print(f"aggregating {len(insts)} instance(s)\n")
    for inst in sorted(insts, key=lambda d: d.name):
        signals += _analyze_one(inst)
        print()
    if len(insts) > 1 or expect:
        print(f"=== aggregate verdict over {len(insts)} instance(s): {'FAIL' if signals else 'clean'} ===")
    # Non-zero exit so background/autonomous runs have a programmatic failure signal.
    return 1 if signals else 0

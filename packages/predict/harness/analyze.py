"""Analyze a harness run's JSONL trace(s).

Reports op counts, gas-vs-moneyness, the pool-NAV trend (drain heuristic), keeper liveness,
and the BUG ORACLE. Classification is code-aware: a Move abort from an INVARIANT module
(arithmetic / accounting / index / custody) or a non-package module is FLAGGED as a likely
contract bug; aborts from GUARD modules are expected business preconditions; submission /
external-data (HTTP, rate-limit) failures are transient.

Exit status is non-zero when the oracle flags an abort, an adversarial probe was wrongly
accepted, or an instance has no keeper trace — so background/autonomous runs have a
programmatic signal, not just the banner. Aggregates across ALL instance dirs of a run, so
parallel up-many is not single-instance blind.
"""

from __future__ import annotations

import json
import re
from collections import Counter, defaultdict
from pathlib import Path

from . import config

# GUARD modules: a Move abort here is an EXPECTED business precondition (admission, expiry,
# freshness, slippage, balance, oracle binding) that a trader/keeper legitimately trips.
GUARD_MODULES = {
    "pricing", "expiry_market", "strike_exposure", "strike_exposure_config",
    "predict_account", "pricing_config", "config_constants", "protocol_config",
    "registry", "market_manager", "pyth_feed", "block_scholes_spot_feed",
    "block_scholes_forward_feed", "block_scholes_svi_feed",
}
# INVARIANT modules: arithmetic / accounting / index / custody. A healthy run NEVER aborts
# here, so a hit is a likely contract bug and is flagged regardless of code. (These were
# previously swallowed because classification keyed on the module name only; e.g. math:3
# EExpOverflow, i64:0 EZeroDivisor, lp_book EInvalidDrainMark, strike_payout_tree
# EInsufficientPayoutTerms.)
INVARIANT_MODULES = {
    "math", "i64", "plp", "pool_accounting", "strike_payout_tree", "lp_book",
    "expiry_cash", "liquidation_book", "range_codec", "account", "account_registry",
}
# Mixed modules hold genuine invariants AND expected business preconditions, so these specific
# codes are whitelisted as expected (checked BEFORE the module-level INVARIANT rule):
#   liquidation_book:4 = EMaxActiveLeveragedOrders (per-market 5000 leveraged-order cap)
#   strike_payout_tree:1 = EMaxPayoutTreeNodes (per-market 1000 payout-boundary-node cap) — the same
#     mint-time admission-cap class as liquidation_book:4 (hitting it is a full market, not a bug).
#   lp_book:0..3 = ERequestNotFound / EBelowMinSupplyRequest / EBelowMinWithdrawRequest / ENotRequestOwner
# (lp_book:4 EInvalidDrainMark + liquidation_book:0..3 index invariants stay FLAGGED.)
EXPECTED_CODES = {
    "liquidation_book:4",
    "strike_payout_tree:1",
    "lp_book:0", "lp_book:1", "lp_book:2", "lp_book:3",
}
# Submission-level / external-data failures — NOT contract bugs (consensus, network, and the
# Pyth-history endpoint rate-limiting or not-yet-having the exact-ts observation). Matched on
# STRUCTURED source markers (http / rpc / pyth history / fetch / …), NOT bare numeric codes: an
# execution or gas failure whose message merely contains "500" must stay flagged, and the real
# HTTP transients carry "pyth history HTTP <code>" / "fetch" anyway.
_TRANSIENT = (
    "rpc", "timeout", "network", "fetch", "econn", "socket", "validators",
    "non-retriable", "equivocat", "rejected as invalid",
    "http", "rate limit", "pyth history", "no price for feed", "expected ts",
)
# A Move abort tag is `module:code` (lowercase module, numeric code). Matched so a numeric abort
# code (e.g. dynamic_field:500) is never mistaken for an HTTP status by the _TRANSIENT substrings.
_MOVE_ABORT = re.compile(r"^[a-z_][a-z0-9_]*:\d+$")

# The Sui per-tx COMPUTATION cap: max_gas_computation_bucket = 5,000,000 units (a protocol constant,
# verified identical localnet/testnet/mainnet) x the reference gas price. Localnet/testnet RGP 1000 ->
# 5e9 MIST; mainnet RGP 100 -> 5e8 MIST — but the binding limit is the 5M UNITS of work, so an OOG book
# size is network-independent. Both the nav-stress and mint-batch sections compare compGas against this.
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


def _classify(fails: list[dict]) -> tuple[Counter[str], Counter[str], list[str]]:
    expected: Counter[str] = Counter()
    transient: Counter[str] = Counter()
    flagged: list[str] = []
    for r in fails:
        tag = str(r.get("tag", ""))
        mod = tag.split(":")[0] if ":" in tag else ""
        if tag in EXPECTED_CODES:
            expected[tag] += 1  # a business precondition inside an otherwise-invariant module
        elif mod in INVARIANT_MODULES:
            flagged.append(tag)  # arithmetic/accounting/index/custody invariant -> bug
        elif mod in GUARD_MODULES:
            expected[tag] += 1
        elif _MOVE_ABORT.match(tag):
            # a `module:code` abort from an unknown/framework module (e.g. dynamic_field) -> bug.
            # Checked BEFORE _TRANSIENT so a numeric abort code is never read as an HTTP status.
            flagged.append(tag)
        elif any(t in tag.lower() for t in _TRANSIENT):
            transient[tag[:40]] += 1
        else:
            flagged.append(tag)  # non-package / framework / unknown abort -> bug
    return expected, transient, flagged


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
    mints = [r for r in recs if r.get("type") == "mint" and "gas" in r]
    if mints:
        buckets: dict[str, list[int]] = defaultdict(list)
        for r in mints:
            d = abs(r.get("moneyness", 1.0) - 1.0)
            key = "ATM (<0.5%)" if d < 0.005 else "near (0.5-2%)" if d < 0.02 else "far (2-5%)" if d < 0.05 else "deep (>5%)"
            buckets[key].append(r["gas"])
        print("\ngas vs moneyness (mint):")
        for k in ("ATM (<0.5%)", "near (0.5-2%)", "far (2-5%)", "deep (>5%)"):
            gs = buckets.get(k)
            if gs:
                print(f"  {k:14} n={len(gs):>3}  avg={sum(gs) // len(gs):>11,} gas")

    # pool NAV trend (flushes) -> drain heuristic.
    flushes = sorted((r for r in recs if r.get("type") == "flush" and r.get("poolValue")), key=lambda r: r["ts"])
    if flushes:
        navs = [r["poolValue"] for r in flushes]
        print(f"\npool NAV (flush, n={len(navs)}): first=${navs[0]:,.0f} last=${navs[-1]:,.0f} min=${min(navs):,.0f} max=${max(navs):,.0f}")
        if min(navs) < max(navs) * 0.99:
            print(f"  WARN NAV dipped {((max(navs) - min(navs)) / max(navs) * 100):.2f}% below peak (inspect for PLP drain)")
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
        return not _MOVE_ABORT.match(tag) and any(t in tag.lower() for t in _TRANSIENT)

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

    # NAV stress: flush gas vs leverage-book size. The nav-stress strategy grows a leveraged book in
    # ONE market (tracing {type:"book", size}); join that with the keeper flush gas to find the book
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
        print(f"\nNAV stress — flush computation vs leverage-book size (peak book {peak}):")
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

        # Only a GAS-EXHAUSTION keeper fail near the cap is the nav-stress breakpoint; a module:code
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

    # mint-batch: the #cap-mintbatch differential (see mintBatch.ts). A batched leveraged mint amplifies
    # the per-op liquidation scan vs standalone, but WHY is unproven. cost(N) in the sweep is confounded
    # (the book grows across it), so the DISCRIMINATOR at a saturated book is the clean mechanism test:
    # (AB-A) vs S = do prior NON-liq-book commands amplify?  (BB/K) vs S = do prior LIQ-BOOK writes amplify?
    batches = [r for r in recs if r.get("type") == "mintBatch"]
    if batches:
        def _by(kind: str) -> dict[int, tuple[int, int]]:  # n -> (mean compGas, mean book-before)
            g: dict[int, list[int]] = defaultdict(list)
            bk: dict[int, list[int]] = defaultdict(list)
            for r in batches:
                if r.get("kind") == kind and not r.get("oog") and r.get("compGas"):
                    g[int(r["n"])].append(int(r["compGas"]))
                    bk[int(r["n"])].append(int(r.get("book", 0)))
            return {n: (sum(v) // len(v), sum(bk[n]) // len(bk[n])) for n, v in g.items()}

        sweep = _by("sweep")
        print("\nmint-batch — batched leveraged mint computation vs batch size N (book = liq orders before):")
        if sweep:
            xs = sorted(sweep)
            for n in xs:
                c, bk = sweep[n]
                print(f"  N={n:>3} (book~{bk:>4}): {c:>14,} comp  ({c // n:>12,}/mint)")
            per = [sweep[n][0] // n for n in xs]
            if len(xs) >= 3 and per[0] > 0:
                growth = per[-1] / per[0]
                shape = ("SUPER-LINEAR: per-mint grows with N -> cost accumulates within the PTB"
                         if growth > 1.5 else "~linear: fixed per-mint cost")
                print(f"  per-mint {per[0]:,} (N={xs[0]}) -> {per[-1]:,} (N={xs[-1]}) = {growth:.1f}x  [{shape}]")
                print("  NOTE: the sweep confounds N with book growth; the discriminator below is the clean test.")
        oogs = sorted({int(r["n"]) for r in batches if r.get("oog")})
        if oogs:
            print(f"  OOG at N in {oogs} — the atomic-batch ceiling (OOG wall = min(SIM_GAS_BUDGET, {COMP_CAP:,} computation cap); set SIM_GAS_BUDGET > {COMP_CAP:,} so the wall is the cap, not the budget)")

        # discriminator at a saturated book (after the sweep, so every scan hits the 24-candidate cap and
        # +-1 book is noise). lev1 (1x) mints never touch the liq book, so AB-A is a leveraged mint's cost
        # with NO prior liq-book writes; BB/K is one with full prior liq-book writes; S is standalone.
        S, A, AB, BB = _by("disc_std").get(1), _by("disc_lev1").get(20), _by("disc_prefix").get(21), _by("disc_lvg").get(20)
        if S and A and AB:
            s = S[0]
            in_prefix = AB[0] - A[0]
            print(f"\n  discriminator (saturated book~{S[1]}): does a leveraged mint's cost need prior LIQ-BOOK writes?")
            print(f"    S   standalone leveraged                             = {s:,} comp")
            print(f"    AB-A  leveraged after 20x lev1 (NO prior liq writes) = {in_prefix:,} comp")
            r1 = in_prefix / s if s else 0.0
            if BB:
                bb = BB[0] // 20
                r2 = bb / s if s else 0.0
                print(f"    BB/20 leveraged in a 20x-lvg batch (prior liq writes) = {bb:,} comp")
                print(f"    => (AB-A)/S = {r1:.1f}x , (BB/20)/S = {r2:.1f}x")
                if r1 < 1.5 <= r2:
                    print("    => VERDICT: amplification needs SAME-PTB LIQ-BOOK writes (dirtied dynamic-field hypothesis)")
                elif r1 >= 1.5:
                    print("    => VERDICT: a multi-command PTB alone amplifies, w/o prior liq writes (tx-metering hypothesis)")
                else:
                    print("    => VERDICT: no clear amplification in either arm — inspect the raw trace")
            else:
                print(f"    => (AB-A)/S = {r1:.1f}x  (BB missing — run longer)")

    # bug oracle (code-aware; tags are module:code). nav-stress breakpoint deferrals excluded (above).
    fails = [r for r in recs if r.get("type") == "fail" and not r.get("_navbreak")]
    expected, transient, flagged = _classify(fails)
    print(f"\nfailures: {len(fails)} ({sum(expected.values())} expected guards, {sum(transient.values())} transient)")
    if expected:
        print("  expected guards:", dict(expected.most_common(6)))
    if transient:
        print("  transient:", dict(transient.most_common(6)))
    if flagged:
        print(f"  *** BUG ORACLE: {len(flagged)} invariant/non-package abort(s) ***")
        for tag, n in Counter(flagged).most_common(10):
            print(f"     {n}x  {tag}")
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
        print("no trace found (run `harness up --traders N` first)")
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

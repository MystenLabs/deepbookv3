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
#   lp_book:0..3 = ERequestNotFound / EBelowMinSupplyRequest / EBelowMinWithdrawRequest / ENotRequestOwner
# (lp_book:4 EInvalidDrainMark + liquidation_book:0..3 index invariants stay FLAGGED.)
EXPECTED_CODES = {
    "liquidation_book:4",
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

    # keeper liveness: a healthy keeper settles + flushes; failing with no progress = stuck.
    keeper_flushes = sum(1 for r in recs if r.get("type") == "flush" and r.get("_actor") == "keeper")
    keeper_fails = [r for r in recs if r.get("type") == "fail" and r.get("_actor") == "keeper"]
    print(f"\nkeeper: {keeper_flushes} flush(es), {len(keeper_fails)} operational fail(s)")
    stuck = bool(keeper_fails) and keeper_flushes == 0
    if stuck:
        print("  *** WARN: keeper failing with no successful flush — settlement/LP lifecycle stuck ***")

    # NAV stress: flush gas vs leverage-book size. The nav-stress strategy grows a leveraged book in
    # ONE market (tracing {type:"book", size}); join that with the keeper flush gas to find the book
    # size at which the NAV calc can no longer be valued in one PTB. The flush deferral at the
    # breakpoint is the MEASUREMENT, not a bug, so it is excluded from the oracle below.
    nav_break: list[dict] = []
    books = sorted([r for r in recs if r.get("type") == "book" and "size" in r], key=lambda r: r.get("ts", 0))
    if books:
        SUI_MAX_GAS = 50_000_000_000  # Sui max tx gas budget (MIST) — the one-PTB ceiling
        succ = sorted(
            [r for r in recs if r.get("type") == "flush" and r.get("_actor") == "keeper" and "gas" in r and r.get("ts")],
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

        pts = [(s, g) for s, g in ((_book_at(f["ts"]), f["gas"]) for f in succ) if s > 0]
        peak = books[-1]["size"]
        print(f"\nNAV stress — flush gas vs leverage-book size (peak book {peak}):")
        if len(pts) >= 2:
            lo, hi = min(pts, key=lambda p: p[0]), max(pts, key=lambda p: p[0])
            print(f"  {lo[0]} orders -> {lo[1]:,} gas  ...  {hi[0]} orders -> {hi[1]:,} gas")
            n = len(pts)
            sx = sum(s for s, _ in pts)
            sy = sum(g for _, g in pts)
            denom = n * sum(s * s for s, _ in pts) - sx * sx
            if denom:
                slope = (n * sum(s * g for s, g in pts) - sx * sy) / denom
                base = (sy - slope * sx) / n
                cross = int((SUI_MAX_GAS - base) / slope) if slope > 0 else 0
                print(f"  ~{int(slope):,} gas/order (+{int(base):,} base) -> hits the {SUI_MAX_GAS:,} PTB cap at ~{cross:,} orders")
        else:
            print("  (only one flush at a non-empty book — run longer / raise SIM_GAS_BUDGET to grow the curve)")
        max_ok = max((s for s, _ in pts), default=0)
        max_gas = max((g for _, g in pts), default=0)
        # A real NAV-gas breakpoint = flush gas approached the cap, THEN the flush failed. A deferral
        # while gas is far below the cap is an ordinary settlement race (pricing:4 etc., already an
        # expected guard), NOT the breakpoint — so only treat late fails as the break once gas is near
        # the cap.
        gas_stressed = max_gas > SUI_MAX_GAS * 0.5
        nav_break = [f for f in keeper_fails if _book_at(f.get("ts", 0)) >= max_ok] if (gas_stressed and max_ok > 0) else []
        for f in nav_break:
            f["_navbreak"] = True
        if nav_break:
            print(f"  EMPIRICAL breakpoint: flush last valued ~{max_ok} orders (~{max_gas:,} gas ≈ the {SUI_MAX_GAS:,} cap), then deferred")
        elif peak >= 4900:
            print(f"  flush valued the full book ({peak}) at ~{max_gas:,} gas (< the {SUI_MAX_GAS:,} cap) — the 5000 order cap binds, not NAV gas")
        else:
            print(f"  no gas breakpoint (flush gas peaked at {max_gas:,}, far below the {SUI_MAX_GAS:,} cap); grow the book further for the empirical limit")

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

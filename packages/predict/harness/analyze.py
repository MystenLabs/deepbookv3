"""Analyze a harness run's JSONL trace.

Reads INSTANCE_DIR/trace/*.jsonl (one file per actor) and reports: op counts, gas vs
moneyness for mints, the pool-NAV trend (drain heuristic), and the bug oracle — any
transaction failure whose abort is NOT an expected guard from one of our packages
(arithmetic/framework errors are the headline bug signal).
"""

from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path

from . import config

# Modules in the Predict package closure whose aborts are EXPECTED business guards (a
# trader/keeper hitting a documented precondition), not bugs.
KNOWN_MODULES = {
    "pricing", "expiry_market", "strike_exposure", "strike_payout_tree", "liquidation_book",
    "range_codec", "plp", "pool_accounting", "lp_book", "expiry_cash", "predict_account",
    "pricing_config", "strike_exposure_config", "config_constants", "protocol_config",
    "registry", "market_manager", "pyth_feed", "block_scholes_spot_feed",
    "block_scholes_forward_feed", "block_scholes_svi_feed", "account", "account_registry",
    "math", "i64",
}
# Submission-level failures (consensus/equivocation/network) — NOT contract bugs.
_TRANSIENT = ("rpc", "timeout", "network", "fetch", "econn", "socket", "validators", "non-retriable", "equivocat", "rejected as invalid")


def _latest_instance() -> Path | None:
    if not config.INSTANCES_DIR.exists():
        return None
    dirs = [d for d in config.INSTANCES_DIR.iterdir() if (d / "trace").exists()]
    return max(dirs, key=lambda d: d.stat().st_mtime) if dirs else None


def _load(trace_dir: Path) -> list[dict]:
    records: list[dict] = []
    for f in sorted(trace_dir.glob("*.jsonl")):
        for line in f.read_text().splitlines():
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return records


def analyze(instance: str | None = None) -> int:
    inst = Path(instance) if instance else _latest_instance()
    if not inst or not (inst / "trace").exists():
        print("no trace found (run `harness up --traders N` first)")
        return 1
    recs = _load(inst / "trace")
    print(f"=== trace: {inst.name} ({len(recs)} ops) ===\n")

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

    # bug oracle.
    fails = [r for r in recs if r.get("type") == "fail"]
    expected: Counter[str] = Counter()
    transient: Counter[str] = Counter()
    flagged: list[str] = []
    for r in fails:
        tag = str(r.get("tag", ""))
        mod = tag.split(":")[0]
        if ":" in tag and mod in KNOWN_MODULES:
            expected[tag] += 1
        elif any(t in tag.lower() for t in _TRANSIENT):
            transient[tag[:40]] += 1
        else:
            flagged.append(tag)
    print(f"\nfailures: {len(fails)} ({sum(expected.values())} expected guards, {sum(transient.values())} transient)")
    if expected:
        print("  expected guards:", dict(expected.most_common(6)))
    if flagged:
        print(f"  *** BUG ORACLE: {len(flagged)} non-package abort(s) ***")
        for tag, n in Counter(flagged).most_common(10):
            print(f"     {n}x  {tag}")
    else:
        print("  bug oracle clean (no non-package aborts)")

    # adversarial probes: rejection-path coverage (guards firing is the healthy outcome).
    adv_rejected = sum(1 for r in recs if r.get("type") == "fail" and r.get("adversarial"))
    adv_accepted = [r for r in recs if r.get("type") == "adversarial-accepted"]
    if adv_rejected or adv_accepted:
        print(f"\nadversarial probes: {adv_rejected} rejected (guards fired), {len(adv_accepted)} wrongly accepted")
        if adv_accepted:
            print(f"  *** {len(adv_accepted)} adversarial order(s) WRONGLY ACCEPTED — guard gap ***")
            for mode, n in Counter(r.get("mode") for r in adv_accepted).most_common():
                print(f"     {n}x  {mode}")
    return 0

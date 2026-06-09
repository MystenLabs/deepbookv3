"""Regenerate .redesign/COVERAGE_MATRIX.md for the predict + predict_math packages.

Run from the repo root: python3 .redesign/gen_coverage_matrix.py

Declared scan: `const E<Name>: u64 =` in packages/{predict,predict_math}/sources.
Covered scan:  `abort_code = <module>::E<Name>` in packages/{predict,predict_math}/tests.
Constants are module-qualified (names like EZeroSpot/EPackageVersionDisabled repeat
across modules and are counted per module).
"""

import os, re, glob, collections, subprocess

PKGS = [
    ("packages/predict", "deepbook_predict"),
    ("packages/predict_math", "predict_math"),
]

decl = collections.defaultdict(list)  # mod -> [(const, relpath, line)]
for pkg, addr in PKGS:
    for f in glob.glob(pkg + "/sources/**/*.move", recursive=True):
        txt = open(f).read()
        m = re.search(r"^module\s+" + addr + r"::([A-Za-z0-9_]+)\s*;", txt, re.M)
        mod = m.group(1) if m else os.path.basename(f)[:-5]
        for i, line in enumerate(txt.splitlines(), 1):
            cm = re.match(r"\s*const\s+(E[A-Za-z0-9]+)\s*:\s*u64\s*=", line)
            if cm:
                decl[mod].append((cm.group(1), f, i))

covered = collections.defaultdict(list)  # (mod, const) -> [test_fn]
for pkg, addr in PKGS:
    for f in glob.glob(pkg + "/tests/**/*.move", recursive=True):
        lines = open(f).read().splitlines()
        for i, line in enumerate(lines):
            am = re.search(r"abort_code\s*=\s*([A-Za-z0-9_]+)::(E[A-Za-z0-9]+)", line)
            if am:
                mod, const = am.group(1), am.group(2)
                fn = "?"
                for j in range(i, min(i + 5, len(lines))):
                    fm = re.search(r"\bfun\s+([A-Za-z0-9_]+)", lines[j])
                    if fm:
                        fn = fm.group(1)
                        break
                covered[(mod, const)].append(fn)

# Priority band per module (plan §6/§8, adapted to this repo's module set).
BAND = {
    "expiry_market": "P0",
    "market_oracle": "P1", "pyth_source": "P1", "settlement_state": "P1",
    "pricing": "P1", "plp": "P1", "incentive": "P1", "order": "P1",
    "registry": "P1", "builder_code": "P1", "predict_manager": "P1",
    "strike_exposure": "P2", "liquidation_book": "P2", "strike_nav_matrix": "P2",
    "pool_accounting": "P2", "strike_grid": "P2", "strike_payout_tree": "P2",
    "ewma": "P2", "math": "P2", "i64": "P2", "expiry_cash": "P2",
    "config_constants": "P3", "protocol_config": "P3",
    "strike_exposure_config": "P3", "market_oracle_config": "P3",
    "pricing_config": "P3", "ewma_config": "P3", "stake_config": "P3",
    "expiry_cash_config": "P3",
}

total = sum(len(v) for v in decl.values())
cov = sum(1 for mod in decl for (c, _, _) in decl[mod] if covered.get((mod, c)))

band_unc = collections.Counter()
for mod in decl:
    for (c, _, _) in decl[mod]:
        if not covered.get((mod, c)):
            band_unc[BAND.get(mod, "P2")] += 1

H = []
H.append("# Predict Error-Constant Coverage Matrix")
H.append("")
H.append("> **Audit artifact + Phase-2 worklist.** Every `const E*` declared in")
H.append("> `packages/predict/sources/**` and `packages/predict_math/sources/**`, whether an")
H.append("> `expected_failure` test triggers it, and the covering test fn. Module-qualified.")
H.append("")
H.append("**Regenerate:** `python3 .redesign/gen_coverage_matrix.py` (from the repo root).")
H.append("")
H.append(f"## Summary — {cov}/{total} covered, {total - cov} uncovered")
H.append("")
H.append("| Priority band | Uncovered |")
H.append("|---|---|")
for b in ["P0", "P1", "P2", "P3"]:
    H.append(f"| {b} | {band_unc.get(b, 0)} |")
H.append("")
H.append("Priority bands:")
H.append("- **P0** — `expiry_market` public-flow gates + the invariant-level hot-flow pass.")
H.append("- **P1** — economic / lifecycle / auth error paths: oracle, pyth, pricing, plp, incentive, order, registry, manager.")
H.append("- **P2** — strike-index internals + accounting leaves + math.")
H.append("- **P3** — config-bounds envelopes (trivial-to-trigger, lowest blast radius).")
H.append("")
H.append("A constant that is a genuinely-unreachable defensive invariant is marked")
H.append("`DEFENSIVE` with the reason — no fabricated path, no test-only source seam added to reach it.")
H.append("")

for b in ["P0", "P1", "P2", "P3"]:
    mods = sorted([m for m in decl if BAND.get(m, "P2") == b and decl[m]])
    if not mods:
        continue
    H.append(f"## {b}")
    for mod in mods:
        consts = decl[mod]
        nc = sum(1 for (c, _, _) in consts if covered.get((mod, c)))
        H.append("")
        H.append(f"### `{mod}` — {nc}/{len(consts)}")
        H.append("| Error const | Covered | Covering test |")
        H.append("|---|---|---|")
        for (c, rel, ln) in consts:
            hits = covered.get((mod, c))
            if hits:
                H.append(f"| `{c}` | ✅ | " + "; ".join(f"`{fn}`" for fn in sorted(set(hits))) + " |")
            else:
                H.append(f"| `{c}` | ❌ | — |")
    H.append("")

# Regression cross-check vs main (name-level: which constants had a covering
# test on main but have none here, and still exist in HEAD sources).
try:
    main_tested = set(
        re.sub(r".*::", "", m)
        for m in subprocess.run(
            ["git", "grep", "-hoE", r"abort_code = [A-Za-z0-9_:]+::(E[A-Za-z0-9]+)",
             "main", "--", "packages/predict*/tests/**"],
            capture_output=True, text=True,
        ).stdout.split()
        if m.startswith("E") or "::" in m
    )
    head_tested_names = {c for (m, c) in covered}
    head_declared_names = {c for mod in decl for (c, _, _) in decl[mod]}
    regressions = sorted((main_tested & head_declared_names) - head_tested_names)
    H.append(f"## Regressions vs `main` — {len(regressions)} constants covered there, uncovered here")
    H.append("")
    H.append("Name-level (not module-qualified). These had `expected_failure` coverage in the granular")
    H.append("test files deleted during suite consolidation and still exist in HEAD sources:")
    H.append("")
    for r in regressions:
        H.append(f"- `{r}`")
    H.append("")
except Exception as e:  # git unavailable etc. — matrix still useful without this section
    H.append(f"_(regression cross-check skipped: {e})_")

open(".redesign/COVERAGE_MATRIX.md", "w").write("\n".join(H) + "\n")
print(f"WROTE .redesign/COVERAGE_MATRIX.md  ({cov}/{total} covered)")
print("Band uncovered:", dict(band_unc))

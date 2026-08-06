#!/usr/bin/env python3
"""Fails if a legacy Pyth entrypoint and its upgraded twin drift apart.

The legacy and upgraded surfaces have to be edited together, forever: the legacy
one takes `pyth::price_info::PriceInfoObject`, the upgraded one Pyth's upgraded
Core type, and both delegate to the same shared logic. Nothing in the compiler
ties them together, so adding a parameter to one and not the other compiles clean
and ships a surface that silently disagrees with itself.

The check is driven from the LEGACY side on purpose. An earlier version walked
the `*_upgraded.move` glob, which meant renaming or deleting an upgraded file
removed its legacy module from the check entirely and the run still reported
"passed" — a guard that protects nothing is worse than no guard, because it reads
as coverage. For the same reason there is a floor on the number of pairs found:
if the twins disappear wholesale, that is a failure, not a clean run.

Two twin conventions are supported:
  * separate module — `pool_proxy.move` / `pool_proxy_upgraded.move`, same fn name
    (`deepbook_margin`, where Move's module-scoped field access forces the split);
  * same module — `liquidate_base` / `liquidate_base_upgraded`
    (`margin_liquidation`, which has no such barrier).
"""
import re
import sys
import pathlib

# Legacy public fns that intentionally have no twin. Each entry must also have an
# aborting body — an exemption that is only a name would let a real entrypoint
# inherit it, so the body is re-checked below rather than trusted.
ALLOWED_UNTWINNED = {
    # deprecated: body is `abort EDeprecatedUseV2`, so a twin adds a second dead entry
    ("deepbook_margin", "margin_manager", "execute_conditional_orders"),
}

# Per-package floor on the number of pairs. If a count drops below its entry, twins
# were removed or discovery broke — either way the run must fail rather than silently
# check less. A package is only checked once it has *started* migrating, i.e. once its
# manifest declares the upgraded Pyth dependency; before that, having no twins is the
# correct state and not a failure. That matters because the two packages migrate in
# separate PRs, and the earlier one must not be red for work the later one does.
MIN_EXPECTED_PAIRS = {
    'deepbook_margin': 20,
    'margin_liquidation': 2,
}
UPGRADED_DEP = 'pyth_upgraded'

FN = re.compile(r'^public(?: entry)? fun (\w+)(<[^>]*>)?\s*\(', re.M)


def params(src: str, name: str) -> str | None:
    """Normalised parameter list of `name`, or None if absent."""
    m = re.search(r'^public(?: entry)? fun ' + re.escape(name) + r'(<[^>]*>)?\s*\(', src, re.M)
    if not m:
        return None
    i = src.index('(', m.start())
    depth, j = 0, i
    while j < len(src):
        if src[j] == '(':
            depth += 1
        elif src[j] == ')':
            depth -= 1
            if depth == 0:
                break
        j += 1
    text = src[i + 1:j].replace('PriceInfoObjectUpgraded', 'PriceInfoObject')
    return re.sub(r'\s+', ' ', text).strip()


def body(src: str, name: str) -> str:
    m = re.search(r'^public(?: entry)? fun ' + re.escape(name) + r'\b', src, re.M)
    if not m:
        return ''
    start = src.index('{', m.start())
    depth, j = 0, start
    while j < len(src):
        if src[j] == '{':
            depth += 1
        elif src[j] == '}':
            depth -= 1
            if depth == 0:
                break
        j += 1
    return src[start:j]


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[2] / 'packages'
    problems: list[str] = []
    pairs: dict[str, int] = {}

    migrated = set()
    for manifest in sorted(root.glob('*/Move.toml')):
        if re.search(rf'^\s*{UPGRADED_DEP}\s*=', manifest.read_text(), re.M):
            migrated.add(manifest.parent.name)

    legacy_files = [
        p for p in sorted(root.glob('*/sources/**/*.move'))
        if not p.name.endswith('_upgraded.move')
    ]

    for legacy_path in legacy_files:
        pkg = legacy_path.parts[legacy_path.parts.index('packages') + 1]
        if pkg not in migrated:
            continue
        stem = legacy_path.stem
        legacy = legacy_path.read_text()
        upg_path = legacy_path.with_name(f'{stem}_upgraded.move')
        upg = upg_path.read_text() if upg_path.exists() else None

        for m in FN.finditer(legacy):
            fn = m.group(1)
            if fn.endswith('_upgraded'):
                continue
            sig = params(legacy, fn)
            if sig is None or 'PriceInfoObject' not in sig:
                continue

            same_module = params(legacy, f'{fn}_upgraded')
            cross_module = params(upg, fn) if upg else None

            if same_module is not None and cross_module is not None:
                problems.append(
                    f"{pkg}::{stem}::{fn} has twins in BOTH conventions — pick one")
            elif same_module is not None:
                pairs[pkg] = pairs.get(pkg, 0) + 1
                if same_module != sig:
                    problems.append(
                        f"{pkg}::{stem}::{fn} / {fn}_upgraded: parameter lists differ\n"
                        f"      legacy:   {sig}\n      upgraded: {same_module}")
            elif cross_module is not None:
                pairs[pkg] = pairs.get(pkg, 0) + 1
                if cross_module != sig:
                    problems.append(
                        f"{pkg}::{fn}: parameter lists differ between "
                        f"{legacy_path.name} and {upg_path.name}\n"
                        f"      legacy:   {sig}\n      upgraded: {cross_module}")
            elif (pkg, stem, fn) in ALLOWED_UNTWINNED:
                if 'abort' not in body(legacy, fn):
                    problems.append(
                        f"{pkg}::{stem}::{fn} is allow-listed as untwinned, but its body "
                        f"no longer aborts — it needs a real upgraded twin")
            else:
                problems.append(
                    f"{pkg}::{stem}::{fn} takes a Pyth feed but has no upgraded twin "
                    f"(expected {fn} in {upg_path.name}, or {fn}_upgraded beside it)")

    # Reverse direction: an upgraded entry with no legacy counterpart.
    for upg_path in sorted(root.glob('*/sources/**/*_upgraded.move')):
        pkg = upg_path.parts[upg_path.parts.index('packages') + 1]
        legacy_path = upg_path.with_name(upg_path.name.replace('_upgraded', ''))
        if not legacy_path.exists():
            problems.append(f"{pkg}::{upg_path.name}: no legacy counterpart")
            continue
        legacy = legacy_path.read_text()
        for m in FN.finditer(upg_path.read_text()):
            if params(legacy, m.group(1)) is None:
                problems.append(f"{pkg}::{upg_path.name}::{m.group(1)} has no legacy twin")

    for path in legacy_files:
        pkg = path.parts[path.parts.index('packages') + 1]
        src = path.read_text()
        for m in re.finditer(r'^public(?: entry)? fun (\w+)_upgraded\b', src, re.M):
            if params(src, m.group(1)) is None:
                problems.append(
                    f"{pkg}::{path.stem}::{m.group(1)}_upgraded has no `{m.group(1)}` twin")

    for pkg in sorted(migrated):
        found, floor = pairs.get(pkg, 0), MIN_EXPECTED_PAIRS.get(pkg, 1)
        if found < floor:
            problems.append(
                f"{pkg}: only {found} legacy/upgraded pairs found, expected at least "
                f"{floor}. Twins were removed, or a file was renamed out of the check's "
                f"reach — either way this run verified less than it should.")

    if problems:
        print("upgraded-twin parity check FAILED:\n")
        for p in problems:
            print(f"  - {p}")
        return 1
    summary = ", ".join(f"{k} {v}" for k, v in sorted(pairs.items())) or "no migrated packages"
    print(f"upgraded-twin parity check passed ({summary})")
    return 0


if __name__ == '__main__':
    sys.exit(main())

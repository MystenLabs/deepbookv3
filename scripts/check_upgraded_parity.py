#!/usr/bin/env python3
"""Fails if a legacy Pyth entrypoint and its upgraded twin drift apart.

The legacy and upgraded surfaces must be edited together, forever: the legacy one
takes `pyth::price_info::PriceInfoObject`, the upgraded one Pyth's upgraded Core
type, and both delegate to the same shared logic. Nothing in the compiler ties
them together, so adding a parameter to one and not the other compiles clean and
ships a surface that silently disagrees with itself.

Checks, per package:
  * every `public fun` in an `_upgraded` module has a same-named legacy twin;
  * every legacy `public fun` taking `&PriceInfoObject` has an upgraded twin;
  * the two parameter lists are identical once the oracle type is normalised.
"""
import re, sys, pathlib

# Legacy public fns that intentionally have no twin, with the reason.
ALLOWED_UNTWINNED = {
    # body is `abort EDeprecatedUseV2`; a twin would only add a second dead entry.
    ("margin_manager", "execute_conditional_orders"),
}

FN = re.compile(r'^public fun (\w+)(<[^>]*>)?\s*\(', re.M)


def signature(src: str, name: str) -> str | None:
    m = re.search(r'^public fun ' + re.escape(name) + r'(<[^>]*>)?\s*\(', src, re.M)
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
    params = src[i + 1:j]
    params = params.replace('PriceInfoObjectUpgraded', 'PriceInfoObject')
    return re.sub(r'\s+', ' ', params).strip()


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent / 'packages'
    problems: list[str] = []
    for upg_path in sorted(root.glob('*/sources/**/*_upgraded.move')):
        legacy_path = upg_path.with_name(upg_path.name.replace('_upgraded', ''))
        if not legacy_path.exists():
            problems.append(f"{upg_path}: no legacy counterpart {legacy_path.name}")
            continue
        upg, legacy = upg_path.read_text(), legacy_path.read_text()
        pkg = legacy_path.stem
        upg_fns = {m.group(1) for m in FN.finditer(upg)}
        legacy_fns = {m.group(1) for m in FN.finditer(legacy)}

        for fn in sorted(upg_fns - legacy_fns):
            problems.append(f"{upg_path.name}::{fn} has no legacy twin")

        for fn in sorted(legacy_fns):
            sig = signature(legacy, fn)
            if sig is None or 'PriceInfoObject' not in sig:
                continue
            if fn in upg_fns:
                if signature(upg, fn) != sig:
                    problems.append(
                        f"{fn}: parameter lists differ\n"
                        f"    legacy:   {sig}\n"
                        f"    upgraded: {signature(upg, fn)}")
            elif (pkg, fn) not in ALLOWED_UNTWINNED:
                problems.append(f"{legacy_path.name}::{fn} takes a Pyth feed but has no upgraded twin")

    # Same-module suffix convention (margin_liquidation).
    for path in sorted(root.glob('*/sources/**/*.move')):
        if path.name.endswith('_upgraded.move'):
            continue
        src = path.read_text()
        for m in re.finditer(r'^public fun (\w+)_upgraded(<[^>]*>)?\s*\(', src, re.M):
            base = m.group(1)
            if signature(src, base) is None:
                problems.append(f"{path.name}::{base}_upgraded has no `{base}` twin")
            elif signature(src, base) != signature(src, base + '_upgraded'):
                problems.append(
                    f"{base}/{base}_upgraded: parameter lists differ\n"
                    f"    legacy:   {signature(src, base)}\n"
                    f"    upgraded: {signature(src, base + '_upgraded')}")

    if problems:
        print("upgraded-twin parity check FAILED:\n")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("upgraded-twin parity check passed")
    return 0


if __name__ == '__main__':
    sys.exit(main())

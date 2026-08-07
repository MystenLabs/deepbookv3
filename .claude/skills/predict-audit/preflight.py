#!/usr/bin/env python3
"""Pre-run drift lint for the predict-audit skill — run in the MAIN loop as part of Step 1 (ground truth).

The primer's module map and the D-id ledger citations are the single point of failure for a run: every one
of the hundreds of subagents inherits them, so a path that went stale after a rework silently misleads the
whole fleet and nothing else detects it. This is a cheap, deterministic guard:

  1. MODULE-MAP DRIFT (FATAL) — every `foo/bar.move` path named in primer.md's module map must exist under
     packages/. Unambiguous and always resolvable from the tree, so a miss is a hard error.
  2. D-ID DRIFT (WARNING) — every D0NN id cited anywhere in the skill, including JSON fixtures consumed by
     its workflows, should resolve to an explicit entry in the committed design or response-policy register.
     A miss means the decision has no canonical record — a real gap to promote, but not a reason to block a
     run, so it warns rather than fails.

Usage:  python3 .claude/skills/predict-audit/preflight.py [REPO_ROOT]
Exits 1 only on FATAL module-map drift; D-id warnings print but keep exit 0.
"""
import os, re, sys, glob

SKILL = os.path.dirname(os.path.abspath(__file__))
PRIMER = os.path.join(SKILL, 'primer.md')


def check_module_map(root, errors, warnings):
    """Every `foo/bar.move` path named in primer.md's module map must exist under packages/. The map writes
    paths as `registry/registry.move`, `strike_exposure/index/strike_payout_tree.move`, etc. A bare
    `constants.move` with no directory is ambiguous across packages, so paths with a directory segment are
    hard-checked and bare names are only warned on."""
    # `file.move` is the literal placeholder in the report-format template (`Location: file.move:line(s)`),
    # not a real module — don't flag it.
    IGNORE = {'file.move'}
    primer = open(PRIMER, encoding='utf-8').read()
    move_tokens = set(re.findall(r'`?([A-Za-z_][A-Za-z0-9_/]*\.move)`?', primer)) - IGNORE
    packages = os.path.join(root, 'packages')
    for tok in sorted(move_tokens):
        hits = glob.glob(os.path.join(packages, '**', tok), recursive=True)
        if hits:
            continue
        if '/' in tok:
            errors.append(f"primer.md names a module path that does not exist under packages/: {tok}")
        else:
            warnings.append(f"primer.md names a bare module '{tok}' not found under packages/ (ambiguous — verify manually)")
    return len(move_tokens)


def check_dids(root, warnings):
    """Every D0NN cited anywhere in the skill SHOULD have an explicit canonical decision or policy entry, so
    a settled_ref the prompts lean on is real, not dangling. A miss is a WARNING, not fatal."""
    definition_sources = [
        (
            os.path.join(root, 'packages', 'predict', 'docs', 'design', 'decisions.md'),
            re.compile(r'^-\s+\*\*(D0\d\d)\s+—', re.MULTILINE),
        ),
        (
            os.path.join(root, 'packages', 'predict', 'predeploy', 'response-policies.md'),
            re.compile(r'^##\s+.*\((D0\d\d)\)\s*$', re.MULTILINE),
        ),
    ]
    defined = set()
    for p, pattern in definition_sources:
        try:
            defined.update(pattern.findall(open(p, encoding='utf-8', errors='replace').read()))
        except OSError:
            pass

    cited = {}  # d-id -> set of skill files citing it
    for path in glob.glob(os.path.join(SKILL, '**', '*'), recursive=True):
        if '__pycache__' in path or not os.path.isfile(path) or not path.endswith(('.md', '.js', '.py', '.json')):
            continue
        if os.path.abspath(path) == os.path.abspath(__file__):
            continue
        try:
            txt = open(path, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for did in re.findall(r'\bD0\d\d\b', txt):
            cited.setdefault(did, set()).add(os.path.relpath(path, SKILL))

    for did in sorted(cited):
        if did not in defined:
            where = ', '.join(sorted(cited[did]))
            warnings.append(f"D-id {did} is cited in the skill ({where}) but not in a canonical decision or policy register; promote it to packages/predict/docs/design/decisions.md or the matching predeploy register")
    return len(cited)


def main():
    # SKILL = <repo>/.claude/skills/predict-audit → three levels up is the repo root.
    root = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.abspath(os.path.join(SKILL, '..', '..', '..'))
    errors, warnings = [], []
    n_paths = check_module_map(root, errors, warnings)
    n_dids = check_dids(root, warnings)
    for w in warnings:
        print(f"⚠  {w}")
    for e in errors:
        print(f"⛔ {e}")
    if errors:
        print(f"\nPREFLIGHT FAILED — {len(errors)} FATAL module-map drift error(s). Fix primer.md before launching a run.")
        return 1
    print(f"preflight OK — {n_paths} module path(s) resolve, {n_dids} cited D-id(s) checked"
          + (f"; {len(warnings)} warning(s) (non-fatal)" if warnings else ""))
    return 0


if __name__ == '__main__':
    sys.exit(main())

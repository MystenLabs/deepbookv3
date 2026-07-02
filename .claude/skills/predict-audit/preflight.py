#!/usr/bin/env python3
"""Pre-run drift lint for the predict-audit skill — run in the MAIN loop as part of Step 1 (ground truth).

The primer's module map and the D-id ledger citations are the single point of failure for a run: every one
of the hundreds of subagents inherits them, so a path that went stale after a rework silently misleads the
whole fleet and nothing else detects it. This is a cheap, deterministic guard:

  1. MODULE-MAP DRIFT (FATAL) — every `foo/bar.move` path named in primer.md's module map must exist under
     packages/. Unambiguous and always resolvable from the tree, so a miss is a hard error.
  2. D-ID DRIFT (WARNING) — every D0NN id cited anywhere in the skill should resolve to a committed guidance
     file (AGENTS.md / CLAUDE.md / .claude/rules/ / packages/predict/predeploy/). A miss means the decision
     lives only in the local (gitignored) decision journal — a real gap to promote into a committed doc, but
     not a reason to block a run, so it warns rather than fails.

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
    """Every D0NN cited anywhere in the skill SHOULD be defined in a committed guidance file, so a settled_ref
    the prompts lean on is real, not dangling. 'Defined' = the id appears in one of the ground-truth docs. A
    miss is a WARNING (the decision may live only in the local decision journal — promote it), not fatal."""
    ledger_files = [os.path.join(root, 'AGENTS.md'), os.path.join(root, 'CLAUDE.md')]
    ledger_files += glob.glob(os.path.join(root, '.claude', 'rules', '*.md'))
    ledger_files += glob.glob(os.path.join(root, 'packages', 'predict', 'predeploy', '**', '*.md'), recursive=True)
    ledger_text = ''
    for p in ledger_files:
        try:
            ledger_text += open(p, encoding='utf-8', errors='replace').read() + '\n'
        except OSError:
            pass
    defined = set(re.findall(r'\bD0\d\d\b', ledger_text))

    cited = {}  # d-id -> set of skill files citing it
    for path in glob.glob(os.path.join(SKILL, '**', '*'), recursive=True):
        if '__pycache__' in path or not os.path.isfile(path) or not path.endswith(('.md', '.js', '.py')):
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
            warnings.append(f"D-id {did} is cited in the skill ({where}) but not in any committed ledger file — it lives only in the local decision journal; promote the decision into AGENTS.md/predeploy so agents can verify it")
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

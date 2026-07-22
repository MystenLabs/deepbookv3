#!/usr/bin/env python3
"""Cross-reference linter for the Predict development system (this directory).

The system's premise is that no session retains memory, so the artifacts must
machine-check each other instead of relying on anyone remembering. This script
is that check. It verifies, deterministically and stdlib-only:

  1. PINNING TESTS (FATAL) — every test function named in a response-policies.md
     "Pinning tests" field exists as `fun <name>` under packages/predict/tests/.
     A register decision whose pinning test vanished is un-enforced: the exact
     drift class that let risks.md promise unshipped behavior.
  2. ID CROSS-REFS — every `RP-n` reference in the predeploy docs resolves to a
     heading in response-policies.md (FATAL). Open-item style IDs (`C-4`,
     `P-7`, ...) must resolve to EITHER an open-items.md heading (open work) OR a
     register tombstone (an id a register entry title 'resolves'); a miss is a
     WARNING. Model A: item ids are permanent — a resolved item leaves the OPEN
     sections but its id stays a valid provenance reference (evidence/register
     cite it forever), it is not a dangling pointer. A line explicitly saying
     resolved/superseded/removed is also skipped. An id that is BOTH an open
     heading AND register-resolved is a FATAL contradiction (open ∧ resolved).
  3. MEASURED LINKS (FATAL) — a register entry claiming a MEASURED risk profile
     must name at least one findings doc that exists. MEASURED without linked
     evidence is just BEST-GUESS wearing a costume.
  4. DEAD PATHS (FATAL / WARNING) — file paths named in the predeploy docs must
     exist (resolved against predeploy/, packages/predict/, the harness, and
     the repo root). Bare filenames are globbed and only warned on.
  5. EVIDENCE SHAPE (FATAL) — every evidence/ record carries an ownership
     header (`**Item:** <id>`) in its first lines, and is referenced from at
     least one tracker doc (open-items.md, response-policies.md, or README.md).
     An unanchored or unreferenced evidence file is a dump, not a record.
  6. UNIQUE RESOLUTION (FATAL) — at most one register entry's title claims to
     resolve a given open item ("resolves X-n").

Usage:  python3 packages/predict/predeploy/check.py [REPO_ROOT]
Exit 1 on any FATAL; warnings print but keep exit 0.

Run this when a diff touches predeploy/, guards, or tests named here; the
predict-audit skill runs it in preflight.
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.abspath(
    os.path.join(HERE, '..', '..', '..'))
PREDICT = os.path.join(ROOT, 'packages', 'predict')

DOCS = sorted(glob.glob(os.path.join(HERE, '*.md')) +
              glob.glob(os.path.join(HERE, 'evidence', '*.md')))

# Lines that legitimately mention IDs or paths of things that no longer exist.
HISTORICAL = re.compile(
    r'resolv|supersed|historical|former|retired|deleted|remov|graduat',
    re.IGNORECASE)
# Lines naming paths that live outside this repository.
EXTERNAL = re.compile(r"external|not part of this repo|deployment repo|another repo",
                      re.IGNORECASE)


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def defined_ids():
    """IDs defined by headings in the two tracker files."""
    ids = {'rp': set(), 'item': set()}
    reg = os.path.join(HERE, 'response-policies.md')
    if os.path.exists(reg):
        ids['rp'] = set(re.findall(r'^## (RP-\d+)', read(reg), re.M))
    items = os.path.join(HERE, 'open-items.md')
    if os.path.exists(items):
        ids['item'] = set(re.findall(r'^### ([A-Z]{1,2}-\d+):', read(items), re.M))
    return ids


def resolution_pairs():
    """(RP-id, resolved-item-id) for every resolution a register heading declares.

    A heading 'RP-n: ... resolves X-n' tombstones item X-n. Tolerant of the phrasings
    that occur in practice — case ('Resolves'), intervening words ('resolves the C-4'),
    and multiple ids ('resolves C-4, C-5'): every item id after a 'resolv...' keyword on
    an RP heading line is captured (RP-ids themselves excluded — they are the register,
    not items)."""
    reg = os.path.join(HERE, 'response-policies.md')
    if not os.path.exists(reg):
        return []
    pairs = []
    for line in read(reg).splitlines():
        m = re.match(r'## (RP-\d+):', line)
        if not m:
            continue
        kw = re.search(r'\bresolv\w*\b', line, re.I)
        if not kw:
            continue
        for item in re.findall(r'\b[A-Z]{1,2}-\d+\b', line[kw.end():]):
            if not item.startswith('RP-'):
                pairs.append((m.group(1), item))
    return pairs


def resolved_items():
    """Items tombstoned by the register (an entry titled 'RP-n: ... resolves X-n').

    Model A: item IDs are permanent, and the register IS the tombstone — a resolved
    item leaves the OPEN sections, but its id stays a valid reference target
    (provenance in evidence/register), not a dangling pointer. `open-items.md`
    headings mark OPEN work; a register-resolved id is done. See README authority order."""
    return {item for _, item in resolution_pairs()}


def check_pinning_tests(errors):
    """Every function-shaped token in a 'Pinning tests' field exists in tests/."""
    reg = os.path.join(HERE, 'response-policies.md')
    if not os.path.exists(reg):
        return
    test_src = ''
    for path in glob.glob(os.path.join(PREDICT, 'tests', '**', '*.move'),
                          recursive=True):
        test_src += read(path)
    text = read(reg)
    # Entry-driven, not block-driven: the register's rule is that EVERY RP entry
    # links a pinning test or explicitly says it doesn't. Iterating only well-formed
    # blocks would let a missing / mislabelled / un-backticked field slip past silently.
    for entry in re.split(r'^## ', text, flags=re.M)[1:]:
        title = entry.splitlines()[0]
        if not title.startswith('RP-'):
            continue
        block_m = re.search(r'\*\*Pinning tests[^*]*\*\*(.*?)(?=\n- \*\*|\n## |\Z)',
                            entry, re.S)
        if not block_m:
            errors.append(f"response-policies.md entry '{title}' has no 'Pinning "
                          f"tests' field (every entry must link tests or say "
                          f"'not yet catalogued')")
            continue
        block = block_m.group(1)
        if 'not yet catalogued' in block or 'untested' in block:
            continue
        toks = [t for t in re.findall(r'`([a-z][a-z0-9_]+)`', block)
                if '.' not in t and len(t) >= 10 and '_' in t]
        if not toks:
            errors.append(f"response-policies.md entry '{title}' has a Pinning "
                          f"tests field that names no backticked test function "
                          f"(nor 'not yet catalogued')")
            continue
        for tok in toks:
            if not re.search(r'\bfun\s+' + re.escape(tok) + r'\b', test_src):
                errors.append(
                    f"response-policies.md entry '{title}' pins test `{tok}` but "
                    f"no `fun {tok}` exists under packages/predict/tests/")


def check_id_refs(errors, warnings):
    ids = defined_ids()
    resolved = resolved_items()
    for path in DOCS:
        name = os.path.relpath(path, HERE)
        for line in read(path).splitlines():
            for rp in re.findall(r'\b(RP-\d+)\b', line):
                if rp not in ids['rp'] and not HISTORICAL.search(line):
                    errors.append(f"{name}: reference to {rp} but no such entry "
                                  f"in response-policies.md")
            if name == 'README.md':
                continue  # the map's surface table names ID *classes*, not instances
            for item in re.findall(r'\b([A-Z]{1,2}-\d+)\b', line):
                # An item id resolves to OPEN work (a heading), a register tombstone
                # (a resolved id — permanent, provenance-only), or a line explicitly
                # flagging it historical. Anything else is a dangling pointer.
                if item.startswith(('RP-',)) or item in ids['item'] or item in resolved:
                    continue
                if re.fullmatch(r'[SPCOHG]{1,2}-\d+', item) and not HISTORICAL.search(line):
                    warnings.append(f"{name}: mentions {item}, which is neither an "
                                    f"open-items.md heading nor a register-resolved id "
                                    f"(dangling pointer? add it, resolve it, or say "
                                    f"'resolved/removed' on the line)")


def check_open_resolved_conflict(errors):
    """Model A integrity: an id cannot be both OPEN and resolved. An open heading whose
    id the register also claims to resolve is a live contradiction (resurrected-as-open,
    or a resolution that forgot to remove the open block)."""
    both = defined_ids()['item'] & resolved_items()
    for item in sorted(both):
        errors.append(f"open-items.md: {item} is an OPEN heading but the register also "
                      f"resolves it — a resolved item must not remain open (remove the "
                      f"open block; the register entry is its tombstone)")


def check_measured_links(errors):
    reg = os.path.join(HERE, 'response-policies.md')
    if not os.path.exists(reg):
        return
    text = read(reg)
    entries = re.split(r'^## ', text, flags=re.M)[1:]
    for entry in entries:
        title = entry.splitlines()[0]
        if not title.startswith('RP-'):
            continue  # schema/discipline sections mention MEASURED as vocabulary
        profile = re.search(r'\*\*Risk profile[^*]*\*\*(.*?)(?=\n- \*\*|\n## |\Z)',
                            entry, re.S)
        if not profile or 'MEASURED' not in profile.group(1):
            continue
        linked = re.findall(r'`([\w./-]+\.md)`', profile.group(1))
        if not any(resolve(p) for p in linked):
            errors.append(f"response-policies.md entry '{title}' claims MEASURED "
                          f"but links no existing findings doc in its risk profile")


def resolve(token, doc_dir=None):
    """Resolve a path-like token against the naming doc's dir + the system's roots."""
    bases = [HERE, PREDICT, os.path.join(PREDICT, 'harness'), ROOT]
    if doc_dir:
        bases.insert(0, doc_dir)
    for base in bases:
        if os.path.exists(os.path.normpath(os.path.join(base, token))):
            return True
    return False


def check_paths(errors, warnings):
    exts = ('.md', '.move', '.py', '.ts', '.js', '.sql', '.sh', '.toml')
    for path in DOCS:
        name = os.path.relpath(path, HERE)
        seen = set()
        for line in read(path).splitlines():
            if HISTORICAL.search(line) or EXTERNAL.search(line):
                continue
            for tok in re.findall(r'`([\w./-]+)`', line):
                if tok in seen or not tok.endswith(exts) or any(c in tok for c in '*{}<>'):
                    continue
                seen.add(tok)
                if resolve(tok, doc_dir=os.path.dirname(path)):
                    continue
                if '/' in tok:
                    errors.append(f"{name}: names path `{tok}` which does not exist")
                else:
                    hits = glob.glob(os.path.join(PREDICT, '**', tok), recursive=True) \
                        or glob.glob(os.path.join(ROOT, '.claude', '**', tok), recursive=True)
                    if not hits:
                        warnings.append(f"{name}: names file `{tok}` not found under "
                                        f"packages/predict/ or .claude/")


def check_evidence(errors):
    """Every evidence/ record is anchored to an owner and referenced by a tracker."""
    trackers = ''
    for fname in ('open-items.md', 'response-policies.md', 'README.md'):
        path = os.path.join(HERE, fname)
        if os.path.exists(path):
            trackers += read(path)
    for path in sorted(glob.glob(os.path.join(HERE, 'evidence', '*.md'))):
        base = os.path.basename(path)
        head = '\n'.join(read(path).splitlines()[:6])
        if not re.search(r'\*\*Item:\*\* *([A-Z]{1,2}|RP)-\d+', head):
            errors.append(f"evidence/{base}: no ownership header "
                          f"('**Item:** <id>') in its first lines")
        if base not in trackers:
            errors.append(f"evidence/{base}: referenced by no tracker doc "
                          f"(open-items.md / response-policies.md / README.md) "
                          f"— cite it or it shouldn't exist")


def check_unique_resolution(errors):
    resolved = {}
    for rp, item in resolution_pairs():
        if item in resolved and resolved[item] != rp:
            errors.append(f"response-policies.md: both {resolved[item]} and {rp} "
                          f"claim to resolve {item} — one item, one resolution")
        resolved[item] = rp


def main():
    errors, warnings = [], []
    check_pinning_tests(errors)
    check_id_refs(errors, warnings)
    check_open_resolved_conflict(errors)
    check_measured_links(errors)
    check_paths(errors, warnings)
    check_evidence(errors)
    check_unique_resolution(errors)
    for w in warnings:
        print(f"WARNING: {w}")
    for e in errors:
        print(f"FATAL: {e}")
    if errors:
        print(f"\n{len(errors)} fatal, {len(warnings)} warnings")
        return 1
    print(f"OK: predeploy system cross-references clean ({len(warnings)} warnings)")
    return 0


if __name__ == '__main__':
    sys.exit(main())

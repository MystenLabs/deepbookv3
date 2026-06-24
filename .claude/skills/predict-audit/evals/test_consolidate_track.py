#!/usr/bin/env python3
"""Self-test for consolidate.py + track.py — locks the bugs found across the three skill-review rounds so a
future edit cannot SILENTLY re-introduce them (every round's fixes had been introducing the next round's
bugs; this is the structural stop). Run from the MAIN LOOP (not a subagent), after editing either script:

    python3 .claude/skills/predict-audit/evals/test_consolidate_track.py

Exits non-zero if any check fails. No third-party deps. Each check names the round + bug class it guards.
"""
import json, os, sys, subprocess, tempfile

SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, SKILL)
import consolidate  # noqa: E402  (unit-level checks for load/_fp)

CONS, TRACK = os.path.join(SKILL, 'consolidate.py'), os.path.join(SKILL, 'track.py')
FAILS = []

def check(name, cond, detail=''):
    print(('  PASS  ' if cond else '  FAIL  ') + name + ('' if cond else f'   <- {detail}'))
    if not cond:
        FAILS.append(name)

def run(*args):
    p = subprocess.run([sys.executable, *args], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr

def write(d, name, obj):
    p = os.path.join(d, name)
    open(p, 'w').write(obj if isinstance(obj, str) else json.dumps(obj))
    return p

def kept(*items):  # an orchestrator-shaped result with these kept findings
    base = {'severity': 'High', 'status': 'confirmed', 'title': 't', 'location': 'a.move:1', 'claim': 'c'}
    return {'summary': {}, 'kept': [dict(base, **i) for i in items]}

def state(d):
    return json.load(open(os.path.join(d, '.audit-state.json')))

with tempfile.TemporaryDirectory() as D:
    print("== round 3: load() marker-gating (a decoy preamble must NOT swallow the findings) ==")
    decoy = write(D, 'decoy.output', '{"event":"start"}\n' + json.dumps(kept({'title': 'RealBug', 'claim': 'real'})))
    obj = consolidate.load(decoy)
    check('load skips decoy preamble, returns the harness result', bool(obj.get('kept')) and obj['kept'][0]['title'] == 'RealBug', obj)
    try:
        consolidate.load(write(D, 'nomark.output', '{"foo":1}'))
        check('load raises on a no-marker object (-> visible parse_failure)', False)
    except Exception:
        check('load raises on a no-marker object (-> visible parse_failure)', True)
    check('load unwraps the {result:{...}} envelope', consolidate.load(write(D, 'env.output', {'result': kept({'title': 'E'})})).get('kept', [{}])[0].get('title') == 'E')

    print("== round 3: id == dedup granularity (the stages must agree so track can't silently collapse) ==")
    check('_fp distinguishes different claims', consolidate._fp('x.move:9', 'T', 'A') != consolidate._fp('x.move:9', 'T', 'B'))
    check('_fp is stable for identical inputs', consolidate._fp('x.move:9', 'T', 'A') == consolidate._fp('x.move:9', 'T', 'A'))
    check('_fp ignores line numbers (survives drift)', consolidate._fp('x.move:9', 'T', 'c') == consolidate._fp('x.move:40', 'T', 'c'))

    print("== round 3 BLOCKER: 2 distinct-claim findings -> 2 ids -> 2 tracker items (no collapse) ==")
    coll = write(D, 'coll.output', kept({'title': 'Auth', 'location': 'x.move:9', 'claim': 'unscoped withdraw'},
                                         {'title': 'Auth', 'location': 'x.move:9', 'claim': 'missing owner check'}))
    o2 = os.path.join(D, 'o2'); run(CONS, o2, coll)
    fj = json.load(open(os.path.join(o2, 'findings.json')))
    check('distinct-claim findings get distinct ids in findings.json', len(set(f['id'] for f in fj['open'])) == 2, [f['id'] for f in fj['open']])
    _, out = run(TRACK, os.path.join(D, 'tr2'), 'merge', '--run', 'r1', os.path.join(o2, 'findings.json'))
    check('tracker keeps BOTH (no id-collapse drop)', '2 open' in out, out)

    print("== round 3 HIGH: id-less findings synthesize per-item ids (no shared-sentinel collapse) ==")
    noid = write(D, 'noid.json', {'open': [{'title': 'A', 'location': 'p.move:1', 'claim': '1'},
                                           {'title': 'B', 'location': 'q.move:2', 'claim': '2'}]})
    _, out = run(TRACK, os.path.join(D, 'tr3'), 'merge', '--run', 'r1', noid)
    check('id-less distinct findings stay distinct', '2 open' in out, out)

    print("== round 3 HIGH: an ABORTED harness (error key) is loud + non-zero exit ==")
    err = write(D, 'err.output', {'summary': {}, 'error': 'no_units_matched'})
    rc, out = run(CONS, os.path.join(D, 'o3'), err, decoy)
    check('errored harness -> ABORTED line', 'ABORTED' in out, out)
    check('errored harness -> non-zero exit', rc == 1, rc)
    check('...but the working harness still produced its report', 'parsed 1' in out, out)

    print("== round 3 HIGH: ownership-walk 'uncertain' is tagged, not mislabeled confirmed ==")
    walk = write(D, 'walk.output', {'summary': {}, 'confirmed': [
        {'rule_family': 'R5', 'node': 'm::f', 'claim': 'c', 'severity': 'correctness', 'status': 'uncertain', 'recommendation': 'r'}]})
    ow = os.path.join(D, 'ow'); run(CONS, ow, walk)
    check('walk uncertain -> UNCERTAIN tag in report', 'UNCERTAIN' in open(os.path.join(ow, 'consolidated-report.md')).read())

    print("== round 2: tracker resolution semantics ==")
    cb = write(D, 'cb.json', {'open': [{'id': 'aa11bb', 'severity': 'High', 'title': 'idx', 'location': 'a.move:5', 'claim': 'vec[x] oob', 'recommendation': 'fix'}]})
    trcb = os.path.join(D, 'trcb')
    run(TRACK, trcb, 'merge', '--run', 'r1', cb)
    run(TRACK, trcb, 'merge', '--run', 'r2', cb)  # re-merge: a stray [x] in the CLAIM must not auto-resolve
    check('[x] in claim text does NOT false-resolve an open item', state(trcb)['items']['aa11bb']['status'] == 'open')
    run(TRACK, trcb, 'resolve', 'aa11bb')
    check('resolve marks it resolved', state(trcb)['items']['aa11bb']['status'] == 'resolved')
    _, out = run(TRACK, trcb, 'merge', '--run', 'r3', cb)  # re-detected after resolve -> re-open w/ warning
    check('re-detected-after-resolve re-opens (bad fix cannot hide)', '↑1 re-opened' in out and state(trcb)['items']['aa11bb']['status'] == 'open', out)
    _, out = run(TRACK, trcb, 'merge', '--run', 'r4', cb)  # idempotent
    check('re-merge of an open item is idempotent (+0 new)', '+0 new' in out, out)

    print("== verdict flows into the tracker (round-3 data-flow gap) ==")
    unc = write(D, 'unc.output', kept({'title': 'split', 'location': 'z.move:3', 'claim': 'q', 'status': 'uncertain'}))
    ou = os.path.join(D, 'ou'); run(CONS, ou, unc)
    tru = os.path.join(D, 'tru'); run(TRACK, tru, 'merge', '--run', 'r1', os.path.join(ou, 'findings.json'))
    check('UNCERTAIN tag reaches OPEN-ITEMS.md', 'UNCERTAIN' in open(os.path.join(tru, 'OPEN-ITEMS.md')).read())

    print("== no-slip accounting ==")
    rc, out = run(CONS, os.path.join(D, 'o5'), decoy, write(D, 'k2.output', kept({'title': 'B', 'location': 'b.move:2', 'claim': 'd'})))
    check('clean run -> DROPPED 0 + exit 0', 'DROPPED 0' in out and rc == 0, (rc, out))
    rc, out = run(CONS, os.path.join(D, 'o6'), write(D, 'junk.output', 'not json at all'))
    check('unparseable input -> visible parse_failure + non-zero exit', 'FAILED TO PARSE' in out and rc == 1, (rc, out))

print(f"\n{'✅ ALL PASS' if not FAILS else '❌ ' + str(len(FAILS)) + ' FAILED: ' + ', '.join(FAILS)}")
sys.exit(1 if FAILS else 0)

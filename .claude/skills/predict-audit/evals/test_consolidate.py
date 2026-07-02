#!/usr/bin/env python3
"""Self-test for consolidate.py.

Run from the main loop after editing consolidate.py:

    python3 .claude/skills/predict-audit/evals/test_consolidate.py

Exits non-zero if any check fails. No third-party deps.
"""
import json, os, sys, subprocess, tempfile

SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, SKILL)
import consolidate  # noqa: E402  (unit-level checks for load/_fp)

CONS = os.path.join(SKILL, 'consolidate.py')
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

def kept(*items):
    base = {'severity': 'High', 'status': 'confirmed', 'title': 't', 'location': 'a.move:1', 'claim': 'c'}
    return {'summary': {}, 'kept': [dict(base, **i) for i in items]}

with tempfile.TemporaryDirectory() as D:
    print("== load() marker-gating: a decoy preamble must NOT swallow the findings ==")
    decoy = write(D, 'decoy.output', '{"event":"start"}\n' + json.dumps(kept({'title': 'RealBug', 'claim': 'real'})))
    obj = consolidate.load(decoy)
    check('load skips decoy preamble, returns the harness result',
          bool(obj.get('kept')) and obj['kept'][0]['title'] == 'RealBug', obj)
    try:
        consolidate.load(write(D, 'nomark.output', '{"foo":1}'))
        check('load raises on a no-marker object (-> visible parse_failure)', False)
    except Exception:
        check('load raises on a no-marker object (-> visible parse_failure)', True)
    check('load unwraps the {result:{...}} envelope',
          consolidate.load(write(D, 'env.output', {'result': kept({'title': 'E'})})).get('kept', [{}])[0].get('title') == 'E')

    print("== id/dedup granularity: distinct claims stay distinct ==")
    check('_fp distinguishes different claims', consolidate._fp('x.move:9', 'T', 'A') != consolidate._fp('x.move:9', 'T', 'B'))
    check('_fp is stable for identical inputs', consolidate._fp('x.move:9', 'T', 'A') == consolidate._fp('x.move:9', 'T', 'A'))
    check('_fp ignores line numbers (survives drift)', consolidate._fp('x.move:9', 'T', 'c') == consolidate._fp('x.move:40', 'T', 'c'))

    print("== two distinct-claim findings -> two ids in findings.json ==")
    coll = write(D, 'coll.output', kept({'title': 'Auth', 'location': 'x.move:9', 'claim': 'unscoped withdraw'},
                                         {'title': 'Auth', 'location': 'x.move:9', 'claim': 'missing owner check'}))
    o2 = os.path.join(D, 'o2')
    run(CONS, o2, coll)
    fj = json.load(open(os.path.join(o2, 'findings.json')))
    check('distinct-claim findings get distinct ids in findings.json',
          len(set(f['id'] for f in fj['open'])) == 2, [f['id'] for f in fj['open']])

    print("== aborted harnesses are loud and non-zero ==")
    err = write(D, 'err.output', {'summary': {}, 'error': 'no_units_matched'})
    rc, out = run(CONS, os.path.join(D, 'o3'), err, decoy)
    check('errored harness -> ABORTED line', 'ABORTED' in out, out)
    check('errored harness -> non-zero exit', rc == 1, rc)
    check('...but the working harness still produced its report', 'parsed 1' in out, out)

    print("== ownership-walk uncertain is tagged, not mislabeled confirmed ==")
    walk = write(D, 'walk.output', {'summary': {}, 'confirmed': [
        {'rule_family': 'R5', 'node': 'm::f', 'claim': 'c', 'severity': 'correctness', 'status': 'uncertain', 'recommendation': 'r'}]})
    ow = os.path.join(D, 'ow')
    run(CONS, ow, walk)
    check('walk uncertain -> UNCERTAIN tag in report',
          'UNCERTAIN' in open(os.path.join(ow, 'consolidated-report.md')).read())

    print("== panel-health statuses are rendered, never silently folded ==")
    pd = write(D, 'pd.output', kept(
        {'title': 'DeadPanel', 'location': 'p.move:1', 'claim': 'x', 'status': 'unverified-panel',
         'panel_degraded': True, 'panel_severity': ''},
        {'title': 'Downranked', 'location': 'q.move:2', 'claim': 'y', 'status': 'confirmed',
         'panel_severity': 'Medium'}))
    opd = os.path.join(D, 'opd')
    rc, out = run(CONS, opd, pd)
    rpt = open(os.path.join(opd, 'consolidated-report.md')).read()
    check('unverified-panel kept finding -> PANEL DEAD tag in open list', 'PANEL DEAD' in rpt, rpt)
    check('panel_degraded -> degraded-panel tag', 'degraded panel' in rpt, rpt)
    check('panel_severity -> rendered for curation', 'Panel severity (confirming verifiers): Medium' in rpt, rpt)
    check('panel-health statuses keep DROPPED 0 accounting', 'DROPPED 0' in out and rc == 0, (rc, out))
    dead_sib = write(D, 'dsib.output', {'summary': {}, 'unverified': [
        {'rule_family': 'R1', 'node': 'm::f', 'claim': 'c', 'severity': 'high', 'status': 'unverified-panel', 'recommendation': 'r'}]})
    osib = os.path.join(D, 'osib')
    run(CONS, osib, dead_sib)
    check('sibling verifier-dead unverified entry -> marked in unverified section',
          'verifier died' in open(os.path.join(osib, 'consolidated-report.md')).read())

    print("== no-slip accounting ==")
    rc, out = run(CONS, os.path.join(D, 'o5'), decoy, write(D, 'k2.output', kept({'title': 'B', 'location': 'b.move:2', 'claim': 'd'})))
    check('clean run -> DROPPED 0 + exit 0', 'DROPPED 0' in out and rc == 0, (rc, out))
    rc, out = run(CONS, os.path.join(D, 'o6'), write(D, 'junk.output', 'not json at all'))
    check('unparseable input -> visible parse_failure + non-zero exit', 'FAILED TO PARSE' in out and rc == 1, (rc, out))

print(f"\n{'ALL PASS' if not FAILS else str(len(FAILS)) + ' FAILED: ' + ', '.join(FAILS)}")
sys.exit(1 if FAILS else 0)

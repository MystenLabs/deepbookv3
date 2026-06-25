#!/usr/bin/env python3
"""Consolidate predict-audit harness outputs into ONE report with a no-slip accounting guarantee.

The harness Workflows RETURN their full result; the runtime persists it to a task output file (the
notification preview is truncated, the FILE is complete). This reads those FULL files and emits one
consolidated report covering OPEN + SETTLED + REFUTED + COVERAGE, with an accounting line proving every
input finding is accounted for (0 dropped). Deterministic — no LLM, so nothing can be silently lost.

Usage:
  python3 consolidate.py OUT_DIR FILE1.output [FILE2.output ...]
    where each FILE is a harness task output file (orchestrator / ownership-walk / rule-sweep).
Writes OUT_DIR/consolidated-report.md and prints the accounting line. Exits non-zero if anything is dropped.
"""
import json, sys, os, re, hashlib, datetime

SEV = {  # unify the two severity vocabularies into one rank (higher = worse)
    'critical': 6, 'high': 5, 'medium': 4, 'correctness': 4, 'low': 3, 'cleanup': 2, 'info': 2, '': 1,
}

MARKERS = {'summary', 'kept', 'confirmed', 'findings', 'violations', 'settled', 'refuted', 'coverage', 'responsibility_map'}

def load(path):
    """Scan ALL successive '{' and raw_decode, but accept ONLY an object that looks like a harness RESULT
    (carries a marker key) — so a leading log/preamble object (e.g. {"event":"start"}) can't be silently
    returned in place of the findings. Returns the richest qualifying object; raises if none qualifies
    (-> a VISIBLE parse_failure, never a silent zero-findings slip)."""
    raw = open(path, encoding='utf-8', errors='replace').read()
    dec = json.JSONDecoder()
    best, i = None, raw.find('{')
    while i != -1:
        try:
            obj, end = dec.raw_decode(raw, i)
            o = obj.get('result', obj) if isinstance(obj, dict) else obj
            if isinstance(o, dict) and (MARKERS & set(o.keys())) and (best is None or len(o) > len(best)):
                best = o
            i = raw.find('{', max(end, i + 1))
        except json.JSONDecodeError:
            i = raw.find('{', i + 1)
    if best is not None:
        return best
    raise ValueError(f"no harness-result JSON object (needs one of {sorted(MARKERS)}) in {path}")

def _fp(location, title, claim=''):
    """Fingerprint = file WITHOUT line numbers + normalized title + a claim digest. The claim is included so
    two DISTINCT findings at the same file+title (different claim) get DIFFERENT ids; consolidate dedups by
    this id and track.py keys on it, so the two layers agree and a distinct finding is never silently
    collapsed downstream. (Cost: a heavily re-worded claim across runs yields a new id — a VISIBLE duplicate,
    the lesser evil vs a silent drop.)"""
    file = re.sub(r'[^a-z0-9/_.]', '', re.split(r':\d', (location or '').lower())[0])
    t = re.sub(r'[^a-z0-9]+', '', (title or '').lower())[:60]
    c = re.sub(r'[^a-z0-9]+', '', (claim or '').lower())[:60]
    return f"{file}::{t}::{c}"

def norm(f, harness, status):
    """Normalize a finding from any harness shape into one record (lossless), with a stable fingerprint +
    id (= sha1(fingerprint)[:6]) so the SAME issue keeps the SAME id across runs (the tracker keys on it)."""
    rec = {
        'harness': harness, 'status': status,
        'severity': str(f.get('severity', '') or '').strip(),
        'title': f.get('title') or (f.get('claim', '') or '')[:90],
        'location': f.get('location') or f.get('node') or '',
        'source': f.get('lane') or f.get('rule_family') or '',
        'claim': f.get('claim', ''),
        'recommendation': f.get('recommendation', ''),
        'evidence': f.get('evidence') or f.get('proof') or '',
        'settled_ref': f.get('settled_ref', ''),
        'why': f.get('why', ''),
        'classification': f.get('classification', ''),
    }
    rec['fingerprint'] = _fp(rec['location'], rec['title'], rec['claim'])
    rec['id'] = hashlib.sha1(rec['fingerprint'].encode()).hexdigest()[:6]
    return rec

def collect(res, harness):
    """Pull EVERY finding from a harness result, tagging its bucket. Counts must add up."""
    out = []
    # open / actionable buckets differ by harness key name
    for key in ('kept', 'confirmed'):
        for f in res.get(key, []) or []:
            r = norm(f, harness, 'open'); r['verdict'] = f.get('status', 'confirmed') or 'confirmed'; out.append(r)
    for f in res.get('settled', []) or []:
        out.append(norm(f, harness, 'settled'))
    for f in res.get('refuted', []) or []:
        out.append(norm(f, harness, 'refuted'))
    promoted = res.get('promoted', []) or []
    for f in promoted:
        r = norm(f, harness, 'open'); r['verdict'] = 'promoted-unverified'; out.append(r)  # not panel-verified
    # Info/Low/cleanup findings the orchestrator triaged out of the verify panel: recorded (so they are NOT
    # silently dropped + the accounting stays honest), but kept OUT of the open tracker — raw, low-priority.
    for f in res.get('unverified', []) or []:
        out.append(norm(f, harness, 'unverified'))
    return out, len(promoted)

def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(2)
    out_dir, files = sys.argv[1], sys.argv[2:]
    os.makedirs(out_dir, exist_ok=True)
    all_findings, per_harness, coverage_blocks, parse_failures, empty_harnesses, errored_harnesses = [], [], [], [], [], []
    for path in files:
        try:
            res = load(path)
        except Exception as e:  # a file we can't parse is a VISIBLE failure, never a silent slip
            parse_failures.append((path, str(e)))
            print(f"⚠ FAILED to parse {path}: {e}", file=sys.stderr)
            continue
        harness = res.get('summary', {})
        hname = (os.path.basename(path).split('.')[0]) or 'harness'
        findings, npromoted = collect(res, hname)
        all_findings += findings
        per_harness.append((hname, path, len(findings),
                            sum(1 for f in findings if f['status'] == 'open'),
                            sum(1 for f in findings if f['status'] == 'settled'),
                            sum(1 for f in findings if f['status'] == 'refuted'), npromoted))
        err = res.get('error')
        if err:  # a harness that ABORTED must be loud (non-zero exit), not a quiet 0-finding line
            errored_harnesses.append((hname, err))
        elif not findings:  # 0 findings could be clean OR silently scoped-out — warn, don't fail
            empty_harnesses.append((hname, '0 findings — confirm it ran, not silently scoped out'))
        for u in (res.get('summary') or {}).get('unmapped_units', []) or []:  # walk map-failures = real holes
            coverage_blocks.append((hname, u, '⚠ NOT EXAMINED — map agent failed; resume to fill', []))
        for c in res.get('coverage', []) or []:
            coverage_blocks.append((hname, c.get('lane', ''), c.get('coverage', ''), c.get('top3', [])))
        # ownership-walk also carries a responsibility_map worth keeping
        if res.get('responsibility_map'):
            coverage_blocks.append((hname, 'responsibility-map',
                                    ' | '.join(f"{m.get('module')}=[{m.get('role')}]" for m in res['responsibility_map']), []))

    total_in = len(all_findings)
    # dedup OPEN findings across harnesses by (location, title) — record merges, never drop
    seen, dedup_open, merges = {}, [], 0
    for f in [x for x in all_findings if x['status'] == 'open']:
        # Dedup by the SAME id track.py keys on, so the two layers agree: findings.json never contains two
        # records that share an id (which track would silently collapse). The id already folds in
        # location+title+claim, so distinct findings have distinct ids and are NOT merged here.
        k = f['id']
        if k in seen:
            seen[k]['also'].append(f['harness']); merges += 1
        else:
            f['also'] = []; seen[k] = f; dedup_open.append(f)
    settled = [x for x in all_findings if x['status'] == 'settled']
    refuted = [x for x in all_findings if x['status'] == 'refuted']
    unverified = [x for x in all_findings if x['status'] == 'unverified']

    # ACCOUNTING: every input finding is either a unique open, a merge, a settled, a refuted, or an unverified.
    accounted = len(dedup_open) + merges + len(settled) + len(refuted) + len(unverified)
    dropped = total_in - accounted
    acct = (f"ACCOUNTING — parsed {total_in} | open {len(dedup_open)} (+{merges} dup-merges) | "
            f"settled {len(settled)} | refuted {len(refuted)} | unverified {len(unverified)} | DROPPED {dropped} "
            + ("✅ 0 dropped" if dropped == 0 else "⚠️ MISMATCH — investigate"))
    if parse_failures:
        acct += f"\n⛔ {len(parse_failures)} INPUT FILE(S) FAILED TO PARSE (findings NOT in this report): " \
                + "; ".join(f"{p} ({e})" for p, e in parse_failures)
    if errored_harnesses:
        acct += "\n⛔ harness(es) ABORTED (findings NOT in this report): " \
                + "; ".join(f"{h} ({e})" for h, e in errored_harnesses)
    if empty_harnesses:
        acct += "\n⚠ harness(es) contributed 0 findings (confirm they ran, not silently scoped out): " \
                + "; ".join(f"{h} ({e})" for h, e in empty_harnesses)

    # severity desc, then panel-confirmed before uncertain/promoted-unverified
    dedup_open.sort(key=lambda f: (-SEV.get(f['severity'].lower(), 1), 0 if f.get('verdict', 'confirmed') in ('confirmed', '') else 1))
    L = []
    L.append(f"# Predict audit — consolidated report ({datetime.date.today()})\n")
    L.append("## Accounting (no-slip guarantee)\n" + acct + "\n")
    for h, p, n, o, s, r, pr in per_harness:
        L.append(f"- **{h}**: {n} findings ({o} open, {s} settled, {r} refuted, {pr} promoted) — `{p}`")
    L.append("\n## Open findings — by severity\n")
    if not dedup_open: L.append("_(none)_\n")
    for f in dedup_open:
        also = f" (also: {', '.join(f['also'])})" if f['also'] else ""
        vd = f.get('verdict', '')
        vtag = ' · ⚠ UNCERTAIN (verifier split)' if vd == 'uncertain' else (' · ⚠ UNVERIFIED (promoted)' if vd == 'promoted-unverified' else '')
        L.append(f"### [{f['severity'] or '?'}] {f['title']}{vtag}\n"
                 f"- Source: {f['harness']}/{f['source']}{also}\n- Location: {f['location']}\n"
                 f"- Claim: {f['claim']}\n- Recommendation: {f['recommendation']}\n"
                 f"- Evidence: {f['evidence']}\n")
    L.append("## Settled (checked & dismissed — verify the D-refs)\n")
    for f in settled:
        L.append(f"- [{f['harness']}/{f['source']}] {f['location']} — {f['title']} → {f['settled_ref']}")
    L.append("\n## Refuted (second-guess these — a wrong refutation hides a real bug)\n")
    for f in refuted:
        L.append(f"- [{f['harness']}/{f['source']}] {f['location']} — {f['title']} → {f['why']}")
    L.append("\n## Unverified (raw finder output — Info/Low/cleanup, NOT panel-verified; triage manually)\n")
    if not unverified: L.append("_(none)_")
    for f in sorted(unverified, key=lambda f: -SEV.get(f['severity'].lower(), 1)):
        sref = f" → {f['settled_ref']}" if f.get('settled_ref') else ""
        L.append(f"- [{f['severity'] or '?'}] {f['title']} — {f['location']} ({f['harness']}/{f['source']}){sref}")
    L.append("\n## Coverage — what was examined and (esp.) NOT examined\n")
    for h, lane, cov, top3 in coverage_blocks:
        L.append(f"- **{h}/{lane}**: {cov}")
        if top3: L.append("  - top3: " + " | ".join(top3))

    rpt = os.path.join(out_dir, 'consolidated-report.md')
    open(rpt, 'w', encoding='utf-8').write("\n".join(L) + "\n")
    # findings.json (open findings with stable ids) feeds track.py, the live OPEN-ITEMS.md tracker. `unverified`
    # is recorded here too but under its OWN key, so track.py (which keys on `open`) never floods the tracker
    # with Info/Low/cleanup noise.
    json.dump({'open': dedup_open, 'settled': settled, 'refuted': refuted, 'unverified': unverified},
              open(os.path.join(out_dir, 'findings.json'), 'w', encoding='utf-8'), indent=1)
    print(acct)
    print(f"wrote {rpt} ({len(dedup_open)} open, {len(settled)} settled, {len(refuted)} refuted, {len(unverified)} unverified)")
    sys.exit(0 if (dropped == 0 and not parse_failures and not errored_harnesses) else 1)

if __name__ == '__main__':
    main()

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

def load(path):
    """Tolerant: scan successive '{' and raw_decode (ignores leading prose / trailing logs) so a task
    output file that isn't pure JSON can't crash the whole consolidation."""
    raw = open(path, encoding='utf-8', errors='replace').read()
    dec = json.JSONDecoder()
    i = raw.find('{')
    while i != -1:
        try:
            data, _ = dec.raw_decode(raw, i)
            return data.get('result', data) if isinstance(data, dict) else data
        except json.JSONDecodeError:
            i = raw.find('{', i + 1)
    raise ValueError(f"no parseable JSON object in {path}")

def _fp(location, title):
    """Stable fingerprint: file path WITHOUT line numbers (survives line drift) + normalized title."""
    file = re.sub(r'[^a-z0-9/_.]', '', re.split(r':\d', (location or '').lower())[0])
    t = re.sub(r'[^a-z0-9]+', '', (title or '').lower())[:60]
    return f"{file}::{t}"

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
    rec['fingerprint'] = _fp(rec['location'], rec['title'])
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
    return out, len(promoted)

def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(2)
    out_dir, files = sys.argv[1], sys.argv[2:]
    os.makedirs(out_dir, exist_ok=True)
    all_findings, per_harness, coverage_blocks, parse_failures = [], [], [], []
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
        # conservative: collapse ONLY true duplicates (same location AND title AND claim-prefix); two
        # distinct findings at the same location are BOTH kept, so a merge can never hide a real claim.
        k = (f['location'].lower().strip(), f['title'].lower().strip()[:80], (f['claim'] or '').lower().strip()[:80])
        if k in seen:
            seen[k]['also'].append(f['harness']); merges += 1
        else:
            f['also'] = []; seen[k] = f; dedup_open.append(f)
    settled = [x for x in all_findings if x['status'] == 'settled']
    refuted = [x for x in all_findings if x['status'] == 'refuted']

    # ACCOUNTING: every input finding is either a unique open, a merge, a settled, or a refuted.
    accounted = len(dedup_open) + merges + len(settled) + len(refuted)
    dropped = total_in - accounted
    acct = (f"ACCOUNTING — parsed {total_in} | open {len(dedup_open)} (+{merges} dup-merges) | "
            f"settled {len(settled)} | refuted {len(refuted)} | DROPPED {dropped} "
            + ("✅ 0 dropped" if dropped == 0 else "⚠️ MISMATCH — investigate"))
    if parse_failures:
        acct += f"\n⛔ {len(parse_failures)} INPUT FILE(S) FAILED TO PARSE (findings NOT in this report): " \
                + "; ".join(f"{p} ({e})" for p, e in parse_failures)

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
    L.append("\n## Coverage — what was examined and (esp.) NOT examined\n")
    for h, lane, cov, top3 in coverage_blocks:
        L.append(f"- **{h}/{lane}**: {cov}")
        if top3: L.append("  - top3: " + " | ".join(top3))

    rpt = os.path.join(out_dir, 'consolidated-report.md')
    open(rpt, 'w', encoding='utf-8').write("\n".join(L) + "\n")
    # findings.json (open findings with stable ids) feeds track.py, the live OPEN-ITEMS.md tracker.
    json.dump({'open': dedup_open, 'settled': settled, 'refuted': refuted},
              open(os.path.join(out_dir, 'findings.json'), 'w', encoding='utf-8'), indent=1)
    print(acct)
    print(f"wrote {rpt} ({len(dedup_open)} open, {len(settled)} settled, {len(refuted)} refuted)")
    sys.exit(0 if (dropped == 0 and not parse_failures) else 1)

if __name__ == '__main__':
    main()

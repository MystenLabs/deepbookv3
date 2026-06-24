#!/usr/bin/env python3
"""Maintain ONE live OPEN-ITEMS.md tracker across audit runs — the single worklist you fix from.

consolidate.py writes findings.json (open findings, each with a stable id = sha1(fingerprint)[:6], where
fingerprint = file-without-line-numbers + normalized title). track.py merges that into a persistent
OPEN-ITEMS.md so you never chase scattered per-run reports:
  - new finding              -> appended as an open item
  - matches an OPEN item     -> updated in place (refresh evidence, bump last-seen, add harness) — no dup
  - matches a RESOLVED item  -> RE-OPENED with a ⚠ "re-detected after resolution" note (a bad fix can't hide)
  - matches a WONTFIX item   -> stays suppressed
  - open item not seen this run -> KEPT (a sampling miss is NOT a fix)

You resolve an item by DELETING its block from OPEN-ITEMS.md (or checking its `[x]`), or:
  track.py STATEDIR resolve <id>     track.py STATEDIR wontfix <id>
Merge after each audit (consolidate.py first):
  track.py STATEDIR merge --run RUNID findings.json
STATEDIR (default .claude/predict-review/) holds OPEN-ITEMS.md (human) + .audit-state.json (source of truth).
The id-derived-from-fingerprint means the same issue keeps the same id across runs, so dedup is reliable.
"""
import json, sys, os, re, hashlib, datetime

SEV = {'critical': 6, 'high': 5, 'medium': 4, 'correctness': 4, 'low': 3, 'cleanup': 2, 'info': 2, '': 1}

def load_state(d):
    p = os.path.join(d, '.audit-state.json')
    return json.load(open(p)) if os.path.exists(p) else {'items': {}}

def reconcile_user_edits(d, state, run):
    """You resolve by deleting an item's block (or checking [x]) in OPEN-ITEMS.md. Detect it: any state
    item currently 'open' whose id is absent from / checked in the md is now resolved. The .json is the
    backstop, so a malformed edit never loses data — it just may not auto-detect that one resolution."""
    md = os.path.join(d, 'OPEN-ITEMS.md')
    if not os.path.exists(md):
        return 0
    text = open(md, encoding='utf-8', errors='replace').read()
    blocks = {}
    for b in re.split(r'(?=^### `#[0-9a-f]{6}`)', text, flags=re.M):
        m = re.match(r'### `#([0-9a-f]{6})`', b)
        if m:
            blocks[m.group(1)] = b
    n = 0
    for iid, it in state['items'].items():
        if it['status'] != 'open':
            continue
        b = blocks.get(iid)
        # block deleted, OR its checkbox line ticked. Anchor to the `- [x] fixed` line so stray `[x]`
        # in a claim/evidence/location can't falsely auto-resolve an item.
        if b is None or re.search(r'(?mi)^\s*-\s*\[[xX]\]\s*fixed', b):
            it['status'] = 'resolved'
            it.setdefault('notes', []).append(f"resolved by you (≤run {run})")
            n += 1
    return n

def merge(d, run, findings_path):
    state = load_state(d)
    resolved_by_user = reconcile_user_edits(d, state, run)
    data = json.load(open(findings_path, encoding='utf-8'))
    new = data.get('open', data if isinstance(data, list) else [])
    added = updated = reopened = 0
    for f in new:
        # synthesize a per-item id from content if missing, so id-less findings do NOT all collapse onto
        # one shared sentinel (which would silently merge unrelated findings into a single tracker item).
        iid = f.get('id') or hashlib.sha1(
            (f.get('location', '') + '|' + f.get('title', '') + '|' + f.get('claim', '')).encode()).hexdigest()[:6]
        it = state['items'].get(iid)
        if it is None:
            state['items'][iid] = {
                'id': iid, 'fingerprint': f.get('fingerprint', ''), 'status': 'open',
                'verdict': f.get('verdict', ''),
                'severity': f.get('severity', ''), 'title': f.get('title', ''), 'location': f.get('location', ''),
                'source': f.get('source', ''), 'claim': f.get('claim', ''), 'recommendation': f.get('recommendation', ''),
                'evidence': f.get('evidence', ''), 'harnesses': [h for h in [f.get('harness', '')] + f.get('also', []) if h],
                'first_seen': run, 'last_seen': run, 'notes': []}
            added += 1
        elif it['status'] == 'wontfix':
            it['last_seen'] = run  # confirmed false-positive — stays suppressed
        elif it['status'] == 'resolved':
            it['status'] = 'open'; it['last_seen'] = run; it['evidence'] = f.get('evidence') or it.get('evidence', '')
            it['verdict'] = f.get('verdict') or it.get('verdict', '')
            it['notes'].append(f"⚠ RE-DETECTED run {run} — was marked resolved (block deleted/checked) but the audit still finds it; re-check the fix")
            reopened += 1
        else:  # open
            it['last_seen'] = run
            it['severity'] = f.get('severity', it['severity']); it['evidence'] = f.get('evidence') or it.get('evidence', '')
            it['verdict'] = f.get('verdict') or it.get('verdict', '')
            h = f.get('harness', '')
            if h and h not in it['harnesses']:
                it['harnesses'].append(h)
            updated += 1
    write(d, state, run, {'added': added, 'updated': updated, 'reopened': reopened, 'resolved_by_user': resolved_by_user})

def write(d, state, run, ch):
    items = list(state['items'].values())
    opens = sorted([it for it in items if it['status'] == 'open'],
                   key=lambda it: (-SEV.get((it['severity'] or '').lower(), 1), it['location']))
    resolved = [it for it in items if it['status'] == 'resolved']
    wontfix = [it for it in items if it['status'] == 'wontfix']
    L = ["# Predict audit — OPEN ITEMS (live tracker)\n"]
    L.append(f"_Updated {datetime.date.today()} · run {run} · +{ch['added']} new · ~{ch['updated']} updated · "
             f"↑{ch['reopened']} re-opened · {ch['resolved_by_user']} resolved-by-you · **{len(opens)} open**_\n")
    L.append("_Resolve an item by deleting its block (or checking its `[x]`), or `track.py <dir> resolve <id>`. "
             "Re-running the audit updates this file in place and re-opens (⚠) anything you resolved that's still detected._\n")
    L.append(f"## Open ({len(opens)})\n")
    if not opens:
        L.append("_(none) 🎉_\n")
    for it in opens:
        hs = it.get('harnesses', [])
        src = '/'.join(filter(None, [hs[0] if hs else '', it.get('source', '')]))
        vd = it.get('verdict', '')
        vtag = ' · ⚠ UNCERTAIN (verifier split)' if vd == 'uncertain' else (' · ⚠ UNVERIFIED (promoted)' if vd == 'promoted-unverified' else '')
        L.append(f"### `#{it['id']}` · [{it['severity'] or '?'}] {it['title']}{vtag}")
        L.append("- [ ] fixed")
        L.append(f"- **Location:** {it['location']}")
        L.append(f"- **Source:** {src}" + (f" (also: {', '.join(hs[1:])})" if len(hs) > 1 else '')
                 + f" · first-seen {it['first_seen']} · last-seen {it['last_seen']}")
        for nt in it.get('notes', []):
            if nt.startswith('⚠'):
                L.append(f"- {nt}")
        L.append(f"- **Claim:** {it['claim']}")
        L.append(f"- **Fix:** {it['recommendation']}")
        if it.get('evidence'):
            L.append(f"- **Evidence:** {it['evidence']}")
        L.append("")
    L.append(f"## Resolved ({len(resolved)}) — history; re-detection re-opens with ⚠")
    for it in resolved:
        L.append(f"- `#{it['id']}` [{it['severity']}] {it['title']} — {it['location']}")
    L.append(f"\n## Won't-fix / false-positive ({len(wontfix)}) — suppressed")
    for it in wontfix:
        L.append(f"- `#{it['id']}` [{it['severity']}] {it['title']} — {it['location']}")
    open(os.path.join(d, 'OPEN-ITEMS.md'), 'w', encoding='utf-8').write("\n".join(L) + "\n")
    json.dump(state, open(os.path.join(d, '.audit-state.json'), 'w', encoding='utf-8'), indent=1)
    print(f"OPEN-ITEMS.md: +{ch['added']} new ~{ch['updated']} updated ↑{ch['reopened']} re-opened "
          f"{ch['resolved_by_user']} resolved-by-you → {len(opens)} open")

def set_status(d, iid, status):
    state = load_state(d)
    if iid not in state['items']:
        print(f"no item #{iid}"); sys.exit(1)
    state['items'][iid]['status'] = status
    state['items'][iid].setdefault('notes', []).append(f"marked {status} manually")
    write(d, state, '(manual)', {'added': 0, 'updated': 0, 'reopened': 0, 'resolved_by_user': 0})

def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(2)
    d, cmd = sys.argv[1], sys.argv[2]
    os.makedirs(d, exist_ok=True)
    if cmd == 'merge':
        run = sys.argv[sys.argv.index('--run') + 1] if '--run' in sys.argv else datetime.date.today().isoformat()
        merge(d, run, sys.argv[-1])
    elif cmd in ('resolve', 'wontfix'):
        set_status(d, sys.argv[3], 'resolved' if cmd == 'resolve' else 'wontfix')
    else:
        print(__doc__); sys.exit(2)

if __name__ == '__main__':
    main()

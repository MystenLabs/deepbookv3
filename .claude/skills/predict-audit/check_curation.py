#!/usr/bin/env python3
"""No-slip check on the LAST hop: consolidated findings.json -> the committed open-items.md tracker.

track.py's deterministic merge was removed (a settled decision — open-items.md is now a reasoned, by-substance
curation). That left the final hop unguarded: a curation pass over a large findings.json can silently drop or
forget an open finding. This restores the *guarantee* (a drop is loud) WITHOUT re-imposing a mechanical merge:
every open finding must be EITHER

  (a) referenced by its 6-char id in open-items.md (provenance the curator pasted), OR
  (b) listed in a dispositions file with a reason (merged-into / refuted-on-review / duplicate-of / accepted).

Anything that is neither is an UNACCOUNTED open finding -> non-zero exit. Panel-dead findings (verifier died,
status 'unverified-panel') are held to the same bar: a verifier that never ran must not vanish silently.

Usage:
  python3 check_curation.py FINDINGS_JSON OPEN_ITEMS_MD [DISPOSITIONS_JSON]
    DISPOSITIONS_JSON (optional) = { "<id>": "reason", ... }  (ids the curator consciously did NOT paste)
Exit 0 iff every open + panel-dead finding is accounted for; prints the unaccounted ones otherwise.
"""
import json, sys, os, re


def load_ids(findings_path):
    """Return (open_ids, paneldead_ids) as {id: title} maps from a consolidate.py findings.json."""
    data = json.load(open(findings_path, encoding='utf-8'))
    open_ids, dead_ids = {}, {}
    for f in data.get('open', []) or []:
        if f.get('id'):
            open_ids[f['id']] = f.get('title', '')
    # panel-dead live in the `unverified` bucket with raw_status/status == 'unverified-panel'
    for f in data.get('unverified', []) or []:
        st = f.get('raw_status') or f.get('status') or ''
        if st == 'unverified-panel' and f.get('id'):
            dead_ids[f['id']] = f.get('title', '')
    return open_ids, dead_ids


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    findings_path, open_items_path = sys.argv[1], sys.argv[2]
    disp_path = sys.argv[3] if len(sys.argv) > 3 else None

    open_ids, dead_ids = load_ids(findings_path)
    tracker = open(open_items_path, encoding='utf-8', errors='replace').read()
    dispositions = {}
    if disp_path and os.path.exists(disp_path):
        dispositions = json.load(open(disp_path, encoding='utf-8'))

    def accounted(fid):
        # id pasted into the tracker as provenance, or explicitly dispositioned with a non-empty reason.
        if re.search(r'\b' + re.escape(fid) + r'\b', tracker):
            return 'in-tracker'
        if fid in dispositions and str(dispositions[fid]).strip():
            return 'dispositioned'
        return None

    unaccounted, ok = [], 0
    for label, ids in (('open', open_ids), ('panel-dead', dead_ids)):
        for fid, title in ids.items():
            if accounted(fid):
                ok += 1
            else:
                unaccounted.append((label, fid, title))

    total = len(open_ids) + len(dead_ids)
    print(f"curation check — {total} finding(s) requiring disposition ({len(open_ids)} open + {len(dead_ids)} panel-dead) | accounted {ok} | unaccounted {len(unaccounted)}")
    for label, fid, title in unaccounted:
        print(f"  ⛔ [{label}] {fid} not in open-items.md and not dispositioned: {title[:80]}")
    if unaccounted:
        print("\nCURATION SLIP — each unaccounted finding must be pasted into open-items.md (provenance) or "
              "listed in the dispositions file with a reason (merged/refuted/duplicate/accepted).")
        return 1
    print("✅ every open + panel-dead finding is accounted for")
    return 0


if __name__ == '__main__':
    sys.exit(main())

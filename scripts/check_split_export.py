#!/usr/bin/env python3
"""Lässt reference/split_docs.py auf einer Trenn-Diagnose aus der App laufen.

    python3 scripts/check_split_export.py Trenn-Diagnose.json [--truth 1,4,7]

Zeigt pro Seite Zähler, Kennungen und die Schnitte des Originals – zum Vergleich mit der App.
"""
import argparse
import json
import sys
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.modules.setdefault('pdfplumber', types.ModuleType('pdfplumber'))
pypdf = types.ModuleType('pypdf')
pypdf.PdfReader = pypdf.PdfWriter = None
sys.modules.setdefault('pypdf', pypdf)
sys.path.insert(0, str(ROOT / 'reference'))
import split_docs as sd  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('export', type=Path)
    ap.add_argument('--truth')
    a = ap.parse_args()
    entries = [e for e in json.loads(a.export.read_text()) if not e['excluded']]
    bodies = [sd.squeeze(e['body']) for e in entries]
    margins = [e['margin'] for e in entries]
    toks = sd.token_sets(margins)
    starts, nums = sd.find_starts(bodies, margins, verbose=True)
    bounds = starts + [len(bodies)]
    docs = []
    for k in range(len(starts)):
        docs += sd.split_inserts(list(range(bounds[k], bounds[k + 1])), nums)
    docs.sort(key=lambda d: d[0])
    print()
    for i, e in enumerate(entries):
        mark = '>>' if any(d[0] == i for d in docs) else '  '
        print(f"{mark} Seite {e['page']:>3}  Zähler {str(nums[i]):<12} Kennungen {sorted(toks[i]) or '-'}"
              f"  App: {'Schnitt' if e['startsDocument'] else '-'} {e['reason'] or ''}")
    got = {entries[d[0]]['page'] for d in docs}
    print(f"\nOriginal: {len(docs)} Dokumente, Starts {sorted(got)}")
    app = {e['page'] for e in entries if e['startsDocument']}
    if app != got:
        print(f"App weicht ab: Starts {sorted(app)}")
    if a.truth:
        truth = sd.parse_truth(a.truth)
        print(f"übersehen: {sorted(truth - got) or 'keine'}   zusätzlich: {sorted(got - truth) or 'keine'}")


if __name__ == '__main__':
    main()

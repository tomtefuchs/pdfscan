#!/usr/bin/env python3
"""Erzeugt Testfälle für die Swift-Portierung von reference/split_docs.py.

Baut zufällige Sammelscans aus typischen Bausteinen (Zähler, Randkennungen, Briefköpfe,
Fortsetzungshinweise, Einschübe, vertauschte Seiten) und lässt das Original die Dokumente
bestimmen. Ergebnis: Tests/PDFScanCoreTests/SplitParityCases.swift (JSON-Literal).

    python3 scripts/gen_split_parity.py
"""
import json
import random
import sys
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.modules['pdfplumber'] = types.ModuleType('pdfplumber')
pypdf = types.ModuleType('pypdf')
pypdf.PdfReader = pypdf.PdfWriter = None
sys.modules['pypdf'] = pypdf
sys.path.insert(0, str(ROOT / 'reference'))
import split_docs as sd  # noqa: E402

FILLER = [
    'wir bestaetigen den Eingang Ihrer Unterlagen vom 3. Mai.',
    'Die Abrechnung umfasst den Zeitraum 01.01. bis 31.12.',
    'Bitte beachten Sie die Hinweise auf der Rueckseite.',
    'Betrag 1.234,56 EUR  faellig zum 15.06.',
    'Position 3/4 Liter Farbe  12,50',
    'Vertragsnummer 4711-0815  Kundennummer 99887',
    'Ihr Ansprechpartner: Frau Meier, Telefon 030 1234567',
    'Anlage: Kontoauszug, Bescheinigung',
    'Mit freundlichen Gruessen',
    'Zinssatz 2,5 % p.a. / Laufzeit 10 Jahre',
]
CITIES = ['Berlin', 'Hamburg', 'Muenchen', 'Koeln', 'Dresden', 'Kiel']


def ident(rng):
    chars = 'ABCDEFGHJKMNPQRTUVWXYZ0123456789'
    while True:
        t = rng.choice('ABCDEFGHKMNPRTUWXYZ') + ''.join(rng.choice(chars) for _ in range(rng.randint(8, 12)))
        if any(c.isdigit() for c in t) and len(set(t)) >= 6:
            return t


def noisy(rng, t):
    """OCR-Rauschen: ein Zeichen tauschen oder anhängen, manchmal rückwärts gelesen."""
    t = list(t)
    r = rng.random()
    if r < 0.3:
        t[rng.randrange(1, len(t))] = rng.choice('0O1IL5S8B')
    elif r < 0.45:
        t.append(rng.choice('0123J'))
    s = ''.join(t)
    return s[::-1] if rng.random() < 0.15 else s


def make_doc(rng, n_pages, style, form_no):
    tok = ident(rng) if rng.random() < 0.5 else None
    letter = rng.random() < 0.6
    pages = []
    order = list(range(1, n_pages + 1))
    if n_pages >= 4 and rng.random() < 0.2:
        rng.shuffle(order)                      # Blätter nicht in Leserichtung
    for c in order:
        lines, margin = [], []
        if style == 'head':
            lines.append(f'Blatt {c}/{n_pages}  Datum 12.03.1998')
        if c == 1 and letter:
            lines += ['Max Mustermann', 'Hauptstr. 1', f'{rng.randint(10000, 99999)} {rng.choice(CITIES)}', '',
                      rng.choice(['Sehr geehrte Frau Beispiel,', 'Sehr geehrter Herr Beispiel,',
                                  'Sehr geehrte Damen und Herren,'])]
        if form_no:
            lines.append(f'Formular {form_no}')
        lines += rng.sample(FILLER, rng.randint(2, 5))
        if c < n_pages and rng.random() < 0.15:
            lines.append(f'Fortsetzung auf Seite {c + 1:02d}')
        if style == 'foot':
            lines.append(rng.choice([f'Seite {c}/{n_pages}', f'{c} / {n_pages}', f'- {c}/{n_pages} -']))
        elif style == 'word':
            lines.insert(0, f'Seite {c}')
        elif style == 'vblock':
            lines += [f'{c:04d}', f'{n_pages:04d}']
        if tok and (c == 1 or rng.random() < 0.7):
            margin.append(noisy(rng, tok))
        if rng.random() < 0.2:
            margin.append(rng.choice(['2123AN', '5V321Z', '1111111N', 'OMR']))
        pages.append(('\n'.join(lines), ' '.join(margin)))
    return pages


def make_case(rng):
    form_no = rng.choice([None, None, '12/34'])
    letterhead = ident(rng) if rng.random() < 0.3 else None
    pages = []
    for _ in range(rng.randint(1, 6)):
        style = rng.choice(['foot', 'foot', 'head', 'word', 'vblock', 'none'])
        doc = make_doc(rng, rng.randint(1, 5), style, form_no)
        if style in ('foot', 'head') and len(doc) >= 3 and rng.random() < 0.25:
            # Fremdes Blatt ohne Zähler dazwischengeraten
            k = rng.randint(1, len(doc) - 1)
            doc.insert(k, ('\n'.join(rng.sample(FILLER, 3)), ''))
        pages += doc
    if letterhead:
        pages = [(b, (m + ' ' + letterhead).strip()) for b, m in pages]
    return pages


def expected(pages):
    bodies = [sd.squeeze(b) for b, _ in pages]
    margins = [m for _, m in pages]
    starts, nums = sd.find_starts(bodies, margins)
    bounds = starts + [len(bodies)]
    docs = []
    for k in range(len(starts)):
        docs += sd.split_inserts(list(range(bounds[k], bounds[k + 1])), nums)
    docs.sort(key=lambda d: d[0])
    return starts, docs


def main():
    rng = random.Random(20260925)
    cases = []
    for _ in range(80):
        pages = make_case(rng)
        starts, docs = expected(pages)
        cases.append({'bodies': [b for b, _ in pages], 'margins': [m for _, m in pages],
                      'starts': starts, 'documents': docs})
    payload = json.dumps(cases, ensure_ascii=True, separators=(',', ':'))
    assert '"#' not in payload
    out = ROOT / 'Tests' / 'PDFScanCoreTests' / 'SplitParityCases.swift'
    out.write_text(
        '// Generiert von scripts/gen_split_parity.py aus reference/split_docs.py – nicht von Hand ändern.\n'
        'enum SplitParityCases {\n'
        '    static let json = #"""\n' + payload + '\n"""#\n}\n')
    total = sum(len(c['bodies']) for c in cases)
    multi = sum(1 for c in cases if len(c['documents']) > 1)
    inserts = sum(1 for c in cases if len(c['documents']) > len(c['starts']))
    print(f'{len(cases)} Fälle, {total} Seiten, {multi} mit mehreren Dokumenten, {inserts} mit Einschüben')


if __name__ == '__main__':
    main()

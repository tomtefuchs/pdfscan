#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pdfplumber", "pypdf"]
# ///
"""
Zerlegt einen Sammelscan in Einzeldokumente.

Kaskade (in dieser Reihenfolge, erste sichere Aussage gewinnt):
  1. Seiten-/Gesamtzaehler (Fuss, Kopftabelle, senkrechter Randblock),
     sowohl "neue Seite 1" als auch "Vorseite war 4/4 und damit Schluss"
  2. Vorgangskennung im Blattrand, unscharf verglichen
  3. Anschriftenfeld mit Anrede
Ein Fortsetzungshinweis auf der Vorseite ("Fortsetzung auf Seite 03")
unterdrueckt einen Schnitt.

Ein *Sprung* im Zaehler ist bewusst kein Signal: gescannte Blaetter liegen
nicht zwingend in Leserichtung (beobachtet: 1,2,5,6,3,4 in einem Dokument),
und zerlesene Zaehler springen ebenfalls. Beides erzeugt Schnitte mitten im
Dokument. Nur der Zaehlerstand 1 zaehlt.

Keine absenderspezifischen Regeln: die Signale beschreiben, wie Geschaefts-
post allgemein gebaut ist, nicht wer sie verschickt hat.

Bewusst uebersegmentierend: ein zu viel gesetzter Schnitt kostet Sekunden,
ein uebersehener versteckt ein Dokument dauerhaft.

Aufruf:
    uv run split_docs.py scan.pdf -o /pfad/consume
    uv run split_docs.py scan.pdf --dry-run --truth 1,4,11,15,19,20,22-55,56
"""

import argparse
import re
import difflib
import sys

import pdfplumber
from pypdf import PdfReader, PdfWriter
from pathlib import Path

# --------------------------------------------------------------------------
# Signale

# Maschinenkennung: Zeichenkette aus Ziffern und Grossbuchstaben, wie sie
# Druckstrassen an den Blattrand setzen. Bewusst formatfrei - welcher
# Absender welches Schema benutzt, muss das Skript nicht wissen.
# Mindestens 8 Zeichen: kuerzere Funde aus dem Blattrand sind in der Praxis
# OCR-Bruchstuecke, keine Kennungen (beobachtet: 2123AN, 5V321Z).
TOKEN = re.compile(r'\b(?=[A-Z0-9_]*\d)[A-Z][A-Z0-9_]{7,23}\b')

# Zaehlerblock: zwei nullgepolsterte Zahlen untereinander, erste <= zweite.
# Deckt "Seite n von m" in senkrechter Randschreibweise ab.
VBLOCK = re.compile(r'^[ \t]*0*(\d{1,5})[ \t]*\n[ \t]*0*(\d{1,5})[ \t]*$', re.M)

# Zaehler im Fliesstext
PG_SLASH = re.compile(r'(?<![\d,.])(\d{1,3})\s*/\s*(\d{1,3})(?![\d,.])')
PG_WORD = re.compile(r'\bSeite\s+(\d{1,3})\b', re.I)
CONT = re.compile(r'Fortsetzung auf Seite\s*0?(\d{1,3})', re.I)

# Kopfblock eines Geschaeftsbriefs
SALUT = re.compile(r'Sehr\s+geehrt\w*\s+(?:Herr|Frau|Damen)', re.I)
ADDR = re.compile(r'\b\d{5}\s+[A-ZAOU][a-zaou\u00e4\u00f6\u00fc\u00df]', re.M)

MAX_DF = 0.40   # Token, das auf mehr als 40 % aller Seiten steht, ist Briefkopf,
                # nicht Vorgangskennung (USt-IdNr, Handelsregister, Domain).
MARGIN_PT = 30  # Randbreite in Punkt (gut 1 cm). Absolut, nicht relativ: bei
                # Querformat wuerde ein Prozentwert die erste Tabellenspalte
                # mit einfangen und ISIN/WKN als Kennung missdeuten.
FUZZ = 0.80     # Aehnlichkeit, ab der zwei Kennungen als dieselbe gelten.
                # Faengt OCR-Rauschen in der ID selbst ab (93569C0D/93569C01J).


def norm(s: str) -> str:
    """OCR-Verwechslungen einebnen und Leserichtung vereinheitlichen.

    Randzeichen stehen um 90 oder 180 Grad gedreht; je nach Drehung liefert die
    Extraktion sie vorwaerts oder rueckwaerts. Kanonisch ist die lexikalisch
    kleinere der beiden Leserichtungen.
    """
    t = (s.upper().replace('VV', 'W')
         .replace('O', '0').replace('I', '1')
         .replace('L', '1').replace('S', '5'))
    return min(t, t[::-1])


def squeeze(t: str) -> str:
    """Fuell-Leerzeichen der Layout-Extraktion kollabieren.

    layout=True haelt Spalten per Leerzeichen auf Position und blaeht eine
    Seite auf das Drei- bis Fuenffache auf. Die Zeichen-Fenster weiter unten
    (Kopf, Fuss) wuerden dann am Fuellmaterial verhungern. Zeilenumbrueche
    bleiben, damit VBLOCK den senkrechten Ziffernblock weiter sieht.
    """
    return re.sub(r'[ \t]{2,}', ' ', t)


def extract(pdf: Path) -> tuple[list[str], list[str]]:
    """Pro Seite Volltext und Randtext in einem Durchgang.

    layout=True haelt Spalten und senkrechte Ziffernbloecke zusammen; ohne das
    zerfaellt der Zaehlerblock im Rand in Einzelzeichen und VBLOCK greift nicht.
    Randtext ist der Teil, der ausserhalb von MARGIN_PT liegt - dort sitzen die
    Steuerzeichen der Druckstrasse.
    """
    pages, margins = [], []
    with pdfplumber.open(str(pdf)) as doc:
        for pg in doc.pages:
            pages.append(squeeze(pg.extract_text(layout=True) or ''))
            try:
                w, h = pg.width, pg.height
                words = pg.extract_words(use_text_flow=False)
                margins.append(' '.join(
                    x['text'] for x in words
                    if x['x1'] < MARGIN_PT or x['x0'] > w - MARGIN_PT
                    or x['bottom'] < MARGIN_PT or x['top'] > h - MARGIN_PT))
            except Exception as e:
                print(f'  Randextraktion Seite {len(pages)} fehlgeschlagen ({e})')
                margins.append('')
    return pages, margins


def token_sets(margins: list[str]) -> list[set]:
    """Pro Seite die Menge der Vorgangskennungen.

    Token, die auf zu vielen Seiten vorkommen, fliegen raus: die stammen aus
    dem Briefkopf und wuerden Dokumentgrenzen ueberbruecken.
    """
    pages = margins
    # Zeichenarme Funde verwerfen: eine Kennung, die aus zwei verschiedenen
    # Zeichen besteht (1111111N), ist verrutschte OCR, kein Vorgangsschluessel.
    raw = [{t for t in (norm(x) for x in TOKEN.findall(p)) if len(set(t)) >= 4}
           for p in pages]
    df = {}
    for s in raw:
        for t in s:
            df[t] = df.get(t, 0) + 1
    limit = max(2, int(len(pages) * MAX_DF))
    return [{t for t in s if df[t] <= limit} for s in raw]


def related(a: set, b: set) -> bool:
    """Teilen sich zwei Seiten eine Vorgangskennung?

    Nicht auf Gleichheit pruefen: die Kennung selbst kommt aus der OCR und
    traegt deren Fehler. Aehnlichkeit oberhalb FUZZ zaehlt als Treffer.
    """
    if a & b:
        return True
    for x in a:
        for y in b:
            if abs(len(x) - len(y)) <= 2 and \
                    difflib.SequenceMatcher(None, x, y).ratio() >= FUZZ:
                return True
    return False


def slash_blacklist(pages: list[str]) -> set:
    """Schraegstrich-Paare, die auf zu vielen Seiten unveraendert stehen.

    Ein echter Seitenzaehler aendert sich von Blatt zu Blatt. Ein Paar, das
    identisch auf der Haelfte des Stapels klebt, ist Briefkopf - Formular-
    nummer, Filial- oder Druckauftragskennung. Dieselbe Ueberlegung wie
    MAX_DF bei den Randkennungen, nur auf die Zaehler angewandt.
    """
    df = {}
    for t in pages:
        seen = {(int(a), int(b))
                for a, b in PG_SLASH.findall(t[:3000]) + PG_SLASH.findall(t[-700:])}
        for pair in seen:
            df[pair] = df.get(pair, 0) + 1
    limit = max(2, int(len(pages) * MAX_DF))
    return {pair for pair, c in df.items() if c > limit}


def page_no(text: str, skip: set = frozenset()):
    """Wahrscheinlichste (Seite, Gesamt) der Seite.

    Zaehler stehen mal im Fuss, mal im Kopftabellenblock, mal als senkrechter
    Ziffernblock im Rand. Alle drei Zonen werden geprueft.
    """
    m = VBLOCK.search(text)
    if m:
        cur, tot = int(m.group(1)), int(m.group(2))
        if 1 <= cur <= tot <= 999:
            return (cur, tot)
    best = None
    for zone in (text[-700:], text[:3000]):
        for cur, tot in PG_SLASH.findall(zone):
            cur, tot = int(cur), int(tot)
            if (cur, tot) in skip:
                continue
            if 1 <= cur <= tot <= 99:
                best = (cur, tot)
        if best:
            return best
    m = PG_WORD.search(text[:1200])
    if m:
        return (int(m.group(1)), None)
    return None


def is_head(text: str) -> bool:
    head = text[:1400]
    return bool(SALUT.search(head)) and bool(ADDR.search(head))


def find_starts(pages: list[str], margins: list[str], verbose=False):
    toks = token_sets(margins)
    nums = [page_no(p, slash_blacklist(pages)) for p in pages]
    conts = [bool(CONT.search(p)) for p in pages]

    # Rueckwaerts auffuellen: traegt die Folgeseite eine 2 und die aktuelle
    # gar keinen Zaehler, ist die aktuelle Seite 1. Rettet Deckblaetter,
    # deren Randmarker die OCR zerlegt hat.
    # Nur mit Anschriftenblock: ohne diese Bedingung borgt die Regel den
    # Zaehler ueber eine Dokumentgrenze hinweg - die "2" der Folgeseite
    # gehoert dann zu einem anderen Vorgang, und mitten in ein Dokument
    # faellt ein Schnitt.
    for i in range(len(pages) - 1):
        if nums[i] is None and nums[i + 1] and nums[i + 1][0] == 2 \
                and ADDR.search(pages[i][:1400]):
            nums[i] = (1, nums[i + 1][1])

    starts, why = [0], ['erste Seite']
    # Letzte Seite, die ueberhaupt eine Kennung trug. Kennungen stehen auf
    # Anschreiben, nicht auf Beiblaettern - gegen die unmittelbare Vorseite
    # zu vergleichen verliert das Signal, sobald ein Beiblatt dazwischenliegt.
    last_tok = toks[0] or None
    for i in range(1, len(pages)):
        n, pn = nums[i], nums[i - 1]
        reason = None

        # 1. Zaehler sagt: neue Seite 1
        if n and n[0] == 1 and not conts[i - 1]:
            reason = 'Zaehler auf 1'
        # 2. Die Vorseite war laut ihrem eigenen Zaehler die letzte ihres
        # Dokuments (4/4). Was danach kommt, kann nur etwas Neues sein -
        # unabhaengig davon, ob die neue Seite selbst einen Zaehler traegt.
        elif pn and pn[1] and pn[0] == pn[1]:
            reason = f'Vorseite {pn[0]}/{pn[1]} war Schluss'
        # 3. Kennungen wechseln vollstaendig
        elif toks[i] and last_tok and not related(toks[i], last_tok):
            reason = 'Kennung wechselt'
        # 4. Neuer Briefkopf
        elif is_head(pages[i]) and not conts[i - 1]:
            reason = 'Anschrift + Anrede'

        if toks[i]:
            last_tok = toks[i]

        if reason:
            starts.append(i)
            why.append(reason)

    if verbose:
        for s, r in zip(starts, why):
            print(f'  Seite {s+1:>3}  {r}')
    return starts, nums


def split_inserts(block: list[int], nums: list) -> list[list[int]]:
    """Fremde Blaetter aus dem Bauch eines Dokuments loesen.

    Gesucht sind Laeufe zaehlerloser Seiten, die eine sonst fortlaufende
    Zaehlerfolge unterbrechen (... 4, -, -, 5 ...). Solche Seiten gehoeren
    nicht zum Dokument, sie sind beim Scannen dazwischengeraten.

    Bewusst wird nur herausgeloest, nie umsortiert: die uebrigen Seiten
    behalten ihre Reihenfolge. Wo ein Zaehler zerlesen ist, entsteht so
    hoechstens ein sichtbar falscher Schnitt - eine Umsortierung wuerde
    dort still Seiten durcheinanderwerfen.
    """
    main, inserts, i = [], [], 0
    while i < len(block):
        if nums[block[i]] is not None:
            main.append(block[i])
            i += 1
            continue
        j = i
        while j < len(block) and nums[block[j]] is None:
            j += 1
        prev = next((nums[x] for x in reversed(main) if nums[x]), None)
        nxt = nums[block[j]] if j < len(block) else None
        if prev and nxt and prev[0] + 1 == nxt[0]:
            inserts.append(block[i:j])      # Einschub: eigenes Dokument
        else:
            main.extend(block[i:j])         # Vor-/Nachspann: gehoert dazu
        i = j
    return [main] + inserts


def write_parts(pdf: Path, docs: list[list[int]], outdir: Path,
                stem: str) -> list[Path]:
    outdir.mkdir(parents=True, exist_ok=True)
    src = PdfReader(str(pdf))
    written = []
    for k, doc in enumerate(docs, 1):
        dst = outdir / f'{stem}_{k:03d}.pdf'
        out = PdfWriter()
        for i in doc:
            out.add_page(src.pages[i])
        with dst.open('wb') as fh:
            out.write(fh)
        written.append(dst)
    return written


def parse_truth(spec: str) -> set[int]:
    """Soll-Startseiten aus einem String oder einer Datei mit ebensolchem."""
    f = Path(spec)
    if f.is_file():
        spec = f.read_text()
    out = set()
    for part in spec.strip().split(','):
        if '-' in part:
            a, b = part.split('-')
            out.update(range(int(a), int(b) + 1))
        else:
            out.add(int(part))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('pdf', type=Path)
    ap.add_argument('-o', '--outdir', type=Path, default=Path('out'))
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--verbose', action='store_true')
    ap.add_argument('--truth', help='Soll-Startseiten oder Datei damit, '
                                    'z.B. 1,4,11,22-55 oder truth/scan.txt')
    a = ap.parse_args()

    pages, margins = extract(a.pdf)
    print(f'{len(pages)} Seiten gelesen')
    starts, nums = find_starts(pages, margins, verbose=a.verbose)
    bounds = starts + [len(pages)]
    docs = []
    for k in range(len(starts)):
        docs += split_inserts(list(range(bounds[k], bounds[k + 1])), nums)
    docs.sort(key=lambda d: d[0])
    print(f'{len(docs)} Dokumente erkannt')

    if a.truth:
        truth = parse_truth(a.truth)
        got = {d[0] + 1 for d in docs}
        miss = sorted(truth - got)
        extra = sorted(got - truth)
        tp = len(truth & got)
        prec = tp / len(got) if got else 0
        rec = tp / len(truth) if truth else 0
        f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0
        print(f'Boundary-Precision {prec:.3f}  Recall {rec:.3f}  F1 {f1:.3f}')
        print(f'uebersehen: {miss or "keine"}')
        print(f'zusaetzlich: {extra or "keine"}')
        blocks = sorted(truth)
        ok = sum(1 for j, s in enumerate(blocks)
                 if s in got and (blocks[j + 1] if j + 1 < len(blocks)
                                  else len(pages) + 1) in got | {len(pages) + 1})
        print(f'vollstaendig korrekte Dokumente: {ok}/{len(truth)}')

    if not a.dry_run:
        files = write_parts(a.pdf, docs, a.outdir, a.pdf.stem)
        print(f'{len(files)} Dateien in {a.outdir}')


if __name__ == '__main__':
    sys.exit(main())

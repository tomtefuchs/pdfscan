# PDFScan

Kleine macOS-App, mit der man alte Dokumente stapelweise mit dem **Epson FastFoto FF-680W** (oder jedem anderen
Scanner mit macOS-Treiber) einscannt und daraus **durchsuchbare PDFs** macht. Die Texterkennung läuft komplett lokal
über Apples Vision-Framework, auch für Deutsch mit Umlauten und ß. Es gibt keine Cloud und keine externen Abhängigkeiten.

## Funktionen

- **Direkt scannen** über den Dokumenteneinzug, auf Wunsch beidseitig (Duplex). Alle Blätter im Einzug werden an das
  aktuelle Dokument angehängt. Mehrere Einzüge hintereinander ergeben ein langes Dokument.
- **Stapelmodus**: „Nach jedem Scan automatisch speichern“ macht aus jedem Einzug ein eigenes PDF.
- **OCR** mit Vision (Deutsch, Englisch, Französisch, Italienisch, Spanisch). Der Text liegt unsichtbar über dem Scan.
  Man kann ihn also suchen, markieren und kopieren, und Spotlight findet ihn.
- **Handschrift** (Einstellung „Handschrift“, Standard „Automatisch“): Sieht eine Seite nach Handschrift aus
  (viel Tinte, aber wenig erkannter Text oder wenige echte Wörter laut macOS-Wörterbuch), läuft ein zweiter
  Durchgang auf kontrastverstärkten Bildern: in Graustufen, im dunkelsten Farbkanal (entfernt Karoraster) und in
  Streifen. Pro Zeile gewinnt die Lesart mit den meisten echten Wörtern. Bei flüchtiger Schreibschrift steigt
  so der Anteil richtig gelesener Wörter spürbar, ein fehlerfreier Text wird es aber nicht. Solche Seiten tragen in der Liste den Hinweis „Handschrift“. Über das Kontextmenü oder
  die Symbolleiste erzwingt **„Handschrift erkennen“** den Durchgang für eine einzelne Seite.
- **Automatisch aufrecht drehen**: Falsch herum eingelegte Seiten werden anhand des Textes erkannt und gedreht.
- **Leerseiten weglassen**: Unbedruckte Rückseiten beim Duplex-Scan werden erkannt und abgewählt. Man kann sie per
  Häkchen wieder aufnehmen.
- **Automatisch in einzelne Dokumente trennen** mit der Logik aus `reference/split_docs.py`: Zähler
  („1/3“, „Seite 1“, senkrechter Randblock), Vorgangskennungen im Blattrand, Anschrift mit Anrede. Der Grund
  steht an jeder Trennlinie. Mit ⌘T setzt oder entfernt man Trennstellen von Hand, mit ⇧⌘T berechnet man sie neu, mit ⌥⌘T
  entfernt man alle auf einmal.
- **Einheitliche Dateinamen**: `<Präfix><Jahr>_<Monat>_<Tag>_<Batch>_<Dokument>.pdf`, z. B.
  `Scan_2026_09_25_003_01.pdf`. Details siehe unten.
- Seiten **sortieren** (Drag & Drop), **drehen**, **löschen**, erkannten Text in der Vorschau prüfen.
- **Import** von Bildern (JPEG/PNG/TIFF/HEIC, auch mehrseitige TIFFs) und **bestehenden PDFs**, etwa alten Scans
  ohne Texterkennung oder Dateien aus Epson ScanSmart/FastFoto. Man kann sie auch einfach ins Fenster ziehen.
- **Kompakte PDFs** (Einstellung „Dateigröße“, Standard „Kompakt“, etwa 100–250 KB pro A4-Seite): Seiten ohne
  echte Farbe werden in Graustufen gespeichert, vergilbtes Papier wird aufgehellt, das Bild im PDF hat 200 dpi.
  Farbige Stempel, Unterschriften und Fotos bleiben farbig. Die Texterkennung nutzt immer den vollen Scan.

## Profile

Profile speichern alle Einstellungen, vor allem den Zielordner, z. B. „Privat“, „Firma“ oder „Eltern“. Das
aktive Profil wählst du oben rechts links neben dem Scanner. Dort legst du Profile auch an („Neues Profil…“
übernimmt die aktuellen Einstellungen und fragt nach dem Zielordner), benennst sie um oder löschst sie. Die
Einstellungen (⌘,) bearbeiten immer das aktive Profil und speichern Änderungen automatisch darin. Gibt es mehrere
Profile, fragt die App beim Start, mit welchem du arbeiten willst.

## Dateinamen

| Teil | Bedeutung |
|---|---|
| Präfix | frei einstellbar, Standard `Scan_` |
| `2026_09_25` | Datum des Speicherns |
| `003` | Batch: ein Speichervorgang, also ein Stapel. Beginnt jeden Tag bei 001 und wird aus den vorhandenen Dateien im Zielordner fortgesetzt, auch nach einem Neustart der App. |
| `01` | Dokument innerhalb des Batches, in der Reihenfolge der Trennstellen |

**Importierte Dateien** (Bilder oder PDFs, die man nur zur Texterkennung hineinzieht) behalten ihren
Namen mit angehängtem `_ocr`, z. B. `Mietvertrag.pdf` → `Mietvertrag_ocr.pdf`. Wird ein importierter
Sammelscan in mehrere Dokumente getrennt, heißen sie `Mietvertrag_ocr_01.pdf`, `…_ocr_02.pdf` usw.
Sie werden **neben der Originaldatei** gespeichert. Ist dieser Ordner schreibgeschützt, fragt die App mit
einem Speichern-Dialog nach dem Ort. Bei mehreren Dokumenten aus demselben Original genügt eine Ordnerwahl. Maßgeblich ist die erste Seite eines Dokuments. Vorhandene Dateien werden nie
überschrieben, stattdessen wird `_2`, `_3` … angehängt.

Beispiel: Ein Stapel mit drei Briefen ergibt `Scan_2026_09_25_003_01.pdf`, `…_003_02.pdf` und `…_003_03.pdf`.
Im Stapelmodus ist jeder Einzug ein eigener Batch. Eine Trennmarke auf einer weggelassenen Leerseite gilt
für die nächste übernommene Seite.

## Voraussetzungen

- macOS 13 (Ventura) oder neuer
- Xcode oder die Command Line Tools (`xcode-select --install`), nur zum Bauen
- **Epson-Treiber für den FF-680W**: „Epson Scan 2“ von der Epson-Supportseite des FF-680W installieren. Er bringt
  den ICA-Treiber mit, über den macOS-Apps den Scanner ansprechen.
  **Test:** Der Scanner muss in der App **„Digitalbilder“** (Image Capture) auftauchen und dort scannen können.
  Dann funktioniert er auch in PDFScan. Das gilt per USB und per WLAN.

## Bauen und starten

```bash
# Direkt starten (Entwicklung)
swift run

# Als richtige App bauen → build/PDFScan.app
./scripts/build-app.sh
cp -R build/PDFScan.app /Applications/

# Tests (OCR, Drehung, Leerseiten, PDF-Erzeugung)
swift test

# Handschrift-Varianten auf einem echten Scan vergleichen (gibt Text und Wörterbuch-Anteil je Variante aus)
swift run PDFScan --ocr-vergleich ~/Scans/Notiz.pdf
```

Alternativ baut GitHub Actions bei jedem Push eine fertige App (Apple Silicon und Intel). Sie liegt im
Workflow-Lauf unter **Artifacts → PDFScan**. Weil die App nur ad hoc signiert ist, muss man sie beim ersten Start
per Rechtsklick → „Öffnen“ starten oder vorher `xattr -dr com.apple.quarantine PDFScan.app` ausführen.

## Ablauf

1. Scanner einschalten. PDFScan wählt den FF-680W automatisch aus (Statusleiste: „Bereit“).
2. Blätter einlegen, **Scannen** drücken (⌘R).
3. Seiten prüfen und an jeder Stelle, an der ein neues Dokument beginnt, ⌘T drücken.
4. **Speichern** (⌘S). Die PDFs landen in `~/Dokumente/Scans/`, z. B. `Scan_2026_09_25_001_01.pdf`.

Der Zielordner, das Präfix, das Papierformat (Standard: automatisch), die Auflösung, Farbe/Graustufen, OCR-Sprachen und die JPEG-Qualität lassen sich unter
**PDFScan → Einstellungen** (⌘,) ändern.

## Automatische Trennung

Die Regeln und Schwellwerte stammen unverändert aus `reference/split_docs.py`. Ein Paritätstest prüft
die Swift-Portierung gegen das Original: `scripts/gen_split_parity.py` erzeugt 80 zufällige Sammelscans,
das Python-Skript bestimmt die Soll-Trennung, und `swift test` vergleicht. Wer die Python-Logik ändert,
kopiert sie nach `reference/`, erzeugt die Fälle neu und passt dann die Swift-Seite an, bis der Test grün ist.

Unterschiede zum Skript:
- Die Eingabe ist Vision-OCR statt der pdfplumber-Textebene. Die Zeilen werden nach ihrer Position sortiert,
  und als Randtext zählt alles, was vollständig in der 30-pt-Zone liegt.
- Senkrecht gedruckte Randtexte liest die App zusätzlich aus ausgeschnittenen und gedrehten Randstreifen.
- Die Postleitzahl-Regel für die Anschrift erkennt auch Orte mit Umlaut (Ö…, Ü…).
- Zusätzliche Regel **„kurzer Einzelzettel“**: Eine Seite mit weniger als 150 Zeichen Text, z. B. eine
  handschriftliche Notiz, wird ein eigenes Dokument, sofern sie nicht nach Briefschluss aussieht (Grußformel,
  Unterschrift). Die Seite danach beginnt ebenfalls neu. Der Paritätstest läuft ohne diese Regel.
- Die Anrede-Regel erkennt jede Anrede „Sehr geehrte… <Wort>“ und „Guten Tag …“. Das Original kennt nur Herr, Frau
  und Damen, damit wären z. B. Genossenschaftsbriefe mit „Sehr geehrtes Mitglied“ nie getrennt worden.
- Leerseiten werden vor dem Trennen herausgenommen. Sonst würden Duplex-Rückseiten als Einschübe gelten.
- Einschübe stehen in der Seitenliste direkt hinter ihrem Dokument.

## Tipps für alte Dokumente

- **Papierformat „Automatisch“** (Standard) schaltet die Größenerkennung des Scanner-Treibers ein. Beim
  Epson FF-680W heißt sie „Automatische Größenerkennung → Standardpapier“. Gemischte Formate im Stapel werden
  so jeweils in ihrer echten Größe erfasst. Bietet ein Treiber keine Größenerkennung, scannt die App in A4.
- **Ränder abgeschnitten?** Bei einem festen Papierformat muss es mindestens so groß sein wie das
  größte Blatt im Stapel. Kleinere Blätter bekommen dann einen Rand. Unter **Scanner → Scanner-Info…**
  steht, welche Formate der Treiber anbietet.

- **300 dpi** reichen für normale Schreibmaschinen- und Druckschrift. **400 dpi** lohnen sich bei sehr kleiner Schrift.
- **Graustufen** geben deutlich kleinere Dateien. Farbe lohnt sich bei Stempeln, Farbmarkierungen und Fotos.
- Dünnes, brüchiges oder eingerissenes Papier nicht durch den Einzug schicken. Den Epson-Trägerbogen verwenden oder
  das Blatt mit einem anderen Gerät scannen und dann importieren.
- Die OCR erkennt Druck- und Schreibmaschinenschrift gut. Lateinische Handschrift (Schulschrift, Druckbuchstaben)
  klappt mit dem Handschrift-Durchgang oft, bei unleserlicher Schrift nur teilweise. **Fraktur, Kurrent und
  Sütterlin** kann Apples Vision nicht lesen. Der Scan landet trotzdem im PDF, nur ohne durchsuchbaren Text.
- Für Handschrift lohnen sich **400 dpi**, besonders bei kleiner oder blasser Schrift.

## Aufbau

| Datei | Inhalt |
|---|---|
| `Sources/PDFScan/ScannerService.swift` | Scanner finden und steuern (ImageCaptureCore): Einzug, Duplex, Auflösung |
| `Sources/PDFScan/AppModel.swift` | Seitenliste, Hintergrundverarbeitung, Import, Speichern |
| `Sources/PDFScan/*View*.swift` | SwiftUI-Oberfläche und Einstellungen |
| `Sources/PDFScanCore/TextRecognizer.swift` | OCR und Erkennung der Ausrichtung (Vision) |
| `Sources/PDFScanCore/HandwritingRecognizer.swift` | Handschrift-Durchgang: Erkennung, Kontrastverstärkung, Zusammenführen |
| `Sources/PDFScanCore/BlankPageDetector.swift` | Erkennung von Leerseiten, robust gegen vergilbtes Papier |
| `Sources/PDFScanCore/SearchablePDFWriter.swift` | PDF mit Scan-Bild und unsichtbarer Textebene |
| `Sources/PDFScanCore/DocumentBoundaryDetector.swift` | Trennlogik, portiert aus `reference/split_docs.py` |
| `Sources/PDFScanCore/PageTextBuilder.swift` | Seitentext und Randtext aus der OCR, Randstreifen-Leser |
| `Sources/PDFScanCore/DocumentNaming.swift` | Dateinamen-Schema, Batch-Zähler, Aufteilung in Dokumente |
| `Sources/PDFScanCore/ImageOps.swift` | Bilder laden, drehen, skalieren, PDFs rastern |

**Warum keine PWA?** Browser können keine USB- oder WLAN-Scanner direkt ansteuern. Man müsste immer erst mit
Epson-Software scannen und die Dateien hochladen. Als native App steuert PDFScan den Scanner direkt an.
Außerdem sind OCR und PDF-Erzeugung auf dem Mac schneller und genauer.

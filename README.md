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
- **Automatisch aufrecht drehen**: Falsch herum eingelegte Seiten werden anhand des Textes erkannt und gedreht.
- **Leerseiten weglassen**: Unbedruckte Rückseiten beim Duplex-Scan werden erkannt und abgewählt. Man kann sie per
  Häkchen wieder aufnehmen.
- **In einzelne Dokumente trennen**: Ein Stapel wird an Trennstellen in mehrere PDFs aufgeteilt. Eine
  Trennstelle setzt man per ⌘T, über das Scheren-Symbol oder das Kontextmenü („Neues Dokument ab dieser Seite“).
- **Einheitliche Dateinamen**: `<Präfix><Jahr>_<Monat>_<Tag>_<Batch>_<Dokument>.pdf`, z. B.
  `Scan_2026_09_25_003_01.pdf`. Details siehe unten.
- Seiten **sortieren** (Drag & Drop), **drehen**, **löschen**, erkannten Text in der Vorschau prüfen.
- **Import** von Bildern (JPEG/PNG/TIFF/HEIC, auch mehrseitige TIFFs) und **bestehenden PDFs**, etwa alten Scans
  ohne Texterkennung oder Dateien aus Epson ScanSmart/FastFoto. Man kann sie auch einfach ins Fenster ziehen.
- Kompakte PDFs: Die Seiten werden als JPEG eingebettet (Qualität einstellbar), Seitengröße aus der Scan-Auflösung.

## Dateinamen

| Teil | Bedeutung |
|---|---|
| Präfix | frei einstellbar, Standard `Scan_` |
| `2026_09_25` | Datum des Speicherns |
| `003` | Batch: ein Speichervorgang, also ein Stapel. Beginnt jeden Tag bei 001 und wird aus den vorhandenen Dateien im Zielordner fortgesetzt, auch nach einem Neustart der App. |
| `01` | Dokument innerhalb des Batches, in der Reihenfolge der Trennstellen |

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
```

Alternativ baut GitHub Actions bei jedem Push eine fertige App (Apple Silicon und Intel). Sie liegt im
Workflow-Lauf unter **Artifacts → PDFScan**. Weil die App nur ad hoc signiert ist, muss man sie beim ersten Start
per Rechtsklick → „Öffnen“ starten oder vorher `xattr -dr com.apple.quarantine PDFScan.app` ausführen.

## Ablauf

1. Scanner einschalten. PDFScan wählt den FF-680W automatisch aus (Statusleiste: „Bereit“).
2. Blätter einlegen, **Scannen** drücken (⌘R).
3. Seiten prüfen und an jeder Stelle, an der ein neues Dokument beginnt, ⌘T drücken.
4. **Speichern** (⌘S). Die PDFs landen in `~/Dokumente/Scans/`, z. B. `Scan_2026_09_25_001_01.pdf`.

Der Zielordner, das Präfix, die Auflösung, Farbe/Graustufen, OCR-Sprachen und die JPEG-Qualität lassen sich unter
**PDFScan → Einstellungen** (⌘,) ändern.

## Tipps für alte Dokumente

- **300 dpi** reichen für normale Schreibmaschinen- und Druckschrift. **400 dpi** lohnen sich bei sehr kleiner Schrift.
- **Graustufen** geben deutlich kleinere Dateien. Farbe lohnt sich bei Stempeln, Farbmarkierungen und Fotos.
- Dünnes, brüchiges oder eingerissenes Papier nicht durch den Einzug schicken. Den Epson-Trägerbogen verwenden oder
  das Blatt mit einem anderen Gerät scannen und dann importieren.
- Die OCR erkennt Druck- und Schreibmaschinenschrift gut, Handschrift nur teilweise. **Fraktur und Sütterlin**
  erkennt sie nicht. Der Scan landet trotzdem im PDF, nur ohne durchsuchbaren Text.

## Aufbau

| Datei | Inhalt |
|---|---|
| `Sources/PDFScan/ScannerService.swift` | Scanner finden und steuern (ImageCaptureCore): Einzug, Duplex, Auflösung |
| `Sources/PDFScan/AppModel.swift` | Seitenliste, Hintergrundverarbeitung, Import, Speichern |
| `Sources/PDFScan/*View*.swift` | SwiftUI-Oberfläche und Einstellungen |
| `Sources/PDFScanCore/TextRecognizer.swift` | OCR und Erkennung der Ausrichtung (Vision) |
| `Sources/PDFScanCore/BlankPageDetector.swift` | Erkennung von Leerseiten, robust gegen vergilbtes Papier |
| `Sources/PDFScanCore/SearchablePDFWriter.swift` | PDF mit Scan-Bild und unsichtbarer Textebene |
| `Sources/PDFScanCore/DocumentNaming.swift` | Dateinamen-Schema, Batch-Zähler, Aufteilung in Dokumente |
| `Sources/PDFScanCore/ImageOps.swift` | Bilder laden, drehen, skalieren, PDFs rastern |

**Warum keine PWA?** Browser können keine USB- oder WLAN-Scanner direkt ansteuern. Man müsste immer erst mit
Epson-Software scannen und die Dateien hochladen. Als native App steuert PDFScan den Scanner direkt an.
Außerdem sind OCR und PDF-Erzeugung auf dem Mac schneller und genauer.

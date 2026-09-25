#!/usr/bin/env bash
# Baut PDFScan.app nach build/. Mit UNIVERSAL=1 für Apple Silicon und Intel.
set -euo pipefail
cd "$(dirname "$0")/.."

ARGS=(-c release --product PDFScan)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARGS+=(--arch arm64 --arch x86_64)
fi

swift build "${ARGS[@]}"
BIN_DIR="$(swift build "${ARGS[@]}" --show-bin-path)"

APP="build/PDFScan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PDFScan" "$APP/Contents/MacOS/PDFScan"
cp Support/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc-Signatur, damit macOS die App lokal startet.
codesign --force --sign - "$APP"

echo "Fertig: $APP"
echo "Installieren:  cp -R $APP /Applications/"

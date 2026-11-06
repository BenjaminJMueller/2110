#!/bin/bash
# Erstellt ein DMG mit der App, einer Verknüpfung zu „Programme“ und einer Kurzanleitung.
set -euo pipefail
APP="$1"
DMG="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Programme"
cp "$ROOT/packaging/DMG-LIESMICH.txt" "$STAGE/Bitte zuerst lesen.txt"
rm -f "$DMG"
hdiutil create -volname "ST 2110 Monitor" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
if [ "${SIGN_IDENTITY:--}" != "-" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
hdiutil verify "$DMG" >/dev/null && echo "DMG erstellt und geprüft: $DMG ($(du -h "$DMG" | cut -f1))"

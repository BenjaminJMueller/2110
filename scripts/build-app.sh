#!/bin/bash
# Baut „2110 Viewer.app“ und das DMG – reproduzierbar, ohne Homebrew.
#
# Voraussetzungen (nur auf dem Build-Mac): macOS 15+ auf Apple Silicon,
# Xcode 26 (für Liquid Glass; ältere Xcode-Versionen bauen ohne Glas-Effekte),
# Internetzugang zu gstreamer.freedesktop.org beim ersten Lauf.
#
# Umgebungsvariablen (optional):
#   SIGN_IDENTITY   "-" = ad-hoc (Standard, ohne Apple-Konto) oder
#                   "Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE  Schlüsselbund-Profil für notarytool (siehe scripts/notarize.sh)
#   BUNDLE_ID       Standard: io.github.benjaminjmueller.viewer2110
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP_NAME="2110 Viewer"
EXEC="ST2110Viewer"
BUNDLE_ID="${BUNDLE_ID:-io.github.benjaminjmueller.viewer2110}"
VERSION="${APP_VERSION:-$(cat VERSION)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "== GStreamer bereitstellen"
"$ROOT/scripts/fetch-gstreamer.sh"
export GSTREAMER_PREFIX="$ROOT/vendor/gstreamer"

echo "== Kompilieren (Release, arm64)"
swift build -c release --arch arm64 --product "$EXEC"
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "== App-Bundle zusammenstellen"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/$EXEC" "$APP/Contents/MacOS/$EXEC"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" -e "s/@BUNDLE_ID@/$BUNDLE_ID/" \
    packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

echo "== Symbol (packaging/icon/AppIcon.svg, gerendert als AppIcon-1024.png)"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s packaging/icon/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) packaging/icon/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "== GStreamer einbetten"
python3 scripts/bundle_gstreamer.py --prefix "$GSTREAMER_PREFIX" \
  --dest "$APP/Contents/Frameworks" \
  --plugin-dest "$APP/Contents/PlugIns" \
  --helpers-dest "$APP/Contents/Helpers" \
  --binary "$APP/Contents/MacOS/$EXEC" \
  --manifest "$APP/Contents/Resources/gstreamer-files.txt"
# Entwicklungs-rpath (absoluter Pfad zum vendor-Ordner) entfernen
install_name_tool -delete_rpath "$GSTREAMER_PREFIX/lib" "$APP/Contents/MacOS/$EXEC" 2>/dev/null || true
# Nur Apple Silicon ausliefern (halbiert die Größe)
while IFS= read -r -d '' f; do
  if lipo -info "$f" 2>/dev/null | grep -q "are:"; then
    lipo "$f" -thin arm64 -output "$f.thin" && mv "$f.thin" "$f"
  fi
done < <(find "$APP/Contents/Frameworks" "$APP/Contents/PlugIns" "$APP/Contents/Helpers" -type f -print0)
# Suchpfade für das flache Layout
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/Helpers/gst-plugin-scanner"
for f in "$APP/Contents/PlugIns/"*.dylib; do
  install_name_tool -add_rpath "@loader_path/../Frameworks" "$f"
done

echo "== Lizenzen"
mkdir -p "$APP/Contents/Resources/Licenses"
cp packaging/licenses/* "$APP/Contents/Resources/Licenses/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/"

echo "== Sprachen (Deutsch, Englisch)"
python3 scripts/gen-l10n.py "$APP/Contents/Resources"

echo "== Signieren ($SIGN_IDENTITY)"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
# Von innen nach außen: Bibliotheken, Plugins, Hilfsprogramme, dann die App
while IFS= read -r -d '' f; do
  codesign "${SIGN_ARGS[@]}" "$f"
done < <(find "$APP/Contents/Frameworks" "$APP/Contents/PlugIns" "$APP/Contents/Helpers" -type f \( -name "*.dylib" -o -perm -u+x \) -print0)
codesign "${SIGN_ARGS[@]}" --entitlements packaging/entitlements.plist "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "== Selbsttest des fertigen Bundles"
"$APP/Contents/MacOS/$EXEC" --selftest || { echo "Selbsttest fehlgeschlagen"; exit 1; }

echo "== Lizenzprüfung des Bundles"
python3 scripts/audit-bundle.py "$APP" --report "$DIST/license-audit-app.txt"

echo "== DMG"
"$ROOT/scripts/make-dmg.sh" "$APP" "$DIST/2110-Viewer-$VERSION.dmg"

echo "== Lizenzprüfung des DMG"
MNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DIST/2110-Viewer-$VERSION.dmg" >/dev/null
python3 scripts/audit-bundle.py "$MNT" --report "$DIST/license-audit-dmg.txt" || { hdiutil detach "$MNT" >/dev/null; exit 1; }
hdiutil detach "$MNT" >/dev/null

if [ -n "${NOTARY_PROFILE:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
  "$ROOT/scripts/notarize.sh" "$DIST/2110-Viewer-$VERSION.dmg"
else
  echo "Hinweis: nicht notarisiert (kein Developer-ID-Zertifikat/NOTARY_PROFILE). Siehe docs/04-Build-und-Verteilung.md."
fi
echo "Fertig: $DIST/2110-Viewer-$VERSION.dmg"

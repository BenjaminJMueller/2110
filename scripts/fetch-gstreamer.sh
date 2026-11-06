#!/bin/bash
# Lädt die offiziellen GStreamer-Pakete für macOS (gstreamer.freedesktop.org),
# prüft die SHA-256-Prüfsummen und entpackt die benötigten Teilpakete nach
# vendor/gstreamer – OHNE sie im System zu installieren (keine Adminrechte).
#
# Nur für den Build nötig. Endanwender brauchen GStreamer nicht: Die App
# enthält alle benötigten Bibliotheken.
set -euo pipefail

VERSION="${GST_VERSION:-1.28.8}"
# Prüfsummen von https://gstreamer.freedesktop.org/data/pkg/osx/1.28.8/*.sha256sum
RUNTIME_SHA="${GST_RUNTIME_SHA:-d371ab04a7632713626836c2fc234e863cc98484c74c473eba99b0fbd9b3a3fe}"
DEVEL_SHA="${GST_DEVEL_SHA:-e6d380bc17be7eccf13e0154567d4718fc9321da822408c7ca0cd808b3d4a3f7}"
BASE="https://gstreamer.freedesktop.org/data/pkg/osx/$VERSION"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DL="$ROOT/vendor/downloads"
OUT="$ROOT/vendor/gstreamer"
COMPONENTS="base-system-1.0 gstreamer-1.0-core gstreamer-1.0-net gstreamer-1.0-system"

if [ -f "$OUT/.version" ] && [ "$(cat "$OUT/.version")" = "$VERSION" ]; then
  echo "GStreamer $VERSION liegt bereits in $OUT"
  exit 0
fi
command -v pkgutil >/dev/null || { echo "pkgutil fehlt – dieses Skript läuft nur unter macOS."; exit 1; }
mkdir -p "$DL"

fetch() { # Datei, Prüfsumme
  local f="$1" sum="$2"
  if [ ! -f "$DL/$f" ] || [ "$(shasum -a 256 "$DL/$f" | cut -d' ' -f1)" != "$sum" ]; then
    echo "Lade $f …"
    curl -fL --retry 4 --retry-delay 3 -o "$DL/$f.part" "$BASE/$f"
    mv "$DL/$f.part" "$DL/$f"
  fi
  local got
  got="$(shasum -a 256 "$DL/$f" | cut -d' ' -f1)"
  if [ "$got" != "$sum" ]; then
    echo "Prüfsumme von $f stimmt nicht (erwartet $sum, erhalten $got)."; exit 1
  fi
  echo "Prüfsumme OK: $f"
}
fetch "gstreamer-1.0-$VERSION-universal.pkg" "$RUNTIME_SHA"
fetch "gstreamer-1.0-devel-$VERSION-universal.pkg" "$DEVEL_SHA"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rm -rf "$OUT"
mkdir -p "$OUT"
for kind in "" "-devel"; do
  pkg="$DL/gstreamer-1.0$kind-$VERSION-universal.pkg"
  pkgutil --expand-full "$pkg" "$TMP/x$kind"
  for c in $COMPONENTS; do
    dir="$TMP/x$kind/$c$kind-$VERSION-universal.pkg/Payload"
    [ -d "$dir" ] || { echo "Teilpaket fehlt: $c$kind"; exit 1; }
    ditto "$dir" "$OUT"
  done
done
echo "$VERSION" > "$OUT/.version"
test -f "$OUT/include/gstreamer-1.0/gst/gst.h" || { echo "Header fehlen"; exit 1; }
test -f "$OUT/lib/gstreamer-1.0/libgstrtp.dylib" || { echo "RTP-Plugin fehlt"; exit 1; }
echo "GStreamer $VERSION entpackt nach $OUT"

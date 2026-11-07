#!/bin/bash
# Stellt den vollständigen entsprechenden Quellcode aller in 2110 Viewer.app
# eingebetteten LGPL-/BSD-/MIT-Bibliotheken zusammen (LGPL-2.1 §6).
# Prüfsummen stammen aus den cerbero-Rezepten des Tags 1.28.8, mit dem die
# offiziellen GStreamer-macOS-Pakete gebaut wurden.
#
# Aufruf: scripts/fetch-third-party-sources.sh [Ausgabedatei.tar.gz]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/2110-Viewer-$(cat "$ROOT/VERSION")-third-party-sources.tar.gz}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/2110-viewer-third-party-sources"
mkdir -p "$SRC"

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
get() { # Name URL SHA256
  echo "Lade $1"
  curl -fsSL --http1.1 --retry 5 --retry-all-errors --retry-delay 3 -o "$SRC/$1" "$2"
  local got; got="$(sha "$SRC/$1")"
  if [ -n "$3" ] && [ "$got" != "$3" ]; then echo "Prüfsumme falsch für $1: $got"; exit 1; fi
  echo "$got  $1" >> "$SRC/SHA256SUMS"
}

get gstreamer-1.28.8.tar.xz          https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-1.28.8.tar.xz baa8e86985ad6417cc0ad6e7b79ff2884c6779c8b1c7a6240e7121822c86e524
get gst-plugins-base-1.28.8.tar.xz   https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-1.28.8.tar.xz ade70e3381fcbb024f1f20aa9ede9b5654aeed39d5bd70b1a98f53015e501117
get gst-plugins-good-1.28.8.tar.xz   https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-1.28.8.tar.xz a7670ed900d3d03be744d25c1873b239896e9a82ce6d17f8febc6fffbaee9521
get glib-2.82.4.tar.xz               https://download.gnome.org/sources/glib/2.82/glib-2.82.4.tar.xz 37dd0877fe964cd15e9a2710b044a1830fb1bd93652a6d0cb6b8b2dff187c709
get proxy-libintl-0.5.tar.gz         https://github.com/frida/proxy-libintl/archive/refs/tags/0.5.tar.gz f7a1cbd7579baaf575c66f9d99fb6295e9b0684a28b095967cfda17857595303
get orc-0.4.42.tar.xz                https://gstreamer.freedesktop.org/src/orc/orc-0.4.42.tar.xz 7ec912ab59af3cc97874c456a56a8ae1eec520c385ec447e8a102b2bd122c90c
get libffi-meson-3.2.9999.5.tar.bz2  https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi/-/archive/meson-3.2.9999.5/libffi-meson-3.2.9999.5.tar.bz2 b4d403932a8860589e571300e807e40bb4f7d9d2630c8ec19c29fb9e7b0fd227
get pcre2-10.42.tar.bz2              https://github.com/PhilipHazel/pcre2/releases/download/pcre2-10.42/pcre2-10.42.tar.bz2 8d36cd8cb6ea2a4c2bb358ff6411b0c788633a2a45dabbf1aeb4b701d1b5e840
get zlib-1.3.1.tar.gz                https://zlib.net/fossils/zlib-1.3.1.tar.gz 9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
# Build-Rezepte und Patches (gehören zum „entsprechenden Quellcode“)
get cerbero-1.28.8.tar.gz            https://gitlab.freedesktop.org/gstreamer/cerbero/-/archive/1.28.8/cerbero-1.28.8.tar.gz ""

cat > "$SRC/README.txt" <<'TXT'
Quellcode der in 2110 Viewer.app eingebetteten Drittanbieter-Bibliotheken
====================================================================
Die Binärdateien stammen aus den offiziellen GStreamer-1.28.8-Paketen für macOS
(https://gstreamer.freedesktop.org/data/pkg/osx/1.28.8/). Sie wurden mit cerbero
(Tag 1.28.8, enthalten) aus diesen Archiven gebaut; cerbero wendet die Patches aus
cerbero-1.28.8/recipes/** an. Nachbauen: cerbero-Dokumentation, Profil
„osx-universal“, Paket „gstreamer-1.0“. 2110 Viewer verwendet daraus die in
THIRD_PARTY_NOTICES.md aufgeführten Dateien unverändert.
TXT
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/LICENSE" "$SRC/"
mkdir -p "$(dirname "$OUT")"
tar -C "$WORK" -czf "$OUT" 2110-viewer-third-party-sources
echo "Quellpaket: $OUT ($(du -h "$OUT" | cut -f1))"

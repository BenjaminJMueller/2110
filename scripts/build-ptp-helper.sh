#!/bin/bash
# Baut gst-ptp-helper (GStreamer 1.28.8, Rust, MPL-2.0) aus dem Originalquelltext
# mit einer kleinen Änderung (packaging/patches/gst-ptp-helper-priority.patch):
# Das offizielle Programm ist für eine Installation mit Root-Rechten gedacht und
# bricht ohne sie beim Erhöhen der Priorität ab. Im App-Bundle läuft es ohne
# Root-Rechte; dann soll es mit normaler Priorität weiterlaufen.
#
# Aufruf: scripts/build-ptp-helper.sh <Ausgabedatei>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"
SHA=baa8e86985ad6417cc0ad6e7b79ff2884c6779c8b1c7a6240e7121822c86e524
TAR="$ROOT/vendor/downloads/gstreamer-1.28.8.tar.xz"

if ! command -v rustc >/dev/null; then
  [ -x "$HOME/.cargo/bin/rustc" ] && export PATH="$HOME/.cargo/bin:$PATH"
fi
command -v rustc >/dev/null || { echo "rustc fehlt (https://rustup.rs)"; exit 1; }

mkdir -p "$(dirname "$TAR")"
if [ ! -f "$TAR" ]; then
  curl -fsSL --http1.1 --retry 5 --retry-all-errors -o "$TAR" \
    https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-1.28.8.tar.xz
fi
got="$(shasum -a 256 "$TAR" 2>/dev/null | cut -d' ' -f1 || sha256sum "$TAR" | cut -d' ' -f1)"
[ "$got" = "$SHA" ] || { echo "Prüfsumme falsch: $got"; rm -f "$TAR"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -C "$WORK" -xf "$TAR" gstreamer-1.28.8/libs/gst/helpers/ptp
patch -p1 -d "$WORK/gstreamer-1.28.8/libs/gst/helpers" < "$ROOT/packaging/patches/gst-ptp-helper-priority.patch"
( cd "$WORK/gstreamer-1.28.8/libs/gst/helpers/ptp" &&
  rustc --edition 2018 -C panic=abort -C opt-level=2 -C strip=symbols \
        --cfg 'ptp_helper_permissions="none"' main.rs -o "$WORK/gst-ptp-helper" )
mkdir -p "$(dirname "$OUT")"
cp "$WORK/gst-ptp-helper" "$OUT"
chmod 755 "$OUT"
echo "gst-ptp-helper gebaut: $OUT"

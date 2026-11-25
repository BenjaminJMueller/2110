#!/bin/bash
# Erzeugt appcast.xml für Sparkle (Updates) zu einem fertigen DMG.
#
#   SPARKLE_PRIVATE_KEY=<base64> scripts/make-appcast.sh <dmg> <version> <build> <ausgabe.xml>
#
# Der private Schlüssel kommt aus dem GitHub-Secret SPARKLE_PRIVATE_KEY und wird
# nur über die Standardeingabe an sign_update gegeben, nie in eine Datei.
# Versionshinweise (optional): packaging/release-notes/<version>.de.html und .en.html
set -euo pipefail

DMG="$1"; VERSION="$2"; BUILD="$3"; OUT="$4"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="BenjaminJMueller/2110"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY fehlt}"

SIGN="$(find "$ROOT/.build/artifacts" -type f -path "*/bin/sign_update" -not -path "*old_dsa*" | head -1)"
if [ ! -x "$SIGN" ]; then
  # Rückfall: offizielles Paket laden und Prüfsumme wie in Sparkles Package.swift prüfen
  T="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$T/s.zip" https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip
  echo "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a  $T/s.zip" | shasum -a 256 -c -
  unzip -q "$T/s.zip" "bin/*" -d "$T"
  SIGN="$T/bin/sign_update"
fi

# Ausgabe: sparkle:edSignature="…" length="…"
ATTRS="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN" --ed-key-file - "$DMG")"
echo "$ATTRS" | grep -q 'sparkle:edSignature=' || { echo "Signatur fehlgeschlagen"; exit 1; }

# Gegenprobe: passt der Schlüssel aus dem Secret zum öffentlichen Schlüssel in der App?
PUB="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | swift "$ROOT/scripts/sparkle-public-key.swift")"
[ "$PUB" = "$(tr -d '[:space:]' < "$ROOT/packaging/sparkle-public-key.txt")" ] \
  || { echo "SPARKLE_PRIVATE_KEY passt nicht zu packaging/sparkle-public-key.txt"; exit 1; }
SIG="$(echo "$ATTRS" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN" --ed-key-file - --verify "$DMG" "$SIG"

NAME="$(basename "$DMG")"
URL="https://github.com/$REPO/releases/download/v$VERSION/$NAME"
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

notes() {
  local f="$ROOT/packaging/release-notes/$VERSION.$1.html"
  [ -f "$f" ] && printf '      <description xml:lang="%s"><![CDATA[%s]]></description>\n' "$1" "$(cat "$f")"
  return 0
}

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>2110 Viewer</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>2110 Viewer $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
$(notes de)$(notes en)
      <enclosure url="$URL" type="application/octet-stream" $ATTRS />
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$OUT" 2>/dev/null || python3 -c "import sys,xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])" "$OUT"
echo "appcast: $OUT ($URL)"

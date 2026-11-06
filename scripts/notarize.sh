#!/bin/bash
# Notarisierung durch Apple (nur mit kostenpflichtiger Apple-Developer-Program-
# Mitgliedschaft und „Developer ID Application“-Zertifikat möglich).
#
# Einmalig einrichten:
#   xcrun notarytool store-credentials "st2110-notary" \
#       --apple-id <Apple-ID> --team-id <TEAMID> --password <app-spezifisches Passwort>
# Dann: NOTARY_PROFILE=st2110-notary SIGN_IDENTITY="Developer ID Application: … (TEAMID)" scripts/build-app.sh
set -euo pipefail
DMG="$1"
: "${NOTARY_PROFILE:?NOTARY_PROFILE fehlt – siehe Kommentar oben.}"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
echo "Notarisiert und geheftet: $DMG"

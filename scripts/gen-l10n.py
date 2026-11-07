#!/usr/bin/env python3
"""Erzeugt die Sprachdateien des App-Pakets aus App/Localization/en.json.

Aufruf: gen-l10n.py <Contents/Resources>
  en.lproj/Localizable.strings  feste SwiftUI-Texte (Schlüssel = deutscher Text)
  en.lproj/InfoPlist.strings    Berechtigungstexte auf Englisch
  de.lproj/InfoPlist.strings    Berechtigungstexte auf Deutsch (aus Info.plist)
  Translations-en.json          Tabelle für zur Laufzeit zusammengesetzte Texte
"""
import json, os, plistlib, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
res = sys.argv[1]
table = json.load(open(os.path.join(root, "App/Localization/en.json"), encoding="utf-8"))

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

def write_strings(path, pairs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for k, v in pairs:
            f.write(f'"{esc(k)}" = "{esc(v)}";\n')

# Feste Texte: SwiftUI interpretiert „%“ in Schlüsseln als Formatangabe, daher nur Einträge ohne Platzhalter.
plain = sorted((k, v) for k, v in table.items() if "%" not in k)
write_strings(os.path.join(res, "en.lproj/Localizable.strings"), plain)
# Deutsch ist die Ausgangssprache. Ohne eigene Tabelle fiele macOS auf die Entwicklungssprache (Englisch) zurück.
write_strings(os.path.join(res, "de.lproj/Localizable.strings"), [(k, k) for k, _ in plain])

usage_en = {
    "NSLocalNetworkUsageDescription": "2110 Viewer looks for Blackmagic devices on the local network (NMOS) and receives their video and audio streams (multicast). Without this permission neither discovery nor reception is possible.",
    "NSCameraUsageDescription": "2110 Viewer sends the camera picture to the network as an ST 2110 video stream when you choose a camera as the source for sending.",
    "NSMicrophoneUsageDescription": "2110 Viewer sends the microphone sound as an ST 2110 audio stream when you choose a camera with sound as the source for sending.",
    "CFBundleGetInfoString": "Made for teaching. Includes GStreamer (LGPL).",
}
write_strings(os.path.join(res, "en.lproj/InfoPlist.strings"), sorted(usage_en.items()))
info = plistlib.load(open(os.path.join(root, "packaging/Info.plist"), "rb"))
write_strings(os.path.join(res, "de.lproj/InfoPlist.strings"),
              sorted((k, info[k]) for k in usage_en if k in info))

with open(os.path.join(res, "Translations-en.json"), "w", encoding="utf-8") as f:
    json.dump(table, f, ensure_ascii=False)
print(f"Sprachdateien: {len(plain)} feste Texte, {len(table)} Einträge gesamt")

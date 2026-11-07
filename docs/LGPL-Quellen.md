# Quellcode der eingebetteten Bibliotheken (LGPL)

Essenz.app enthält GStreamer und weitere Bibliotheken unter LGPL-2.1-or-later
(sowie BSD, MIT, zlib). Die vollständige Liste mit Versionen steht in
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

## So erfüllt das Projekt die LGPL

| Pflicht | Umsetzung |
|---|---|
| Hinweis auf die Bibliothek und ihre Lizenz | `THIRD_PARTY_NOTICES.md` und Lizenztexte in `Essenz.app/Contents/Resources/Licenses/`; außerdem auf dem DMG |
| Quellcode bereitstellen (§ 6) | Mit jeder Veröffentlichung liegt neben dem DMG `Essenz-<Version>-third-party-sources.tar.gz`: alle Upstream-Archive (Prüfsummen aus den cerbero-Rezepten) und **cerbero 1.28.8** mit allen Patches und Build-Rezepten. Erzeugt durch `scripts/fetch-third-party-sources.sh` im CI. |
| Austausch der Bibliothek ermöglichen | Dynamisch gelinkt, unveränderte Einzeldateien in `Contents/Frameworks` und `Contents/PlugIns`. Nach dem Ersetzen die App neu signieren (`codesign --force --deep --sign - Essenz.app`). |
| Keine Einschränkung durch die Lizenz des Hauptprogramms | Essenz steht unter MIT und schränkt Änderungen, Reverse Engineering zur Fehlersuche oder Austausch der LGPL-Bibliotheken nicht ein. |

## Nachbauen

```bash
tar xzf Essenz-1.0.0-third-party-sources.tar.gz
cd essenz-third-party-sources
shasum -a 256 -c SHA256SUMS
tar xzf cerbero-1.28.8.tar.gz && cd cerbero-1.28.8
./cerbero-uninstalled -c config/osx-universal.cbc package gstreamer-1.0
```

Essenz verwendet daraus nur die Dateien, die `scripts/bundle_gstreamer.py` auswählt.

## Prüfung jedes DMG

`scripts/audit-bundle.py` läuft bei jedem Build gegen die fertige App **und** das gemountete DMG:

* jede Binärdatei muss in einer Positivliste stehen, die sie einem Bestandteil und einer Lizenz zuordnet,
* für jede Lizenz muss der Lizenztext im Bundle liegen,
* Dateinamen von GPL-Plugins, Codecs (x264, libav, …) und Herstellerkomponenten (Blackmagic, DeckLink, …) führen zum Abbruch,
* unbekannte Dateien führen zum Abbruch.

Zusätzlich prüft `Essenz --selftest` die Lizenzangabe jedes geladenen GStreamer-Plugins (nur LGPL, BSD, MIT zulässig). Die Berichte (`license-audit-app.txt`, `license-audit-dmg.txt`) liegen bei den CI-Artefakten.

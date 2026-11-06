# ST 2110 Monitor

Native macOS-App (Apple Silicon, SwiftUI) zum **Empfangen, Ansehen und Abhören von SMPTE-ST-2110-Video und -Audio** von Blackmagic-2110-IP-Geräten über Ethernet, für Tests und Lehre im Medienlabor.

* unkomprimiertes **ST 2110-20** (YCbCr 4:2:2, 10/8 Bit, progressiv), Zielformate 1080p25 und 1080p50
* **ST 2110-30** Audio (L24/L16, 1–64 Kanäle, 1 ms/125 µs), Abhören von Einzelkanal oder frei wählbarem Stereopaar, Ausgabegerät wählbar
* **NMOS IS-04** Peer-to-Peer (mDNS, ohne Registry) bzw. mit Registry, Geräteadresse oder Adressbereich; **IS-05** Status und, nach Freischaltung, Steuerung
* SDP per Drag-and-drop, Datei, Einfügen oder Experteneingabe; getrennte Video- und Audio-SDP pro Quelle; Quellen werden gespeichert
* **Lippensynchrone** Wiedergabe über RTP-Zeitstempel, optional als passiver **PTP**-Slave; einfache Vorschau zum Vergleich
* Diagnose mit Paketverlusten, erkannten Parametern, PTP-Status und objektiver **Lippensynchron-Messung** (Blitz/Ton-Einsatz)
* Liquid Glass ab macOS 26, native Materialien ab macOS 14; Hell/Dunkel, Tastatur, VoiceOver
* **Ein DMG**: App in „Programme“ ziehen, fertig. GStreamer ist eingebettet; kein Homebrew, kein Terminal, keine Dienste.

## Dokumentation

| Dokument | Inhalt |
|---|---|
| [docs/01-Machbarkeit.md](docs/01-Machbarkeit.md) | Gerätebestand, Herstellerangaben zum 2110 IP Converter 3x3G, GStreamer-Prüfung, Ergebnis |
| [docs/02-Kompatibilitaet.md](docs/02-Kompatibilitaet.md) | unterstützte Modelle, Firmware, Formate mit Prüfstatus (dokumentiert/synthetisch/Hardware) |
| [docs/03-Synchronisation.md](docs/03-Synchronisation.md) | Vorschau vs. RTP-abgestimmt vs. PTP, Rolle im PTP-Netz, Messung |
| [docs/04-Build-und-Verteilung.md](docs/04-Build-und-Verteilung.md) | reproduzierbarer Build, DMG, Signierung, Notarisierung, Berechtigungen |
| [docs/05-Nutzeranleitung.md](docs/05-Nutzeranleitung.md) | Kurzanleitung für Anwender ohne Vorkenntnisse |
| [docs/06-Testplan.md](docs/06-Testplan.md) | Abnahmetests mit dem Equipment des Labors und Rückmeldevorlage |

## Prüfstatus dieser Version

| Bereich | dokumentiert | synthetisch getestet | mit Blackmagic-Hardware |
|---|---|---|---|
| Formate und Fähigkeiten des 3x3G | ✔ (Handbuch 09/2026, Techspecs) | – | **ausstehend** |
| SDP-Parser, Formatprüfung | ✔ | ✔ 75 Unit-Prüfungen | ausstehend |
| Empfang Video+Audio, Verlust, Neustart, Formatwechsel | | ✔ Loopback-Suite (Linux, CI) | ausstehend |
| Lippensynchronität RTP / PTP | ✔ ST 2059 | ✔ < 0,2 ms; PTP mit Software-Grandmaster | ausstehend |
| NMOS-Client, Gruppierung | ✔ IS-04/05 | ✔ Unit-Tests mit nachgebildeten Antworten | ausstehend |
| App-Build, Bundle, Selbsttest auf macOS | | ✔ GitHub Actions (macOS 26, Apple Silicon) | |
| Installation auf Mac ohne Entwicklerwerkzeuge | | | ausstehend (Testplan I1–I5) |

## Aufbau

```
core/            C-Empfangskern auf GStreamer-Basis (plattformneutral, Linux-Tests)
  src/           SDP, Multicast-Socket, Medienuhr, Empfangspipeline, Selbsttest
  tools/         st2110-probe (Kommandozeilen-Empfänger), st2110-testsender (synthetisch)
  tests/         Unit-, Loopback- und PTP-Tests
App/Sources/
  ST2110Kit/     NMOS-Client, Gruppierung, Adressbereiche, Diagnose, Quellen (testbar)
  ST2110Monitor/ SwiftUI-App, Metal-Renderer, CoreAudio, Netzwerkschnittstellen
scripts/         GStreamer laden, App bauen, einbetten, signieren, DMG, notarisieren
packaging/       Info.plist, Entitlements, Lizenztexte, DMG-Hinweise
```

Schnellstart Build: `./scripts/build-app.sh` auf einem Mac mit Xcode 26 oder das DMG-Artefakt aus GitHub Actions verwenden.

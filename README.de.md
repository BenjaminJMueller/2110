<p align="center"><img src="packaging/icon/AppIcon-1024.png" width="128" alt="2110-Viewer-Symbol"></p>

# 2110 Viewer

[English](README.md) | **Deutsch**

**ST 2110 am Mac empfangen, senden und analysieren.** Entstanden für die Lehre. Aktuell in der Entwicklung.

**[DMG laden](https://github.com/BenjaminJMueller/2110/releases/latest/download/2110-Viewer.dmg)** (macOS 14 oder neuer, Apple Silicon) | **[Webseite](https://benjaminjmueller.github.io/2110/)**

| Empfangen | Senden | Analysieren |
|---|---|---|
| ST 2110-20 (YCbCr 4:2:2, 10/8 Bit) und ST 2110-30 (bis 64 Kanäle) | Testbild, Lippensynchron-Test, Videodatei oder Kamera als ST 2110-20/-30 | pcap/pcapng mit ST-2110-Verkehr, angelehnt an EBU LIST |
| Quellen per NMOS IS-04 automatisch, oder SDP per Drag-and-drop | Kündigt sich als NMOS-Quelle an, verbindet Empfänger per IS-05 | Verluste, Paketabstände, Format ohne SDP, Cinst/VRX nach ST 2110-21 |
| Lippensynchron über RTP-Zeitstempel bzw. als passiver PTP-Slave | Zeitstempel vom PTP-Grandmaster, Pakete gleichmäßig verteilt | Audio-TS-DF, PTP-Domains und Grandmaster, IGMP-Querier, Vorschaubild |
| Einzelkanal oder freies Stereopaar abhören, Ausgabegerät wählbar; Bild randlos auf zweitem Bildschirm oder Beamer | Dateien dekodiert macOS selbst (H.264, HEVC, ProRes, AAC) | Mitschnitt direkt aus dem Empfang aufzeichnen |

Projektseite: https://benjaminjmueller.github.io/2110/

## Installation

DMG öffnen, **2110 Viewer** in **Programme** ziehen, starten. GStreamer und alle Bibliotheken sind in der App enthalten. Solange die App nicht notarisiert ist (es fehlt ein Apple-Developer-Konto), beim ersten Start einmal *Systemeinstellungen › Datenschutz & Sicherheit › Dennoch öffnen*. Details: [Nutzeranleitung](docs/05-Nutzeranleitung.md).

Die DMG liegt unter [Releases](https://github.com/BenjaminJMueller/2110/releases), zusammen mit dem Quellpaket der eingebetteten Bibliotheken und den Lizenzprüfberichten. Zwischenstände gibt es als Artefakt jedes CI-Laufs (Actions › „Build und Tests“ › *2110-Viewer-dmg*).

## Dokumentation

| | |
|---|---|
| [01 Machbarkeit](docs/01-Machbarkeit.md) | Gerätebestand, Herstellerangaben, GStreamer-Prüfung |
| [02 Kompatibilität](docs/02-Kompatibilitaet.md) | Modelle, Firmware, Formate mit Prüfstatus |
| [03 Synchronisation](docs/03-Synchronisation.md) | Vorschau, RTP-abgestimmt, PTP; Rolle im PTP-Netz |
| [04 Build und Verteilung](docs/04-Build-und-Verteilung.md) | reproduzierbarer Build, DMG, Signierung, Notarisierung |
| [05 Nutzeranleitung](docs/05-Nutzeranleitung.md) | für Anwender ohne Vorkenntnisse |
| [06 Testplan](docs/06-Testplan.md) | Abnahme mit dem Equipment, Rückmeldevorlage |
| [07 Netzwerkadapter](docs/07-Netzwerkadapter.md) | kompatible 10-GbE-Adapter in Deutschland mit Richtpreisen |
| [08 Analyse](docs/08-Analyse.md) | Messgrößen, Formeln, Grenzen |
| [09 Senden](docs/09-Senden.md) | Quellen, Zeitbezug, NMOS/IS-05, Datenraten |
| [LGPL-Quellen](docs/LGPL-Quellen.md) | Bereitstellung des Quellcodes der eingebetteten Bibliotheken |

## Aufbau

```
core/              C-Kern (GStreamer), plattformneutral, unter Linux getestet
  src/             SDP, Multicast-Socket, Medienuhr, Empfänger, Sender, Analyse, Selbsttest
  tools/           st2110-probe, st2110-send, st2110-analyze, st2110-testsender
  tests/           Unit-, Loopback-, Sender-, Analyse- und PTP-Tests
App/Sources/
  ST2110Kit/       NMOS-Client und -Knoten, Gruppierung, Adressbereiche, Diagnose (testbar)
  ST2110Viewer/    SwiftUI-App, Metal-Renderer, AVFoundation, CoreAudio
scripts/           GStreamer laden, App bauen, einbetten, prüfen, DMG, notarisieren, Quellpaket
packaging/         Info.plist, Symbol (SVG), Lizenztexte, DMG-Hinweise
site/              Projektseite (GitHub Pages)
```

## Bauen

```bash
./scripts/build-app.sh          # macOS mit Xcode 26, ergibt dist/2110 Viewer.app und dist/2110-Viewer-<Version>.dmg
make -C core && make -C core test   # Kern und Tests (Linux oder macOS mit pkg-config)
```

GitHub Pages: in den Repository-Einstellungen *Pages › Source: GitHub Actions* wählen; der Workflow `Webseite` veröffentlicht `site/` bei Änderungen auf `main`.

## Lizenz

Code: [MIT](LICENSE). Die App enthält GStreamer und weitere Bibliotheken unter LGPL-2.1, BSD, MIT und zlib, Einzelheiten stehen in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md). Das Repository enthält keine Herstellerdateien.

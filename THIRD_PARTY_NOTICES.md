# Third-Party Notices / Drittanbieter-Hinweise

2110 Viewer selbst steht unter der **MIT-Lizenz** (`LICENSE`). Dieses Dokument listet
**alle** fremden Bestandteile: was in der ausgelieferten App (DMG) steckt, was nur
beim Bauen oder Testen verwendet wird, und worauf sich das Projekt inhaltlich stützt.
Es wird unverändert in die App kopiert (`2110 Viewer.app/Contents/Resources/Licenses/`).

## 1 In der App enthalten (Binärverteilung)

Quelle: offizielle macOS-Pakete von GStreamer **1.28.8**, gebaut mit cerbero 1.28.8
(https://gstreamer.freedesktop.org/data/pkg/osx/1.28.8/). Unverändert, dynamisch
gelinkt, nur arm64-Teil. **Keine GPL-Bestandteile, keine Codec-Implementierungen**:
Video und Audio aus Dateien und von der Kamera dekodiert macOS selbst (AVFoundation).

| Bestandteil | Version | Dateien im Bundle | Lizenz | Lizenztext |
|---|---|---|---|---|
| GStreamer core (Bibliotheken `gstreamer`, `gstbase`, `gstnet`; Plugin `coreelements`; `gst-plugin-scanner`, `gst-ptp-helper`) | 1.28.8 | `Frameworks/libgst{reamer,base,net}-1.0.0.dylib`, `PlugIns/libgstcoreelements.dylib`, `Helpers/*` | LGPL-2.1-or-later | `LGPL-2.1.txt` |
| GStreamer Base Plugins (Bibliotheken `app`, `audio`, `video`, `rtp`, `tag`, `pbutils`; Plugins `app`, `audioconvert`, `audioresample`, `volume`, `videotestsrc`, `audiotestsrc`, `videoconvertscale`) | 1.28.8 | `Frameworks/libgst{app,audio,video,rtp,tag,pbutils}-1.0.0.dylib`, `PlugIns/…` | LGPL-2.1-or-later | `LGPL-2.1.txt` |
| GStreamer Good Plugins (`udp`, `rtp`, `osxaudio`) | 1.28.8 | `PlugIns/libgst{udp,rtp,osxaudio}.dylib` | LGPL-2.1-or-later | `LGPL-2.1.txt` |
| GLib, GObject, GIO, GModule | 2.82.4 (+ cerbero-Patches) | `Frameworks/lib{glib,gobject,gio,gmodule}-2.0.0.dylib` | LGPL-2.1-or-later | `LGPL-2.1.txt` |
| proxy-libintl (Tor Lillqvist) | 0.5 (+ cerbero-Patch) | `Frameworks/libintl.8.dylib` | LGPL-2.0-or-later (hier unter LGPL-2.1 genutzt) | `LGPL-2.1.txt` |
| ORC | 0.4.42 | `Frameworks/liborc-0.4.0.dylib` | BSD-2-Clause/BSD-3-Clause | `orc-BSD.txt` |
| libffi (GStreamer-meson-Port) | 3.2.9999.5 | `Frameworks/libffi.7.dylib` | MIT | `libffi-MIT.txt` |
| PCRE2 | 10.42 (+ cerbero-Patch) | `Frameworks/libpcre2-8.0.dylib` | BSD-3-Clause mit Bibliotheksausnahme | `pcre2-BSD.txt` |
| zlib | 1.3.1 (laut cerbero-Rezept) | `Frameworks/libz.1.dylib` | zlib | `zlib.txt` |

### LGPL: Quellcode und Austauschbarkeit

* Der vollständige entsprechende Quellcode (Upstream-Archive mit SHA-256 aus den
  cerbero-Rezepten **plus** cerbero 1.28.8 mit allen Patches und Build-Rezepten)
  wird mit jeder Veröffentlichung als `2110-Viewer-<Version>-third-party-sources.tar.gz`
  neben dem DMG bereitgestellt. Erzeugt wird er reproduzierbar mit
  `scripts/fetch-third-party-sources.sh`. Details: `docs/LGPL-Quellen.md`.
* Die LGPL-Bibliotheken sind separate, dynamisch gelinkte Dateien. Sie lassen sich
  durch eigene kompatible Builds ersetzen (danach die App neu signieren, z. B.
  `codesign --force --deep --sign - 2110 Viewer.app`). 2110 Viewer verbietet weder
  Reverse Engineering zur Fehlersuche an diesen Bibliotheken noch deren Austausch.

## 2 Vom Betriebssystem genutzt (nicht mitgeliefert)

SwiftUI, AppKit, Metal, MetalKit, CoreAudio, AVFoundation, VideoToolbox, Network,
SystemConfiguration (Apple, Teil von macOS). SF Symbols werden nur über die
Systemschnittstelle angezeigt; auf der Projektwebseite werden keine SF Symbols
verwendet.

## 3 Nur beim Bauen bzw. Testen (nicht im DMG)

| Werkzeug | Lizenz | Verwendung |
|---|---|---|
| Xcode / Swift-Toolchain | Apple-Lizenz bzw. Apache-2.0 (Swift) | Kompilieren |
| GStreamer-devel-Paket 1.28.8 | LGPL-2.1-or-later | Header, Linkbibliotheken |
| GStreamer (Ubuntu-Pakete), linuxptp (`ptp4l`, GPL-2.0) | LGPL / GPL | nur Linux-CI-Tests; nicht verteilt, nicht gelinkt |
| GitHub Actions (`actions/checkout`, `cache`, `upload-artifact`, `deploy-pages`) | MIT | CI |

## 4 Inhaltliche Grundlagen (kein übernommener Code)

* SMPTE ST 2110-10/-20/-21/-30/-40, ST 2059-1/-2, IETF RFC 4175, RFC 3190, RFC 7273,
  RFC 4566: Implementierung nach den Normen, keine Normtexte im Repository.
* AMWA NMOS IS-04/IS-05, BCP-002-01 (Apache-2.0): Implementierung nach Spezifikation,
  keine Dateien übernommen.
* EBU LIST: Vorbild für die Art der Analyse. **Kein Code übernommen**; die
  Messgrößen sind aus ST 2110-21 bzw. -30 selbst implementiert.
* Blackmagic Design: Herstellerangaben (Handbuch, technische Daten) werden in der
  Dokumentation **zitiert bzw. zusammengefasst und verlinkt**. Es sind **keine
  Herstellerdateien** (Handbücher, SDKs, Firmware, Treiber, Bilder, Logos, SDP- oder
  Konfigurationsdateien von Blackmagic) im Repository oder in der App enthalten.
  Test-SDPs und NMOS-Testantworten sind selbst erstellt.
* Gestaltung: Die Oberfläche folgt den Human Interface Guidelines von Apple
  (Systemsteuerelemente, Liquid Glass, SF Symbols). Einzelne Textregeln (z. B.
  sachliche Meldungen ohne Ausrufezeichen) gehen auf „unslop“ von Damir Sokolovsky
  (@heydamir, https://github.com/heydamir/unslop, CC BY 4.0) zurück; kein Code und
  keine Grafiken übernommen.

## 5 Marken

„Blackmagic Design“, „Blackmagic 2110 IP Converter“, „ATEM“, „HyperDeck“ sind
Marken von Blackmagic Design Pty. Ltd.; „Mac“, „macOS“, „Apple Silicon“, „Liquid
Glass“, „Thunderbolt“ (Intel) sind Marken ihrer Inhaber. Die Namen dienen nur der
Beschreibung der Kompatibilität. 2110 Viewer ist ein unabhängiges Projekt und weder mit
Blackmagic Design noch mit Apple verbunden.

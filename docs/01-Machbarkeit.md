# 1 Gerätebestand und Machbarkeitsprüfung

Stand: 6. November 2026

## 1.1 Erfasster Gerätebestand

| Angabe | Stand |
|---|---|
| Gerät | **Blackmagic 2110 IP Converter 3x3G** |
| Firmware | **noch offen**: bitte in „Blackmagic Converters Setup“ ablesen und im Testprotokoll eintragen |
| Videoformate im Einsatz | **noch offen**; Zielformate laut Auftrag 1080p25 und 1080p50, YCbCr 4:2:2 10 Bit |
| Netzwerk | Adressen und Bereiche sollen in der App einstellbar sein (umgesetzt) |
| PTP-Grandmaster, Switch, NMOS-Registry | **noch offen**; siehe Testplan, Abschnitt 0 |
| Apple-Developer-Konto | **nicht vorhanden**; Folgen siehe [04-Build-und-Verteilung](04-Build-und-Verteilung.md) |

## 1.2 Quellen

Geprüft wurden:

* **[H]** Blackmagic Design, *Installation and Operation Manual – Blackmagic 2110 IP Converters*, Fassung vom September 2026, abgerufen über documents.blackmagicdesign.com/UserManuals/Blackmagic2110IPConvertersManual.pdf.
* **[T]** Blackmagic Design, Technische Daten „Blackmagic 2110 IP Converter 3x3G“, blackmagicdesign.com/products/blackmagic2110ipconverter/techspecs, abgerufen am 6.11.2026.
* **[G]** Offizielle GStreamer-Pakete für macOS 1.28.8 (gstreamer.freedesktop.org/data/pkg/osx/1.28.8/). Die Pakete wurden entpackt und die Binärdateien untersucht (Architekturen, Abhängigkeiten, Plugin-Fähigkeiten).
* AMWA NMOS IS-04 v1.3, IS-05 v1.1, BCP-002-01; SMPTE ST 2110-10/-20/-21/-30, ST 2059-1/-2; RFC 4175, RFC 7273.

## 1.3 Was der 3x3G laut Hersteller sendet

| Frage | Ergebnis | Quelle |
|---|---|---|
| Videoformate | 720p50/59.94/60, 1080i50/59.94/60, 1080p23.98 … 1080p60 (kein SD, kein UHD) | [T] |
| Farbabtastung | „8, 10 RGB 4:4:4 in all modes up to 1080p30 and 8, 10-bit YUV 4:2:2 in all modes“ | [T] |
| Farbraum | Rec. 709 | [T] |
| Videokodierung | **SMPTE 2110-20 (unkomprimiert)**. Der 3x3G hat keinen Codec-Eintrag. **IP10** nennt Blackmagic nur für 12G-Modelle („used when converting 2160p59.94 and 2160p60“), also nicht für den 3x3G. | [T], [H] S. 33 |
| Sendeprofil | ST 2110-21 Sender **Narrow** | [T] |
| Audio | ST 2110-30, **Level C**, 48 kHz, 24 Bit, bis 16 eingebettete Kanäle je SDI-Kanal | [T] |
| Anzahl Ströme | 3 Video-Ein- und 3 Video-Ausgangskanäle bis 1080p60, jeweils mit Audio und Ancillary | [T] |
| Ancillary | ST 2110-40 (Timecode, Untertitel, HDR-Metadaten) | [T] |
| Ethernet | 1 × 10 Gbit/s RJ-45 (10GBASE-T, PoE+), punkt-zu-punkt oder über Switch | [T], [H] S. 80 f. |
| Multicast | IGMPv3, „managed 10G switch that supports IGMP version 3 snooping“; Adressen und Ports je Strom automatisch oder manuell | [H] S. 24, 32 |
| PTP | IEEE 1588-2008, ST 2059-1/-2; Domain „commonly 127“; Gerät kann **selbst Master werden**, wenn „PTP follower only“ nicht gesetzt ist | [T], [H] S. 25, 31 |
| NMOS | IS-04 v1.3.2 **Peer-to-Peer über mDNS/DNS-SD**, IS-05 v1.1.2, BCP-002-01 (Natural Grouping), BCP-004-01 | [T] |
| NMOS-Registry | optional: „can be entered manually or check auto to automatically discover“ | [H] S. 32 |
| ST 2022-7 | nicht beim 3x3G (nur SDI to HDMI 12G-10 und SDI Expander 8x12G) | [H] S. 26 |
| Weitere Steuerung | REST-API, Konfiguration per USB-C mit „Blackmagic Converters Setup“ | [T], [H] S. 27 |

**Nicht in der Dokumentation zu finden** (wird im Testplan am Gerät ermittelt):

* ob ein 16-Kanal-Audiostrom mit 125 µs oder ob zwei 8-Kanal-Ströme mit 1 ms gesendet werden. Rechnerisch passen 16 × 48 Abtastwerte × 3 Byte = 2304 Byte bei 1 ms nicht in ein Standard-Ethernet-Paket. 16 Kanäle in einem Strom bedingen daher 125 µs (ST 2110-30 Level C).
* wie die Geräte Sender und Gruppen in NMOS benennen und ob jeder Sender ein `manifest_href` (SDP) hat,
* der Port der NMOS-Node-API (wird über mDNS gemeldet, deshalb unkritisch),
* die Paketgröße (Standard-MTU oder Jumbo-Frames) und das Verhalten bei 1080i.

## 1.4 Konsequenzen für die App

| Thema | Entscheidung |
|---|---|
| Video | Unkomprimiertes ST 2110-20, YCbCr 4:2:2 10 und 8 Bit, progressiv: **unterstützt**. Geprüfte Zielformate sind 1080p25 und 1080p50; 720p und 1080p mit anderen Bildraten werden empfangen, sind aber nicht abgenommen. |
| 1080i, PsF | **Nicht unterstützt.** Der GStreamer-Depayloader `rtpvrawdepay` 1.28 meldet „interlaced formats not supported yet“ (im Binärcode nachgewiesen [G]). Die App erkennt das an der SDP und an den Paketköpfen (F-Bit) und meldet es mit Abhilfe: **Am SDI-Quellgerät ein progressives Format einstellen** (z. B. Kamera oder ATEM auf 1080p25/1080p50). Der 3x3G übernimmt das Format seines SDI-Eingangs; er hat keinen Formatwandler. |
| RGB 4:4:4 | **Nicht unterstützt** (GStreamer kann nur RGB mit 8 Bit, ungeprüft). Meldung mit Abhilfe: Quellgerät auf YUV 4:2:2 stellen. |
| IP10 / JPEG XS | Nicht unterstützt, wird erkannt und gemeldet. Für den 3x3G laut Hersteller nicht relevant. |
| Audio | ST 2110-30 L24/L16, 1–64 Kanäle, Paketzeit beliebig (1 ms und 125 µs geprüft). Kanalzahl und Paketzeit werden aus der SDP übernommen und **an den empfangenen Paketen nachgemessen**. |
| Erkennung | NMOS IS-04 Peer-to-Peer per mDNS (`_nmos-node._tcp`). **Eine Registry ist nicht nötig.** Zusätzlich: Registry (mDNS `_nmos-query._tcp` oder manuell), Geräteadresse manuell, Suche in einem einstellbaren Adressbereich. |
| Paarung Video/Audio | über BCP-002-01-Gruppen-Tags; ersatzweise über die Nummer in der Bezeichnung (als „vermutet“ gekennzeichnet); Audio frei zuordenbar. |
| Verbindungssteuerung | IS-05: Status lesen. Sender aktivieren bzw. Zieladresse setzen nur nach ausdrücklicher Freischaltung, weil das alle Empfänger betrifft. Für den Empfang am Mac ist kein IS-05-Receiver nötig: Der Mac tritt der Multicast-Gruppe selbst bei. |
| PTP | Der Mac nimmt nur als **passiver Slave** teil (GStreamer-PTP-Client, wird nie Master, sendet keine Announce-Nachrichten, nur Delay_Req). Das Produktionstiming bleibt unverändert. **Wichtig:** Läuft kein Grandmaster und ist am 3x3G „PTP follower only“ nicht gesetzt, wird der 3x3G selbst Master [H]. |
| Schnittstelle | 10GBASE-T am 3x3G passt direkt zu Thunderbolt-10-GbE-Adaptern (RJ-45), auch punkt-zu-punkt ohne Switch. |

## 1.5 GStreamer unter macOS / Apple Silicon (geprüft am Paket [G])

| Prüfpunkt | Ergebnis |
|---|---|
| Architektur | Universal (x86_64 + arm64), Mindestversion macOS 10.13, gebaut mit SDK 26.2 |
| Relokierbarkeit | alle Bibliotheken über `@rpath`, Plugins mit `@loader_path/../lib`, also ohne Installation in `/Library/Frameworks` in die App einbettbar |
| `rtpvrawdepay` | YCbCr-4:2:2 mit `depth=10` → Ausgabe `UYVP` (pgroup-Format); 8 Bit → `UYVY`; **kein Zeilensprung** |
| `rtpL24depay`/`rtpL16depay` | vorhanden (Plugin `rtp`) |
| `udpsrc` | vorhanden (Plugin `udp`). Den Multicast-Beitritt übernimmt die App selbst (siehe unten). |
| Audioausgabe | `osxaudiosink` (CoreAudio), Gerät wählbar |
| PTP | `gst-ptp-helper` (Rust) für macOS enthalten, ohne weitere Bibliotheksabhängigkeiten |
| Bildausgabe | Eigener Metal-Renderer: 10-Bit-Ausgabe, BT.709-Farbmanagement, keine OpenGL-Abhängigkeit |
| Lizenz | Benötigte Plugins und Bibliotheken: LGPL/BSD/MIT/zlib. Keine GPL-Bestandteile. Eingebettete Größe ca. 17 MB (arm64). |

**Eigenentwicklungen, wo GStreamer allein nicht reicht:**

1. *Multicast-Beitritt auf einer bestimmten Schnittstelle.* GLib tritt IPv4-Gruppen unter macOS ohne zuverlässige Schnittstellenwahl bei. Die App öffnet den Socket deshalb selbst (Beitritt über die IPv4-Adresse der gewählten Schnittstelle, `IP_BOUND_IF`, SSM bei Quellangabe) und übergibt ihn an `udpsrc`.
2. *Lippensynchronität.* Statt zwei unabhängiger Player setzt die App für jedes RTP-Paket den Ausgabezeitpunkt aus dem RTP-Zeitstempel (siehe [03-Synchronisation](03-Synchronisation.md)).

## 1.6 Ergebnis

Der Empfang von 1080p25/50, YCbCr 4:2:2 10 Bit, mit ST-2110-30-Audio vom 3x3G ist mit GStreamer unter macOS auf Apple Silicon **technisch machbar**. Es braucht weder Capture-Karte noch kostenpflichtige SDKs. Einschränkungen:

* **1080i wird nicht unterstützt.** Am Quellgerät muss progressiv eingestellt sein.
* 1080p50 erzeugt ca. 2,2 Gbit/s und rund 190 000 Pakete pro Sekunde. Ob ein Mac mit Thunderbolt-10-GbE-Adapter das dauerhaft verlustfrei empfängt, hängt von Adapter und Treiber ab. macOS begrenzt den Socket-Puffer ohne Administratoreingriff auf 8 MB. **Das muss am Gerät gemessen werden** (Testplan T4).
* Ohne Apple-Developer-Konto ist keine Notarisierung möglich. Der erste Start erfordert einmalig „Dennoch öffnen“.

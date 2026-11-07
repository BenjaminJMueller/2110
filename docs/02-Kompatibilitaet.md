# 2 Kompatibilität: Modelle, Firmware, Formate

**Legende:** **D** = nur dokumentiert (Herstellerangabe bzw. Norm) · **S** = synthetisch getestet (eigener Testsender, Linux bzw. macOS-CI) · **H** = mit Blackmagic-Hardware geprüft

> Stand dieser Version: **Es wurde noch nichts mit Blackmagic-Hardware geprüft.** Die Spalte H füllt sich mit Ihren Testergebnissen (siehe [06-Testplan](06-Testplan.md)).

## 2.1 Geräte

| Modell | Firmware | Status |
|---|---|---|
| Blackmagic 2110 IP Converter 3x3G | noch zu erfassen (Blackmagic Converters Setup › Setup › Software) | D (Handbuch 09/2026, Techspecs) · H ausstehend |
| andere Blackmagic-2110-Geräte (Mini BiDirect, SDI to HDMI 12G …) | – | nicht Gegenstand dieser Version. Bei 2160p59.94/60 senden die 12G-Modelle **IP10**, das wird nicht unterstützt. |

## 2.2 Videoformate (ST 2110-20, unkomprimiert)

| Format | Abtastung | Status | Hinweis |
|---|---|---|---|
| 1080p25 | YCbCr 4:2:2 10 Bit | **S**, H ausstehend | Zielformat |
| 1080p50 | YCbCr 4:2:2 10 Bit | **S** (synthetisch bis 720p50 verlustfrei; 1080p50 in der Linux-Testumgebung durch den Testsender begrenzt), H ausstehend | Zielformat, ca. 2,2 Gbit/s |
| 1080p23.98/24/29.97/30/59.94/60 | YCbCr 4:2:2 10 Bit | D, wird empfangen | nicht abgenommen; Hinweis in der App |
| 720p50/59.94/60 | YCbCr 4:2:2 10 Bit | S (720p50) | nicht abgenommen |
| 8 Bit 4:2:2 | YCbCr 4:2:2 8 Bit | D (Pfad implementiert) | |
| **1080i50/59.94/60** | – | **nicht unterstützt** | Abhilfe: Am SDI-Quellgerät 1080p25 oder 1080p50 einstellen |
| RGB 4:4:4 (bis 1080p30 laut Blackmagic) | – | **nicht unterstützt** | Abhilfe: Quellgerät auf YUV/YCbCr 4:2:2 stellen |
| Blackmagic IP10, JPEG XS (ST 2110-22) | – | **nicht unterstützt** | beim 3x3G laut Hersteller nicht verwendet |

## 2.3 Audio (ST 2110-30)

| Variante | Status |
|---|---|
| L24, 48 kHz, 16 Kanäle, 125 µs | S |
| L24, 48 kHz, 8 Kanäle, 1 ms | S |
| L24, 48 kHz, 2 Kanäle, 1 ms | S |
| L16 | D (Pfad implementiert) |
| AM824 (ST 2110-31) | nicht unterstützt |
| Tatsächliche Senderkonfiguration des 3x3G (Kanalzahl/Paketzeit je Strom) | **H ausstehend** (Testplan T2) |

## 2.4 Erkennung und Steuerung

| Funktion | Status |
|---|---|
| NMOS IS-04 Peer-to-Peer (mDNS `_nmos-node._tcp`) | D (Blackmagic-Angabe) · Client S (Unit-Tests mit nachgebildeten IS-04-Antworten) · H ausstehend |
| NMOS-Registry (Query API) | D · S (gleicher Code wie Node API) |
| Gruppierung Video/Audio (BCP-002-01) | D · S |
| SDP über `manifest_href` bzw. IS-05 `transportfile` | S |
| IS-05 Sender aktivieren/Ziel setzen | D, implementiert, nur nach Freischaltung · H ausstehend |
| Geräteadresse manuell / Adressbereichssuche | S (Parser) · H ausstehend |
| SDP-Datei, Drag-and-drop, Texteingabe, getrennte Video-/Audio-SDP | S |

## 2.5 Netzwerk und Zeit

| Funktion | Status |
|---|---|
| Multicast-Beitritt ASM und SSM auf gewählter Schnittstelle | S (Linux) · macOS-Pfad (IP_BOUND_IF) H ausstehend |
| PTP passiver Slave, Domain aus SDP/einstellbar | S (Software-Grandmaster linuxptp, Linux) · H ausstehend |
| Rückfall, wenn der Sender nicht zum Grandmaster passt | S |
| RTP-abgestimmte Lippensynchronität | S: Versatz < 0,2 ms an den Ausgabezeitstempeln |
| Senderneustart, Unterbrechung, Formatwechsel, Paketverlust | S |

## 2.6 Senden und Analyse

| Funktion | Status |
|---|---|
| Senden ST 2110-20 1080p25/50/29,97/59,94, 720p50/59,94 (10 Bit) | S (eigener Empfänger, Linux und macOS-CI) |
| Senden ST 2110-30 L24, 1–16 Kanäle, 1 ms/125 µs | S |
| Quellen Datei (AVFoundation) und Kamera | D – implementiert, auf echtem Mac zu prüfen (T13) |
| NMOS-Knoten (IS-04 Node API, mDNS) und IS-05 für Sender | S (Unit-Tests: eigener Client liest die Ressourcen) |
| IS-05: Empfänger am 3x3G verbinden | D – implementiert, **H ausstehend** (T11) |
| Analyse pcap/pcapng: Formate, Verluste, Cinst/VRX, TS-DF, PTP, IGMP | S |

## 2.7 Empfohlene Geräteeinstellungen (3x3G)

* **Videoformat:** am SDI-Quellgerät progressiv, 1080p25 oder 1080p50, YUV 4:2:2 10 Bit.
* **PTP:** Mit Grandmaster im Netz „PTP follower only“ aktivieren und Domain wie am Grandmaster (meist 127). Ohne Grandmaster darf genau ein Gerät Master sein. Die App wird nie Master.
* **Multicast:** Adressen je Strom eindeutig (Converters Setup › 2110 › Multicast Address). Am Switch IGMPv3-Snooping **mit Querier**.
* **NMOS:** Für die App genügt Peer-to-Peer (mDNS). Eine Registry ist optional.
* **Netz:** Mac und 3x3G im selben IP-Subnetz, damit mDNS und IGMP funktionieren.

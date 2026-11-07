# 9 Senden

[English](en/sending.md)

2110 Viewer sendet ST 2110-20 (YCbCr 4:2:2, 10 Bit) und ST 2110-30 (L24, 1–16 Kanäle). Empfänger können Blackmagic-Geräte sein, aber auch jedes andere ST-2110-Gerät.

## Quellen

| Quelle | Hinweise |
|---|---|
| Testbild | 75-%-Farbbalken, Graustufen, Laufbalken; Ton 1 kHz bei −18 dBFS |
| Lippensynchron-Test | Schwarzes Bild, weißer Blitz und Piep zu jeder vollen Sekunde (Zeitstempel). Am SDI-Ausgang des Converters mit Monitor und Smartphone-Zeitlupe prüfbar; der 2110-Viewer-Empfang misst ihn automatisch. |
| Videodatei | Alles, was macOS abspielen kann (z. B. H.264, HEVC, ProRes; Ton AAC/PCM). Dekodiert mit AVFoundation, skaliert auf das Sendeformat (Seitenverhältnis bleibt), in Echtzeit und in Schleife. 2110 Viewer liefert keine eigenen Codecs mit. |
| Kamera | Eingebaute oder USB-Kamera, Continuity-Kamera; Ton vom gewählten Mikrofon. macOS fragt nach Kamera- und Mikrofonzugriff. |

## Formate

1080p25, 1080p50, 1080p29,97, 1080p59,94, 720p50, 720p59,94. Der 3x3G gibt diese progressiven HD-Formate am SDI-Ausgang aus (laut technischen Daten). Audio: bis 8 Kanäle mit 1 ms, mehr Kanäle mit 0,125 ms (ST 2110-30 Level C).

## Zeitbezug

Mit dem Schalter „Zeit vom PTP-Grandmaster“ synchronisiert sich 2110 Viewer passiv auf den Grandmaster (nur Follower) und setzt die RTP-Zeitstempel auf die PTP-Zeit. Das ist die Voraussetzung dafür, dass Empfänger Bild und Ton zeitrichtig zuordnen. Ohne Grandmaster dient die Systemzeit als Näherung; die SDP nennt dann `ts-refclk:localmac`.

## Paketverteilung

Die Pakete eines Bildes werden gleichmäßig über die aktive Bildzeit verteilt (Profil „Narrow Linear“, `TP=2110TPNL`). 2110 Viewer taktet in Software. Auf einem stark ausgelasteten Rechner kann das burstiger ausfallen, als ST 2110-21 für Narrow verlangt; der Blackmagic 2110 IP Converter 3x3G akzeptiert laut technischen Daten als Empfänger Narrow, Wide und Asynchronous. Die Analyse zeigt, wie gleichmäßig der eigene Strom tatsächlich ist (Mitschnitt aufzeichnen und Cinst/VRX ansehen).

## Ans Gerät bringen

1. **NMOS (empfohlen):** 2110 Viewer kündigt sich als NMOS-Knoten per mDNS an (IS-04, Node API, und IS-05 für die Sender). Laut Blackmagic-Handbuch listet der 3x3G im LCD-Menü unter *Outputs* bzw. in Converters Setup die verfügbaren 2110-Ströme im Netz; ob dort auch der 2110-Viewer-Strom erscheint, wird in Test T10 geprüft. Ein NMOS-Controller sieht ihn ebenfalls. Mit Registry: Adresse unter Erweitert › NMOS eintragen, 2110 Viewer registriert sich dort.
2. **IS-05 direkt aus 2110 Viewer:** Unter „An ein Gerät senden“ den Empfänger wählen (z. B. „SDI Out 1“) und „Verbinden“. 2110 Viewer überträgt die SDP per IS-05 an den Empfänger.
3. **SDP-Datei:** SDP kopieren oder speichern und in das Zielgerät bzw. die Zielsoftware laden.

## Datenraten

| Format | Video | mit 16 Kanälen Audio |
|---|---|---|
| 1080p25 | ca. 1,07 Gbit/s | + 19 Mbit/s |
| 1080p50 | ca. 2,14 Gbit/s | + 19 Mbit/s |

Gesendet wird nur über kabelgebundene Ethernet-Schnittstellen sinnvoll; bei WLAN warnt 2110 Viewer.

## Geprüft

Synthetisch: Sender und Empfänger von 2110 Viewer gegeneinander (Format, Bildrate inkl. 29,97, 125 µs/1 ms, Lippensynchronität < 1 ms), Mitschnitt-Analyse des eigenen Stroms. NMOS-Ressourcen werden in Unit-Tests vom eigenen IS-04-Client gelesen. Mit Blackmagic-Hardware: **ausstehend** (Testplan T9–T12).

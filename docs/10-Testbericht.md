# 10 Testbericht: erster Test mit Blackmagic-Hardware

[English](en/test-report.md)

**Datum:** 25. November 2026  
**Ergebnis:** erfolgreich. 2110 Viewer empfängt ST 2110 vom Blackmagic 2110 IP Converter 3x3G und sendet ST 2110 an ihn; PTP und NMOS arbeiten mit dem Gerät zusammen.

## Aufbau

| Bestandteil | Gerät | Details |
|---|---|---|
| ST-2110-Gerät | Blackmagic 2110 IP Converter 3x3G („3x3G Stage #3“) | Software: neueste zum Testzeitpunkt, Blackmagic Converters 12.4.2 (4. November 2026); PTP-Grandmaster des Aufbaus (Domain 123, „PTP Follower Only“ aus); IP 192.168.88.3 |
| Switch | MikroTik CRS305-1G-4S+ | 4 × SFP+; Werkseinstellung (Bridge, ohne IGMP-Snooping); 10GBASE-T-Kupfermodule (mehrere Geschwindigkeiten) und ein 1-Gbit-Kupfermodul |
| Mac | MacBook Pro 16″ (Mac16,7), Apple M4 Pro, 24 GB Arbeitsspeicher | macOS 26.2 (25C56) |
| Netzwerkadapter am Mac | USB 10/100/1G/2.5G LAN (Realtek) | 2,5 Gbit/s ausgehandelt; IP 192.168.88.2/16 |
| SDI-Quelle | am Eingang SDI 1 des 3x3G | 1080p25 und 1080p60, YCbCr 4:2:2, 10 Bit |
| Software | 2110 Viewer 1.2.6/1.2.7 | Converters Setup zum Prüfen der Gerätewerte |

Vorher wurde der 3x3G auch direkt (ohne Switch) an den 2,5-G-Adapter angeschlossen.

## Ergebnisse

| Prüfpunkt | Ergebnis |
|---|---|
| Erkennung per NMOS IS-04 (mDNS, ohne Registry) | ✔ alle drei Sender und Empfänger des 3x3G erscheinen |
| SDP über NMOS laden | ✔ |
| PTP: Mac als passiver Follower | ✔ synchron zum 3x3G (Grandmaster 7C-2E-0D-FF-FE-20-96-EA, Domain 123) |
| Sender am Gerät per IS-05 einschalten | ✔ „Aktiv: ja“, danach sendet der 3x3G |
| Empfang vom 3x3G (1080p25) | ✔ Video kommt an; Verluste, solange ein Teil der Strecke nur 1 Gbit/s hatte |
| Senden aus der App an den 3x3G | ✔ Testbild 1080p25 am Ausgang des 3x3G (Empfänger in Converters Setup gewählt) |
| IS-05 „Verbinden“ eines Empfängers am 3x3G | ✔ technisch; 720p25 lehnt das Gerät ab („SDP format refused“) |

## Erkenntnisse

1. **Der 3x3G braucht zwingend eine 10-Gbit/s-Verbindung.** Mit 2,5 Gbit/s (Direktverbindung) und mit 1 Gbit/s (1G-SFP-Modul im Switch) zeigte das Display „N/C“, und das Gerät sendete nicht, auch nicht mit eingeschaltetem Sender. Verwaltung, NMOS und PTP liefen dabei weiter. Erst am 10G-Port sendete der 3x3G. Laut Datenblatt kann der Port 10M/100M/1G/10G; für ST 2110 ist 10G nötig.
2. **Sender ab Werk aus:** Die Sender des 3x3G meldeten in NMOS `master_enable: false`. Zusätzlich zur 10G-Verbindung müssen sie eingeschaltet werden (IS-05). Die App bietet dafür seit 1.2.8 „Einschalten …“ direkt unter dem Bild.
3. **Bandbreite zum Mac:** 1080p25 braucht etwa 1,1 Gbit/s, 1080p60 etwa 2,6 Gbit/s. Über eine 1-Gbit/s-Strecke zum Mac gehen viele Pakete verloren. Seit 1.2.8 warnt die App, wenn ein Strom nicht durch die Verbindung passt.
4. **Formate:** Der 3x3G nimmt nur SDI-Normformate an; 720p25 gehört nicht dazu.
5. **PTP-Domain:** Der 3x3G lief auf Domain 123 statt 127. Die App erkennt die Domain seit 1.2.4 automatisch.

## Im Test gefundene und behobene Fehler der App

| Version | Fehler | Behebung |
|---|---|---|
| 1.2.4 | PTP-Hilfsprogramm brach ohne Root-Rechte ab („Failed to set process priority“), dadurch kein PTP | eigenes Build des Hilfsprogramms, läuft mit normaler Priorität weiter |
| 1.2.4 | Domain 123 nicht einstellbar; SDP mit `localmac=00-00-…` | Domain frei bzw. automatisch; echte MAC-Adresse |
| 1.2.5 | SDP nannte „traceable“ statt der Grandmaster-ID | ID direkt von der PTP-Uhr |
| 1.2.6 | Absturz bei gleichzeitigem Senden und Empfangen | PTP wird von Sender und Empfang gemeinsam genutzt |
| 1.2.7 | „Sender aktivieren“ schaltete nur Video ein | Video und Audio |

## Noch offen

* Empfang 1080p50/60 und Lippensynchronität mit durchgehend 10 Gbit/s bzw. 2,5 Gbit/s zum Mac prüfen.
* Weitere Punkte aus dem [Testplan](06-Testplan.md).

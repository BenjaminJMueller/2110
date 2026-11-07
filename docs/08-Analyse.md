# 8 Paketmitschnitte analysieren

[English](en/analysis.md)

2110 Viewer analysiert pcap- und pcapng-Dateien mit ST-2110-Verkehr. Der Funktionsumfang orientiert sich an EBU LIST; der Code ist eigenständig. Der Schwerpunkt liegt auf der Fehlersuche, nicht auf der Wiedergabe.

## Woher kommt der Mitschnitt?

| Quelle | Zeitgenauigkeit | Geeignet für |
|---|---|---|
| Hardware-Mitschnitt (Capture-NIC mit PTP-Zeitstempeln, Spiegelport + Messgerät) | ns | alle Werte, auch ST 2110-21 |
| Wireshark/tcpdump am Mac oder PC | µs, Software | Verluste, Formate, PTP, IGMP; Zeitwerte nur als Richtwert |
| 2110 Viewer: Empfang › Diagnose › Aufzeichnen | Software, ns-Auflösung | wie oben; die Datei ist als Software-Mitschnitt gekennzeichnet |

Für die Bildrekonstruktion mindestens 1600 Byte je Paket mitschneiden (Snaplen).

## Was ausgewertet wird

| Bereich | Messgrößen |
|---|---|
| Mitschnitt | Format, Linktyp (Ethernet, VLAN, Linux cooked, Loopback), Dauer, Zeitauflösung, IP-Fragmente, gekürzte Pakete |
| Jeder RTP-Strom | Quelle/Ziel, SSRC, Payload-Typ, Datenrate, Verluste, Duplikate, Umsortierungen, SSRC-Wechsel, Paketabstände (Statistik, Histogramm, Verlauf) |
| Video (ST 2110-20) | Bildgröße und Bittiefe **ohne SDP** aus den Zeilenköpfen, Bildrate aus den RTP-Zeitstempeln, Pakete je Bild, Marker, Dauer der Paketverteilung, RTP-Latenz, **Cinst** und **VRX** mit Grenzwerten für Narrow und Wide, Vorschaubild |
| Audio (ST 2110-30) | Paketzeit, Kanalzahl (aus SDP oder geschätzt), **TS-DF** je Sekunde, RTP-Latenz |
| Zusatzdaten (ST 2110-40) | DID/SDID, z. B. Timecode, Untertitel |
| PTP | Domains, Grandmaster, Anzahl sendender Master (Warnung bei mehreren), Priorität, Clock Class, Sync-/Announce-Raten, Delay-Req/Resp, UTC-Versatz |
| IGMP | Querier, Abfragen (v2/v3), Beitritte und Austritte je Gruppe |

SDP-Dateien lassen sich mitgeben (`st2110-analyze --sdp`); in der App werden beim Aufzeichnen die SDPs der Quelle automatisch verwendet.

## Formeln (ST 2110-21:2017)

* Cinst: Eimermodell, je Paket +1, Abfluss ein Paket je `TDRAIN = (TFRAME/NPACKETS)/1,1`.
  Grenzwerte: `CMAX(N) = max(4, ⌊NPACKETS/(43200·RACTIVE·TFRAME)⌋)`, `CMAX(W) = max(16, ⌊NPACKETS/(21600·TFRAME)⌋)`.
* VRX: Empfänger liest ab dem ersten Paket eines Bildes ein Paket je `TRS = TFRAME·RACTIVE/NPACKETS`.
  Grenzwerte: `VRX_FULL(N) = max(8, ⌊NPACKETS/(27000·TFRAME)⌋)`, `VRX_FULL(W) = max(720, ⌊NPACKETS/(300·TFRAME)⌋)`.
  2110 Viewer richtet das VRX-Modell am ersten Paket aus (TRO aus dem Mitschnitt), nicht an der absoluten Bildzeit, weil diese einen PTP-synchronen Mitschnitt voraussetzt.
* `RACTIVE` = aktive Zeilen / Zeilen gesamt (1080/1125, 720/750).

## Kommandozeile

```bash
st2110-analyze mitschnitt.pcapng --sdp video.sdp --sdp audio.sdp --json > bericht.json
st2110-analyze mitschnitt.pcapng --thumb 1 bild.ppm
```

## Geprüft

Synthetisch: Mitschnitte des eigenen Senders (Software-Mitschnitt und tcpdump, auch mit künstlichem Verlust und IP-Fragmenten), PTP und IGMP mit linuxptp im Netz-Namespace. Mit Blackmagic-Mitschnitten: **ausstehend** (Testplan A1–A3).

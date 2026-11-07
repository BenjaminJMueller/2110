# 6 Testplan für das Equipment des Medienlabors

Ziel: Nachweis mit **echter Blackmagic-Hardware**. Bitte jede Zeile mit Ergebnis (✔/✘), Datum und, wo verlangt, dem **Diagnosebericht** (Diagnose › Bericht kopieren) zurückmelden. Vorlage: Abschnitt 8.

## 0 Bestandsaufnahme (vor den Tests ausfüllen)

| # | Angabe | Wert |
|---|---|---|
| 0.1 | Anzahl und Seriennummern der 2110 IP Converter 3x3G | |
| 0.2 | Firmware (Converters Setup › Setup › Software) | |
| 0.3 | Version „Blackmagic Converters Setup“ | |
| 0.4 | SDI-Quellen und deren Format (Kamera/ATEM …, z. B. 1080p50 YUV 4:2:2 10 Bit) | |
| 0.5 | Switch (Hersteller/Modell), IGMPv3-Snooping an? Querier an? | |
| 0.6 | PTP-Grandmaster (Modell, Domain, Profil) oder „keiner“ | |
| 0.7 | Am 3x3G: „PTP follower only“ an/aus, Domain | |
| 0.8 | NMOS-Registry vorhanden? Welche? | |
| 0.9 | Mac: Modell, Chip (M4 …), macOS-Version | |
| 0.10 | Netzwerkadapter (Hersteller/Modell, 10GBASE-T?) | |
| 0.11 | IP-Adresse Mac / 3x3G, Subnetz, DHCP oder statisch | |

## 1 Installation auf einem Mac ohne Entwicklungswerkzeuge

| # | Schritt | Erwartung |
|---|---|---|
| I1 | DMG aus dem Actions-Artefakt auf einen Mac **ohne Xcode, ohne Homebrew, ohne GStreamer** kopieren (Prüfen: `/Library/Frameworks/GStreamer.framework` existiert nicht) | |
| I2 | App nach „Programme“ ziehen, öffnen, ggf. „Dennoch öffnen“ | App startet, Einführung erscheint |
| I3 | Abfrage „Lokales Netzwerk“ | erscheint, nach „Erlauben“ keine weitere Abfrage |
| I4 | Demo-Modus | Farbbalken, Laufbalken, Blitz + Tick je Sekunde, „DEMO“ sichtbar, Pegel ca. −6 dBFS |
| I5 | Hilfe › Kurzanleitung, Erweitert › Info | GStreamer 1.28.8 „(in der App enthalten)“, keine fehlenden Komponenten |

## 2 Erkennung und Formate

| # | Schritt | Erwartung / zu notieren |
|---|---|---|
| T1 | Mac am Switch, App öffnen, 30 s warten | 3x3G-Eingänge erscheinen unter „Im Netzwerk gefunden“ (mDNS). Bezeichnungen, Format und Zahl der Audiosender notieren. |
| T1b | Falls nichts erscheint: Gerät per Adresse hinzufügen | erscheint; Hinweis an uns: mDNS im Netz blockiert? |
| T1c | Mit Registry (falls vorhanden): Erweitert › Registry eintragen | Quellen auch über Registry |
| T2 | Quelle SDI 1 mit **1080p25** auswählen | Bild + Ton; Diagnose: 1920×1080, 25,000 B/s, Audio-Kanalzahl und **Paketzeit (gemessen)** notieren; Bericht anhängen |
| T3 | Kanäle durchschalten (⌘]), Einzelkanal, freies Paar, Ausgabegerät wechseln (z. B. USB-Kopfhörer) | jeweils richtiger Kanal hörbar (am Quellgerät Kanäle unterschiedlich belegen, z. B. Ansage „Kanal 3“) |
| T4 | **1080p50** | Bild flüssig; nach 10 min Diagnose: Paketverluste Video (%)? Verworfene Bilder? Bericht anhängen |
| T5 | Quellgerät auf **1080i50** stellen | Meldung „Zeilensprung … nicht unterstützt“ mit Abhilfe |
| T6 | Format während der Wiedergabe von 1080p25 auf 1080p50 umstellen | App lädt über NMOS die neue SDP (Ereignis „Sender hat Parameter geändert“) und spielt weiter; bei SDP-Quelle: Formatmeldung |
| T7 | SDP-Datei: aus NMOS-URL (z. B. Browser: `http://<3x3G>/x-nmos/…`) oder Converters Setup speichern, ins Fenster ziehen; getrennte Video- und Audio-SDP zuordnen | Quelle spielbar, nach Neustart der App wieder vorhanden |
| T8 | Manuelle Eingabe (Experte) mit Adressen aus Converters Setup › 2110 | spielbar |

## 2b Senden an das Blackmagic-Gerät

| # | Schritt | Erwartung |
|---|---|---|
| T9 | Modus Senden, Testbild 1080p25, 2 Kanäle, PTP an, „Als NMOS-Quelle anbieten“ an, starten | Status „PTP, Grandmaster …“, Datenrate ca. 1,1 Gbit/s |
| T10 | Am 3x3G im LCD-Menü *Outputs* bzw. Converters Setup › 2110 › Receiver suchen | Essenz-Strom erscheint in der Liste; nach Auswahl Farbbalken und 1 kHz am SDI-Ausgang |
| T11 | Alternativ in Essenz „An ein Gerät senden › Verbinden“ (IS-05) | SDI-Ausgang zeigt Farbbalken; Ergebnis und ggf. Fehlermeldung notieren |
| T12 | Lippensynchron-Test senden, SDI-Ausgang auf Monitor mit Lautsprecher, Zeitlupe filmen | Blitz und Piep gleichzeitig (± 1 Bild) |
| T13 | Videodatei (H.264 MP4) und Kamera senden | flüssige Wiedergabe am SDI-Ausgang; „Verspätet gesendet“ und „Audiopuffer“ notieren |
| T14 | 1080p50 senden, mit Essenz (zweiter Mac) oder Analysator mitschneiden | ST-2110-21-Klasse, Cmax, Verluste notieren |

## 2c Analyse

| # | Schritt | Erwartung |
|---|---|---|
| A1 | Empfang 3x3G › Diagnose › „10 s aufzeichnen und analysieren“ | Analyse zeigt Video- und Audiostrom, Format ohne SDP korrekt, Vorschaubild richtig |
| A2 | Wireshark-Mitschnitt am Spiegelport (falls vorhanden) öffnen | PTP-Domain, Grandmaster, IGMP-Querier sichtbar; Ergebnis notieren |
| A3 | ST-2110-21-Klasse des 3x3G-Senders (laut Hersteller „Narrow“) mit Hardware-Mitschnitt | Klasse „Narrow“; bei Software-Mitschnitt nur Richtwert |

## 3 Synchronisation

| # | Schritt | Erwartung |
|---|---|---|
| S1 | Mit Grandmaster: Modus „Automatisch“ | Status „PTP-synchronisiert“; Diagnose: GM-ID = GM in SDP, Domain, Pfadverzögerung |
| S2 | Ohne Grandmaster bzw. falsche Domain | Rückfall „zeitlich abgestimmt (ohne PTP)“ mit verständlicher Meldung |
| S3 | **Lippensynchronität (objektiv):** Blitz/Piep-Testsignal am SDI-Eingang (Testsignalgenerator, ATEM-Mediaplayer oder HyperDeck-Clip mit weißem Blitz in der Bildmitte und gleichzeitigem Ton) | Diagnose › Lippensynchron-Messung: Mittelwert in **±5 ms** (Ausgabezeitstempel), in beiden Modi „Automatisch“ und „RTP“ |
| S4 | Gleiches Signal im Modus „Einfache Vorschau“ | Messwert notieren (zeigt den Unterschied für die Lehre) |
| S5 | **Lippensynchronität (Gesamtkette):** Bildschirm und Lautsprecher mit Smartphone-Zeitlupe (240 B/s) filmen | Versatz Blitz ↔ Ton-Beginn ≤ 1 Bild (EBU R37: Ton höchstens 40 ms früher, 60 ms später); ggf. Tonversatz einstellen und Wert notieren |
| S6 | PTP-Rolle: am Grandmaster bzw. Switch prüfen, dass der Mac **nicht** als Master erscheint | Mac nur als Slave/Follower sichtbar |

## 4 Zuverlässigkeit

| # | Schritt | Erwartung |
|---|---|---|
| R1 | **Dauerbetrieb 8 h** 1080p50 mit Audio | App bedienbar; Bericht am Ende: Verluste, verworfene Bilder, Neuausrichtungen, Drift, Speicher (Aktivitätsanzeige) |
| R2 | **Senderneustart:** 3x3G aus- und einschalten | „Signal unterbrochen“, danach automatisch wieder Bild und Ton, lippensynchron (S3 wiederholen) |
| R3 | **Verbindungsunterbrechung:** Netzwerkkabel am Mac 10 s ziehen und wieder stecken | Meldung, automatische Neuverbindung |
| R4 | SDI-Kabel am 3x3G ziehen | verständliche Meldung, Wiederaufnahme nach Einstecken |
| R5 | **Falsche Schnittstelle** (Erweitert › WLAN wählen) | Hinweis „Möglicherweise falsche Netzwerkschnittstelle“ bzw. „WLAN ausgewählt“ mit Vorschlag |
| R6 | **Kein Multicast:** IGMP-Querier am Switch abschalten oder falsche Gruppe | „Keine Daten empfangen“ + Liste möglicher Ursachen (als vermutet gekennzeichnet) |
| R7 | **Hohe Last:** während 1080p50 eine CPU-intensive App laufen lassen, Fenster vergrößern, Vollbild, Diagnose öffnen | Oberfläche reagiert; Verluste notieren |
| R8 | Lokales Netzwerk in den Systemeinstellungen verbieten, App neu starten | Meldung/Hinweis verständlich; nach Erlauben funktioniert es wieder |

## 5 Bedienung und Bedienungshilfen

| # | Schritt | Erwartung |
|---|---|---|
| B1 | Komplett mit Tastatur (Tab, Leertaste, ⌘-Kürzel) | alle Funktionen erreichbar |
| B2 | VoiceOver an (⌘F5) | Bedienelemente, Status, Pegel werden angesagt |
| B3 | Hell-/Dunkelmodus, „Transparenz reduzieren“, „Kontrast erhöhen“ | gut lesbar, Bild unverändert |
| B4 | macOS 26: Liquid Glass sichtbar nur an der Bedienleiste, nie über dem Bild (außer eingeblendeter Leiste im Vollbild) | |
| B5 | macOS 14/15 (falls verfügbar) | gleiche Funktionen, Materialien statt Glas |

## 6 Bildbeurteilung

| # | Schritt | Erwartung |
|---|---|---|
| V1 | SMPTE-Farbbalken 75 % vom Quellgerät, Vergleich mit Referenzmonitor am SDI-Ausgang | Farben plausibel (Mac-Display: BT.709-Farbmanagement durch macOS) |
| V2 | Graukeil/Rampe 10 Bit | keine Stufen über 8-Bit-Niveau hinaus (Ausgabe 10 Bit) |

## 7 Kommandozeilen-Prüfung (optional, für Betreuung)

Im Bundle liegt der Selbsttest: `"/Applications/Essenz.app/Contents/MacOS/Essenz" --selftest`.
Der Empfangskern ist auch als Werkzeug `st2110-probe` baubar (siehe 04); es zeichnet mit `--json` maschinenlesbare Ergebnisse auf.

## 8 Rückmeldevorlage

```
Test-ID:            (z. B. T4)
Datum, Tester:
Gerät/Firmware:
Ergebnis:           ✔ / ✘
Beobachtung:
Diagnosebericht:    (Bericht kopieren und hier einfügen)
```

Mit diesen Rückmeldungen werden in [02-Kompatibilitaet](02-Kompatibilitaet.md) die Einträge von „D/S“ auf „H“ gesetzt.

# 2110 Viewer – Kurzanleitung

Für alle, die Bild und Ton von Blackmagic-ST-2110-Geräten am Mac sehen und hören möchten. Programmierkenntnisse sind nicht nötig.

## Installieren (einmalig)

1. `2110-Viewer-….dmg` doppelklicken.
2. **2110 Viewer** auf **Programme** ziehen.
3. Die App aus „Programme“ öffnen. Meldet macOS, die App könne nicht überprüft werden, unter **Systemeinstellungen › Datenschutz & Sicherheit** auf **„Dennoch öffnen“** klicken. Das ist nur beim ersten Mal nötig.
4. Fragt macOS nach dem **lokalen Netzwerk**, bitte erlauben. Ohne diese Erlaubnis findet die App keine Geräte und empfängt nichts.

## Bild sehen und Ton hören

1. Den Mac über einen 10-GbE-Adapter (zum Beispiel für Thunderbolt) per Netzwerkkabel mit dem ST-2110-Switch verbinden oder direkt mit der Buchse „10G Ethernet“ am 2110 IP Converter 3x3G.
2. Die App öffnen.
3. Links unter **„Im Netzwerk“** erscheinen die Blackmagic-Eingänge, zum Beispiel „Studio Converter – SDI 1“. Einen davon anklicken.
4. Bild und Ton laufen jetzt. Unten in der Leiste zeigt ein grüner Punkt „Empfang, mit PTP synchronisiert“ oder „Empfang, zeitlich abgestimmt“.

| Bedienelement | Funktion | Tastatur |
|---|---|---|
| Start/Stopp | Wiedergabe | Leertaste, ⌘↩ |
| Kopfhörer-Menü | Kanalpaar (1+2, 3+4 …), Einzelkanal oder frei wählbares Paar | ⌘[ / ⌘] |
| Lautsprecher-Symbol, Regler | Stumm, Lautstärke | M, ⌘↑ / ⌘↓ |
| HiFi-Symbol | Audioausgabegerät (Standard: Systemausgang) | |
| Pfeile | Vollbild (Esc beendet) | ⌃⌘F |
| Zweiter Bildschirm (Symbolleiste) | Bild randlos auf Monitor oder Beamer, Bedienung bleibt im Hauptfenster | ⌘⇧B |
| Diagnose (Symbolleiste) | Formate, Paketverluste, Synchronisation, PTP, Aufzeichnen | ⌘I |
| Modus | Empfangen, Senden, Analysieren | ⌘1, ⌘2, ⌘3 |
| „?“ (Symbolleiste) | Erklärung „So funktioniert ST 2110“ | |
| Erweitert (Symbolleiste) | Netzwerk, Synchronisation, NMOS, Adressbereiche | ⌘, |

Die Pegelanzeige zeigt alle Kanäle; abgehörte Kanäle sind umrandet.

## Ausgabe auf einem zweiten Bildschirm

Monitor oder Beamer anschließen und in *Systemeinstellungen › Displays* „Erweitern“ (nicht „Spiegeln“) wählen. In der Symbolleiste **Zweiter Bildschirm** den Bildschirm wählen. Dort erscheint nur das Videobild, randlos und ohne Mauszeiger, im richtigen Seitenverhältnis mit schwarzen Rändern. Start, Kanäle, Lautstärke und Diagnose bleiben im Hauptfenster. ⌘⇧B schaltet die Ausgabe ein und aus (zuletzt benutzter Bildschirm). Wird der Bildschirm getrennt, schaltet sich die Ausgabe ab.

## Senden

Oben in der Symbolleiste **Senden** wählen (⌘2). Quelle wählen (Testbild, Lippensynchron-Test, Videodatei oder Kamera), Format und Audiokanäle einstellen, **Senden starten**. Unter „An ein Gerät senden“ lässt sich ein Blackmagic-Ausgang direkt verbinden; ansonsten den 2110-Viewer-Strom am Gerät auswählen. Details: [09-Senden](09-Senden.md).

## Analysieren

**Analysieren** (⌘3) öffnet pcap- oder pcapng-Mitschnitte (z. B. aus Wireshark). Beim Empfang erstellt **Diagnose › 10 s aufzeichnen und analysieren** einen Mitschnitt und öffnet ihn sofort. Links stehen die gefundenen Ströme, rechts Kennzahlen, ein Diagramm und verständliche Befunde. Details: [08-Analyse](08-Analyse.md).

## Darstellung

Hell, Dunkel oder wie das System: Einstellungen (⌘,) › Allgemein. Das Videobild bleibt unverändert.

## Wenn keine Quelle erscheint

* **„Gerät per Adresse hinzufügen …“** (Plus-Menü): IP-Adresse des 3x3G eintragen. Sie steht am Gerät im LCD-Menü unter Setup › Netzwerk.
* Oder eine **SDP-Datei** ins Fenster ziehen. Getrennte Video- und Audio-SDPs lassen sich zusammen ziehen bzw. im Fenster „Neue Quelle“ den Feldern **Video-SDP** und **Audio-SDP** zuordnen.
* Unter **Erweitert › NMOS & Adressen** kann ein Adressbereich (z. B. `192.168.10.1-254`) durchsucht werden.

Gespeicherte Quellen erscheinen beim nächsten Start unter „Gespeicherte Quellen“.

## Wenn kein Bild kommt

Die App zeigt im Bild und unter der Leiste, was sie **gemessen** hat (z. B. „Keine Daten empfangen“) und was **vermutlich** die Ursache ist (gekennzeichnet mit „vermutet“). Häufige Ursachen:

| Meldung | Was tun |
|---|---|
| Möglicherweise falsche Netzwerkschnittstelle | Erweitert › Netzwerk › Schnittstelle wählen, die im Netz der Blackmagic-Geräte liegt |
| WLAN ausgewählt | Kabelverbindung (10 GbE) verwenden |
| Keine Daten empfangen | Am Switch IGMP-Snooping mit Querier prüfen; Sender aktiv? Lokales Netzwerk erlaubt? |
| Zeilensprung (1080i) nicht unterstützt | Kamera/Mischer auf **1080p25** oder **1080p50** umstellen |
| RGB 4:4:4 nicht unterstützt | Quellgerät auf YUV 4:2:2 umstellen |
| Ohne PTP wiedergegeben | Bild und Ton bleiben lippensynchron; nur die Ausrichtung am Studiotakt fehlt |

Für Rückmeldungen: **Diagnose › Bericht kopieren** und den Text an die Betreuung schicken.

## Demo-Modus

**„Demo: Testbild und Testton“** (Seitenleiste unten) zeigt Farbbalken mit Laufbalken und einen Ton-Tick pro Sekunde, gleichzeitig mit einem weißen Blitz. Das ist deutlich als **DEMO** gekennzeichnet und nützlich, um Bildschirm, Ton und Bedienung ohne Netzwerk zu prüfen.

## Für die Lehre: Vorschau vs. synchron

Unter Erweitert › Synchronisation lässt sich „Einfache Vorschau“ wählen. Dann wird jeder Strom bei Ankunft ausgegeben. Mit einem Blitz/Piep-Testsignal zeigt die Diagnose, dass Bild und Ton dann **nicht** lippensynchron sind; im Modus „Automatisch“ sind sie es.

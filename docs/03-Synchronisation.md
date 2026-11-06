# 3 Synchronisation von Bild und Ton

## 3.1 Grundlage

Nach ST 2110-10 und ST 2059-1 ist der RTP-Zeitstempel eines Pakets
`floor(PTP-Zeit der Aufnahme × Taktrate) mod 2³²`. Video läuft mit 90 kHz, Audio mit 48 kHz. Die SDP verweist mit
`a=ts-refclk:ptp=IEEE1588-2008:<GM>:<Domain>` und `a=mediaclk:direct=0` darauf.
Video- und Audiopakete desselben Senders tragen damit Zeitstempel **derselben Uhr**. Daraus lässt sich für jedes Paket die Aufnahmezeit zurückrechnen. Der Zeitstempel wiederholt sich erst nach 13,2 h (Video) bzw. 24,8 h (Audio); eine grobe Referenzzeit genügt, um ihn eindeutig zu machen.

## 3.2 Die drei Betriebsarten der App

| Betriebsart | Was passiert | Lippensynchron? |
|---|---|---|
| **Einfache Vorschau** | Jeder Strom wird bei Ankunft ausgegeben (wie zwei unabhängige Player). | **Nein.** Unterschiedliche Laufzeiten bleiben stehen; in synthetischen Tests z. B. 25–200 ms. |
| **Zeitlich abgestimmt (RTP)** | Für jedes Paket wird die Aufnahmezeit aus dem RTP-Zeitstempel berechnet. Beide Ströme erhalten **denselben** Versatz zur Mac-Uhr und dieselbe feste Latenz. Die Abweichung zwischen Sender- und Mac-Uhr wird langsam nachgeführt (für beide Ströme gemeinsam). | **Ja**, sofern der Sender beide Ströme aus derselben Uhr stempelt. Das ist bei ST 2110 Pflicht. |
| **PTP-synchronisiert** (Standard „Automatisch“) | Der Mac läuft als passiver PTP-Slave. Die Wiedergabeuhr ist die PTP-Zeit des Grandmasters; Ausgabezeitpunkt = Aufnahmezeit + Latenz. | **Ja**, und am Studiotakt ausgerichtet. |

„Automatisch“ wartet bis zu 4 s auf einen Grandmaster und fällt sonst auf „Zeitlich abgestimmt“ zurück; die App meldet das. Liegen die Zeitstempel des Senders mehr als 1 s neben der PTP-Zeit, ist der Sender auf einen anderen Grandmaster, eine andere Domain oder eine andere Zeitskala synchronisiert. Auch dann fällt die App mit Meldung zurück, statt das Bild anzuhalten.

## 3.3 Rolle im PTP-Netz

Die App verwendet den PTP-Client von GStreamer. Er ist ein reiner **Slave-only-Teilnehmer**:
Er wertet Announce-, Sync- und Follow_Up-Nachrichten aus und sendet nur Delay_Req.
Er sendet nie Announce und kann **nicht Master werden**. Das Timing des Produktionsnetzes bleibt unverändert.

## 3.4 Latenz

Ein Videobild ist erst nach dem letzten Paket vollständig. Bei ST 2110-21 „Narrow“ ist das etwa eine Bilddauer nach der Aufnahme (40 ms bei 25p). Die Grundeinstellung ist 120 ms. Kommen Daten später, erhöht die App den Puffer automatisch bis höchstens 1000 ms und meldet das. Video und Audio werden dabei immer gemeinsam verzögert.

## 3.5 Manueller Tonversatz

Unter „Erweitert › Audio“ lässt sich der Ton um 0–500 ms verzögern, z. B. um die Verarbeitungszeit eines Bildschirms auszugleichen. Er **ersetzt keine Synchronisation** und ist in der Messung (3.6) nicht enthalten.

## 3.6 Messung der Lippensynchronität

Die App misst objektiv mit einem Testsignal, das am SDI-Eingang des 3x3G eingespeist wird: weißer Blitz in der Bildmitte und gleichzeitiger Ton-Einsatz, z. B. aus einem Testsignalgenerator oder einer passenden Clipdatei auf einem HyperDeck. Gemessen wird der Abstand zwischen Blitz und Ton-Einsatz an den **Ausgabezeitstempeln** der Pipeline. Die Latenz von Bildschirm und Audiogerät ist nicht enthalten. Für die Gesamtkette (inkl. Bildschirm) gibt es im Testplan zusätzlich eine Aufnahme mit einer Hochgeschwindigkeitskamera (Smartphone-Zeitlupe).

Synthetische Ergebnisse (Linux, Testsender mit ST-2059-artigen Zeitstempeln):

| Fall | Ergebnis |
|---|---|
| RTP-abgestimmt, 1080p25 + 16 ch | +0,0 … +0,1 ms |
| PTP (Software-Grandmaster) | +0,02 ms |
| Audio-Zeitstempel absichtlich +40 ms versetzt | +40,0 ms gemessen: Die App folgt den Zeitstempeln und gleicht nichts „heimlich“ aus. |
| Einfache Vorschau, gleicher Sender | −25 … −216 ms: **nicht synchron**, wie erwartet |

# Mitmachen

* Fehler und Testergebnisse bitte als Issue melden; für Hardwaretests gibt es die Vorlage „Testbericht“.
* Beiträge stehen unter der MIT-Lizenz des Projekts.
* Keine Herstellerdateien (Handbücher, SDKs, Firmware, Logos, Mitschnitte mit vertraulichen Inhalten) einchecken.
* Neue Drittanbieter-Bestandteile nur mit Eintrag in `THIRD_PARTY_NOTICES.md` und in der Positivliste von `scripts/audit-bundle.py`.
* Vor einem Pull Request: `make -C core && make -C core test` (Linux/macOS) und `swift test --filter ST2110KitTests` (macOS).

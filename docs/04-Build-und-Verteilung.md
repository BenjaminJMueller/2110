# 4 Build, Paketierung, Signierung und Verteilung

[English](en/build-and-distribution.md)

## 4.1 Für Endanwender

Endanwender laden nur das **DMG**, ziehen die App in „Programme“ und starten sie.
GStreamer und alle Bibliotheken stecken in der App (`Contents/Frameworks`, `Contents/PlugIns`, `Contents/Helpers`). Nichts wird in Systemordner installiert.

Systemvoraussetzungen: Mac mit Apple Silicon (M1 oder neuer, Ziel M4), **macOS 14 Sonoma oder neuer**.
Liquid-Glass-Oberfläche ab macOS 26; unter macOS 14/15 erscheinen dieselben Bedienelemente mit nativen Materialien.

## 4.2 DMG ohne eigenen Mac bauen: GitHub Actions

Jeder Push startet den Workflow `.github/workflows/macos.yml`. Er:

1. baut und testet den Empfangskern unter Linux (Unit-, Loopback- und Selbsttest),
2. lädt auf einem macOS-26-Runner die offiziellen GStreamer-Pakete und prüft die SHA-256-Prüfsummen,
3. führt die Swift-Unit-Tests aus,
4. baut die App, bettet GStreamer ein, signiert sie ad hoc und führt den **Selbsttest der fertigen App** aus (`2110 Viewer --selftest`: Demo, Loopback-Empfang, Lippensynchronität, PTP-Helfer),
5. erstellt das DMG und stellt es als Artefakt „2110-Viewer-dmg“ bereit (Actions › Lauf › Artifacts).

Hinweis: macOS-Minuten zählen bei privaten Repositories zehnfach gegen das Actions-Kontingent. Bei öffentlichen Repositories sind sie frei.

Eine Veröffentlichung (Release) mit DMG entsteht über *Actions › Build und Tests › Run workflow* mit der Option „Release“ oder durch ein Tag `v<Version>`.

## 4.3 Auf einem eigenen Mac bauen (reproduzierbar)

Voraussetzungen: Apple Silicon, macOS 15 oder neuer, **Xcode 26** (aus dem App Store; enthält Swift 6.2 und das macOS-26-SDK). Mit älterem Xcode wird ohne Liquid Glass gebaut.

```bash
git clone <Repository> && cd 2110
./scripts/build-app.sh
# Ergebnis: dist/2110 Viewer.app und dist/2110-Viewer-1.0.0.dmg
```

Was das Skript macht:

| Schritt | Skript |
|---|---|
| GStreamer 1.28.8 laden, Prüfsummen prüfen, ohne Installation nach `vendor/gstreamer` entpacken (`pkgutil --expand-full`) | `scripts/fetch-gstreamer.sh` |
| Kompilieren (Swift Package, Release, arm64) | `swift build` |
| Bundle, Info.plist, Symbol (`packaging/icon/AppIcon.svg` → PNG → icns) | `scripts/build-app.sh` |
| Lizenzprüfung von App und DMG | `scripts/audit-bundle.py` |
| Quellcode der eingebetteten Bibliotheken | `scripts/fetch-third-party-sources.sh` |
| benötigte Plugins und deren Abhängigkeiten kopieren (Liste in `bundle_gstreamer.py`), auf arm64 ausdünnen | `scripts/bundle_gstreamer.py` |
| Lizenztexte beilegen | `packaging/licenses`, `packaging/THIRD_PARTY.md` |
| Signieren (von innen nach außen) und prüfen | `codesign` |
| Selbsttest des fertigen Bundles | `--selftest` |
| Sprachdateien Deutsch und Englisch aus `App/Localization/en.json` | `scripts/gen-l10n.py` |
| DMG mit Verknüpfung „Applications“ und Kurzanleitung (Deutsch, Englisch) | `scripts/make-dmg.sh` |

Entwicklung in Xcode: `Package.swift` mit Xcode öffnen. Vorher einmal `./scripts/fetch-gstreamer.sh` ausführen; im Schema die Umgebungsvariable `GSTREAMER_PREFIX=<Repo>/vendor/gstreamer` setzen.

Empfangskern ohne App (Linux oder macOS mit pkg-config):

```bash
make -C core && make -C core test     # Unit-, Loopback-Tests
core/build/st2110-probe --help         # Kommandozeilen-Empfänger
```

## 4.4 Signierung und Notarisierung: aktueller Stand

**Es gibt kein Apple-Developer-Konto.** Folgen:

* Die App ist **ad hoc signiert**. Sie läuft auf Apple Silicon, wird aber von Gatekeeper beim ersten Start blockiert, wenn sie aus dem Internet geladen wurde.
* Einmalige Freigabe ohne Terminal: Systemeinstellungen › Datenschutz & Sicherheit › „Dennoch öffnen“ (macOS 15+); unter macOS 14 per ctrl-Klick › Öffnen. Das steht auch im DMG in „Bitte zuerst lesen.txt“.
* Wird das DMG per USB-Stick oder Netzlaufwerk statt per Browser verteilt, entfällt die Abfrage meist, weil dann kein Quarantäne-Attribut gesetzt wird.
* Nach jedem Update fragt macOS erneut nach „Lokales Netzwerk“ und gegebenenfalls nach der Firewall, weil sich die Ad-hoc-Signatur ändert.

**Für die reguläre Verteilung fehlen:**

1. Mitgliedschaft im **Apple Developer Program** (Organisation: Hochschule, D-U-N-S-Nummer nötig; 99 USD/Jahr),
2. ein Zertifikat **„Developer ID Application“** im Schlüsselbund des Build-Macs,
3. ein **app-spezifisches Passwort** bzw. API-Schlüssel für `notarytool`.

Danach genügt:

```bash
xcrun notarytool store-credentials st2110-notary --apple-id … --team-id … --password …
SIGN_IDENTITY="Developer ID Application: Hochschule … (TEAMID)" NOTARY_PROFILE=st2110-notary ./scripts/build-app.sh
```

Das Skript signiert dann mit Hardened Runtime und Zeitstempel, reicht das DMG zur Notarisierung ein und heftet das Ticket an. Für GitHub Actions müssen Zertifikat und Zugangsdaten als verschlüsselte Secrets hinterlegt werden; der Workflow ist dafür vorbereitet, aber nicht eingerichtet.

## 4.5 Updates (Sparkle)

Die App sucht einmal täglich nach neuen Versionen (abschaltbar unter *Erweitert › Info*) und installiert sie auf Wunsch selbst. Dafür ist [Sparkle](https://sparkle-project.org) 2.10.1 eingebettet (MIT).

- Die Versionsliste `appcast.xml` hängt am jeweils neuesten GitHub-Release; die App liest sie über `releases/latest/download/appcast.xml`.
- Jedes DMG ist mit einem EdDSA-Schlüssel (Ed25519) signiert. Den öffentlichen Teil enthält die App (`packaging/sparkle-public-key.txt`), sie installiert nur Updates mit passender Signatur. Das ersetzt bei der Ad-hoc-Signatur die fehlende Developer ID.
- Der private Schlüssel liegt ausschließlich als Repository-Secret `SPARKLE_PRIVATE_KEY` vor (*Settings › Secrets and variables › Actions*). Der Release-Lauf signiert damit das DMG und prüft, ob er zum öffentlichen Schlüssel passt. Fehlt das Secret, erscheint das Release ohne Update-Feed.
- Geht der private Schlüssel verloren, lassen sich bestehende Installationen nicht mehr aktualisieren; dann einmal neues Schlüsselpaar und manuelle Installation. Daher eine Kopie sicher aufbewahren (Passwortmanager).
- Versionshinweise im Update-Fenster: `packaging/release-notes/<Version>.de.html` und `.en.html`.

## 4.6 Berechtigungen der App

| Berechtigung | Wofür | Wie |
|---|---|---|
| Kamera, Mikrofon | nur beim Senden von einer Kamera | Systemabfrage, Begründungstext in der Info.plist |
| Lokales Netzwerk (macOS 15+) | NMOS-Erkennung (mDNS), HTTP zu den Geräten, Multicast-Empfang | Systemabfrage beim ersten Zugriff, Begründungstext in der Info.plist |
| Eingehende Verbindungen | nur bei eingeschalteter Firewall, für App und `gst-ptp-helper` | Systemabfrage |
| keine Sandbox | Multicast auf frei wählbarer Schnittstelle und PTP-Ports 319/320 sind in der App-Sandbox nicht möglich | nur für Developer-ID-Verteilung relevant (nicht App Store) |
| Administratorrechte | werden nicht benötigt | |

import AppKit
import ST2110Kit
import SwiftUI

/// „Erweitert“: alle technischen Parameter gebündelt.
struct AdvancedSettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("Allgemein", systemImage: "gearshape") }
            NetworkTab().tabItem { Label("Netzwerk", systemImage: "network") }
            SyncTab().tabItem { Label("Synchronisation", systemImage: "clock.arrow.2.circlepath") }
            AudioTab().tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            NMOSTab().tabItem { Label("NMOS & Adressen", systemImage: "point.3.connected.trianglepath.dotted") }
            AboutTab().tabItem { Label("Info", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 500)
        .buttonBorderShape(.capsule)
    }
}

private struct GeneralTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Darstellung", selection: $model.settings.appearance) {
                Text("Wie System").tag(0)
                Text("Hell").tag(1)
                Text("Dunkel").tag(2)
            }
            .pickerStyle(.segmented)
            Text("Das Videobild selbst bleibt in jeder Darstellung unverändert.").font(.caption).foregroundStyle(.secondary)
            Button("Erklärung „So funktioniert ST 2110“ zeigen") { model.explainerPage = 1; model.showOnboarding = true }
        }
        .formStyle(.grouped)
    }
}

private struct NetworkTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Netzwerkschnittstelle", selection: $model.settings.interfaceName) {
                Text("Automatisch (empfohlen)").tag("")
                ForEach(model.interfaces.interfaces, id: \.name) { i in
                    Text(tr(i.menuTitle)).tag(i.name)
                }
            }
            InfoRow("Gilt ab dem nächsten Start einer Quelle.", info: "„Automatisch“ wählt die Schnittstelle im Netz des Senders, sonst die schnellste kabelgebundene.")
            Toggle("Quellfilter (Source-Specific Multicast) verwenden, wenn die SDP eine Sender-IP nennt", isOn: $model.settings.useSourceFilter)
            Picker("Empfangspuffer", selection: $model.settings.socketBufferMB) {
                Text("Automatisch (so groß wie macOS erlaubt)").tag(0)
                Text("4 MB").tag(4)
                Text("8 MB").tag(8)
                Text("32 MB").tag(32)
            }
            Button("Schnittstellen neu einlesen") { model.interfaces.refresh() }
        }
        .formStyle(.grouped)
    }
}

private struct SyncTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Wiedergabe", selection: $model.settings.sync) {
                ForEach(AppSettings.SyncChoice.allCases) { Text(tr($0.title)).tag($0) }
            }
            .pickerStyle(.radioGroup)
            InfoRow("„Automatisch“ passt fast immer.", info: "Automatisch: Der Mac lauscht als passiver PTP-Follower (nur Slave, wird nie Master) und richtet Bild und Ton an der PTP-Zeit aus. Ohne Grandmaster werden Bild und Ton über ihre RTP-Zeitstempel zueinander ausgerichtet. „Einfache Vorschau“ gibt jeden Strom bei Ankunft wieder und ist nicht lippensynchron.")
            Picker("PTP-Domain", selection: $model.settings.ptpDomain) {
                Text("Aus SDP (sonst 127)").tag(-1)
                ForEach([0, 1, 127], id: \.self) { Text(tr("\($0)")).tag($0) }
            }
            Stepper(tr("Wartezeit auf PTP: \(model.settings.ptpTimeoutSeconds) s"), value: $model.settings.ptpTimeoutSeconds, in: 1...20)
            HStack {
                Text(tr("Wiedergabepuffer: \(model.settings.latencyMs) ms"))
                Slider(value: Binding(get: { Double(model.settings.latencyMs) }, set: { model.settings.latencyMs = Int($0) }), in: 40...1000, step: 10)
            }
            Toggle("Puffer bei verspäteten Daten automatisch erhöhen", isOn: $model.settings.autoLatency)
        }
        .formStyle(.grouped)
    }
}

private struct AudioTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Ausgabegerät", selection: $model.settings.audioDeviceUID) {
                Text("Systemausgang").tag("")
                ForEach(model.audioDevices.devices) { Text(tr($0.name)).tag($0.uid) }
            }
            HStack {
                Text(tr("Manueller Tonversatz: \(model.settings.audioDelayMs) ms"))
                Slider(value: Binding(get: { Double(model.settings.audioDelayMs) }, set: {
                    model.settings.audioDelayMs = Int($0)
                    model.player.setAudioDelay(Int($0))
                }), in: 0...500, step: 5)
            }
            InfoRow("Gleicht verzögernde Bildschirme aus.", info: "Gleicht z. B. die Verzögerung eines Bildschirms aus. Ersetzt keine korrekte Synchronisation; die Lippensynchron-Messung in der Diagnose erfolgt ohne diesen Versatz.")
            Button("Versatz zurücksetzen") {
                model.settings.audioDelayMs = 0
                model.player.setAudioDelay(0)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NMOSTab: View {
    @Environment(AppModel.self) private var model
    @State private var scanResult: String?
    @State private var newNode = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Erkennung") {
                Toggle("Automatisch per mDNS/DNS-SD suchen (Peer-to-Peer, ohne Registry)", isOn: $model.settings.mdnsDiscovery)
                TextField("NMOS-Registry (optional, z. B. 192.168.10.5 oder URL)", text: $model.settings.registryURL)
            }
            Section("Geräteadressen") {
                ForEach(model.settings.manualNodes, id: \.self) { n in
                    HStack {
                        Text(tr(n))
                        Spacer()
                        Button("Entfernen") { model.settings.manualNodes.removeAll { $0 == n } }.controlSize(.small)
                    }
                }
                HStack {
                    TextField("Adresse hinzufügen", text: $newNode)
                    Button("Hinzufügen") {
                        let t = newNode.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty, !model.settings.manualNodes.contains(t) { model.settings.manualNodes.append(t) }
                        newNode = ""
                    }
                }
            }
            Section("Adressbereich durchsuchen") {
                TextField("Bereiche, z. B. 192.168.10.1-254, 10.0.0.0/24", text: $model.settings.scanRanges)
                TextField("Ports", text: $model.settings.scanPorts)
                HStack {
                    Button("Jetzt durchsuchen") {
                        Task { scanResult = await model.discovery.scan(ranges: model.settings.scanRanges, ports: model.settings.scanPorts) }
                    }
                    .disabled(model.discovery.isScanning || model.settings.scanRanges.isEmpty)
                    if model.discovery.isScanning { ProgressView(value: model.discovery.scanProgress).frame(width: 160) }
                    if let scanResult { Text(tr(scanResult)).font(.caption) }
                }
            }
            Section("Multicast") {
                TextField("Erlaubter Multicast-Bereich", text: $model.settings.multicastRange)
                InfoRow("Gilt für manuelle Eingabe und IS-05.", info: "Wird bei manueller Eingabe und beim Setzen von Zieladressen über IS-05 geprüft.")
                Toggle("Sender über NMOS IS-05 verändern dürfen (aktivieren, Zieladresse setzen)", isOn: $model.settings.allowSenderControl)
                Text("Wirkt auf das Gerät und damit auf alle Empfänger.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Section("Status") {
                Text(tr("mDNS: \(model.discovery.browserState)")).font(.caption)
                ForEach(model.discovery.endpoints, id: \.base) { e in
                    Text(tr("\(e.origin.rawValue): \(e.base.absoluteString)\(model.discovery.errors[e.base].map { " – \($0)" } ?? "")"))
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            LabeledContent("App-Version", value: model.appVersion)
            LabeledContent("GStreamer", value: GStreamerEnvironment.version + (GStreamerEnvironment.bundled ? " (in der App enthalten)" : " (Entwicklungsumgebung)"))
            if !GStreamerEnvironment.missingPlugins.isEmpty {
                LabeledContent("Fehlende Komponenten", value: GStreamerEnvironment.missingPlugins)
            }
            LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            Section("Lizenzen") {
                LicenseLink(name: "2110 Viewer", license: "MIT", url: "https://github.com/BenjaminJMueller/2110/blob/main/LICENSE")
                LicenseLink(name: "GStreamer 1.28", license: "LGPL-2.1", url: "https://gstreamer.freedesktop.org/documentation/frequently-asked-questions/licensing.html")
                LicenseLink(name: "GLib", license: "LGPL-2.1", url: "https://gitlab.gnome.org/GNOME/glib/-/blob/main/COPYING")
                LicenseLink(name: "ORC", license: "BSD", url: "https://gitlab.freedesktop.org/gstreamer/orc/-/blob/main/COPYING")
                LicenseLink(name: "libffi", license: "MIT", url: "https://github.com/libffi/libffi/blob/master/LICENSE")
                LicenseLink(name: "PCRE2", license: "BSD", url: "https://github.com/PCRE2Project/pcre2/blob/master/LICENCE.md")
                LicenseLink(name: "zlib", license: "zlib", url: "https://zlib.net/zlib_license.html")
                LicenseLink(name: "GNU LGPL 2.1 (Volltext)", license: "", url: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html")
                LicenseLink(name: "Alle Drittanbieter-Hinweise", license: "", url: "https://github.com/BenjaminJMueller/2110/blob/main/THIRD_PARTY_NOTICES.md")
                LicenseLink(name: "Quellcode der eingebetteten Bibliotheken", license: "", url: "https://github.com/BenjaminJMueller/2110/releases/latest")
                Button("Lizenztexte in der App zeigen") {
                    let dir = Bundle.main.resourceURL?.appendingPathComponent("Licenses")
                    if let dir, FileManager.default.fileExists(atPath: dir.path) { NSWorkspace.shared.open(dir) }
                }
            }
            Button("Einführung erneut anzeigen") { model.showOnboarding = true }
        }
        .formStyle(.grouped)
    }
}

/// Zeile mit Name, Lizenz und Link.
private struct LicenseLink: View {
    let name: String
    let license: String
    let url: String

    var body: some View {
        HStack {
            Text(tr(name))
            Spacer()
            if !license.isEmpty { Text(license).foregroundStyle(.secondary) }
            if let u = URL(string: url) {
                Link(destination: u) { Image(systemName: "arrow.up.right.square") }
                    .help(url)
            }
        }
    }
}

/// Kurzer Hinweis mit Info-Knopf für die ausführliche Erklärung.
struct InfoRow: View {
    let short: String
    let info: String
    init(_ short: String, info: String) { self.short = short; self.info = info }
    var body: some View {
        HStack(spacing: 4) {
            Text(tr(short)).font(.caption).foregroundStyle(.secondary)
            InfoButton(text: info)
        }
    }
}

import SwiftUI
import ST2110Kit

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                if model.discovery.sources.isEmpty {
                    DiscoveryEmptyRow()
                } else {
                    ForEach(model.discovery.sources) { s in
                        DiscoveredRow(source: s)
                            .tag(SidebarItem.discovered(s.id))
                    }
                }
            } header: {
                HStack {
                    Text("Im Netzwerk gefunden (NMOS)")
                    Spacer()
                    if model.discovery.isScanning { ProgressView().controlSize(.mini) }
                }
            }

            Section("Gespeicherte Quellen") {
                if model.saved.isEmpty {
                    Text("SDP-Dateien hierher ziehen oder mit ＋ hinzufügen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.saved.sorted(by: { ($0.lastUsed ?? $0.createdAt) > ($1.lastUsed ?? $1.createdAt) })) { s in
                        SavedRow(source: s)
                            .tag(SidebarItem.saved(s.id))
                            .contextMenu {
                                Button("Bearbeiten …") { model.edit(s.id) }
                                Button("Duplizieren") { model.duplicate(s.id) }
                                Divider()
                                Button("Löschen", role: .destructive) { model.delete(s.id) }
                            }
                    }
                }
            }

            Section("Test") {
                Label {
                    VStack(alignment: .leading) {
                        Text("Demo: Testbild und Testton")
                        Text("Ohne Netzwerk – zum Prüfen von Bild, Ton und Bedienung")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "testtube.2")
                }
                .tag(SidebarItem.demo)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("SDP-Datei öffnen …") { model.showImporter = true }
                    Button("SDP aus Zwischenablage einfügen") { model.pasteSDP() }
                    Button("Neue Quelle (Video- und Audio-SDP) …") { model.newSource() }
                    Divider()
                    Button("NMOS-Gerät per Adresse hinzufügen …") { model.showAddNode = true }
                    Button("Manuelle Eingabe (Experte) …") { model.showManualEntry = true }
                } label: {
                    Label("Quelle hinzufügen", systemImage: "plus")
                }
                .help("Quelle hinzufügen")
            }
        }
    }
}

private struct DiscoveryEmptyRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.discovery.endpoints.isEmpty ? "Noch keine Blackmagic-Geräte gefunden." : "Geräte gefunden, aber keine Video-/Audiosender.")
                .font(.callout)
            Text("Suche per mDNS: \(model.discovery.browserState)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Gerät per Adresse hinzufügen …") { model.showAddNode = true }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

private struct DiscoveredRow: View {
    @Environment(AppModel.self) private var model
    let source: DiscoveredSource

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: source.video != nil ? "video" : "speaker.wave.2")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title)
                Text([source.deviceLabel, source.formatSummary, source.audio.isEmpty ? nil : "\(source.audio.count) Audio"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if source.videoFlow?.isInterlaced == true {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("Zeilensprungformat – wird nicht unterstützt. Am SDI-Quellgerät ein progressives Format einstellen.")
                    .accessibilityLabel("Format nicht unterstützt")
            }
        }
        .contextMenu {
            if source.audio.count > 1 || !otherAudio.isEmpty {
                Menu("Mit Audio von …") {
                    ForEach(source.audio + otherAudio, id: \.id) { a in
                        Button(a.label ?? a.id) {
                            Task { await model.playDiscovered(source, audioSenderID: a.id) }
                        }
                    }
                }
            }
            if !source.pairingCertain && source.video != nil && !source.audio.isEmpty {
                Text("Audio wurde über die Bezeichnung zugeordnet (vermutet).")
            }
        }
    }

    /// Audiosender anderer Gruppen (freie Zuordnung)
    private var otherAudio: [NMOSSender] {
        model.discovery.sources.filter { $0.id != source.id }.flatMap { $0.audio }
            .filter { a in !source.audio.contains(where: { $0.id == a.id }) }
    }
}

private struct SavedRow: View {
    let source: SavedSource

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch source.origin {
        case .nmos: return "network"
        case .manual: return "slider.horizontal.below.square.filled.and.square"
        case .sdp: return "doc.text"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let v = source.videoSDP, let m = SDPMedia.parse(v).media.first(where: { $0.kind == .video }) { parts.append(m.summary) }
        if let a = source.audioSDP, let m = SDPMedia.parse(a).media.first(where: { $0.kind == .audio }) { parts.append("\(m.channels) ch") }
        if source.origin == .nmos { parts.append("NMOS") }
        return parts.joined(separator: " · ")
    }
}

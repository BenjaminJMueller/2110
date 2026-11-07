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
                    Text("Im Netzwerk")
                    Spacer()
                    if model.discovery.isScanning { ProgressView().controlSize(.mini) }
                }
            }

            Section("Gespeichert") {
                if model.saved.isEmpty {
                    Label("SDP-Datei hierher ziehen", systemImage: "arrow.down.doc")
                        .foregroundStyle(.secondary)
                        .help("SDP-Dateien ins Fenster ziehen oder mit ＋ hinzufügen")
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

            Section("Ausprobieren") {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Testbild und Testton")
                        Text("Ohne Netzwerk")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "tv")
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
        let state = model.discovery.browserState
        let problem = state != "aktiv" && !state.hasPrefix("aus")
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if problem {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(tr(model.discovery.endpoints.isEmpty ? "Suche nach Geräten …" : "Geräte gefunden, aber keine Sender"))
                    .foregroundStyle(.secondary)
            }
            if problem || state.hasPrefix("aus") {
                Text(tr(state)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Per Adresse hinzufügen …") { model.showAddNode = true }
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(.vertical, 4)
    }
}

private struct DiscoveredRow: View {
    @Environment(AppModel.self) private var model
    let source: DiscoveredSource

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: source.video != nil ? "video.fill" : "waveform")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr(source.title))
                Text(tr([source.deviceLabel, source.formatSummary, source.audio.isEmpty ? nil : "\(source.audio.count) Audio"]
                        .compactMap { $0 }.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if source.videoFlow?.isInterlaced == true {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("Zeilensprungformat wird nicht unterstützt. Am SDI-Quellgerät ein progressives Format einstellen.")
                    .accessibilityLabel("Format nicht unterstützt")
            }
        }
        .contextMenu {
            if source.audio.count > 1 || !otherAudio.isEmpty {
                Menu("Mit Audio von …") {
                    ForEach(source.audio + otherAudio, id: \.id) { a in
                        Button(tr(a.label ?? a.id)) {
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
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr(source.name))
                Text(tr(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch source.origin {
        case .nmos: return "network"
        case .manual: return "slider.horizontal.3"
        case .sdp: return "doc.text.fill"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let v = source.videoSDP, let m = SDPMedia.parse(v).media.first(where: { $0.kind == .video }) { parts.append(m.summary) }
        if let a = source.audioSDP, let m = SDPMedia.parse(a).media.first(where: { $0.kind == .audio }) { parts.append("\(m.channels) Kanäle") }
        if source.origin == .nmos { parts.append("NMOS") }
        return parts.joined(separator: ", ")
    }
}

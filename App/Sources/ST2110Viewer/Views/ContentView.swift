import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            Group {
                switch model.mode {
                case .receive: SidebarView()
                case .send: SendSidebar()
                case .analyze: AnalysisSidebar()
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 400)
        } detail: {
            Group {
                switch model.mode {
                case .receive: PlayerView()
                case .send: SendView()
                case .analyze: AnalysisView()
                }
            }
            // Die Diagnose gehört zum Empfangen; beim Moduswechsel verschwindet sie ohne Animation
            .inspector(isPresented: Binding(get: { model.inspectorShown && model.mode == .receive },
                                            set: { model.inspectorShown = $0 })) {
                DiagnosticsView()
                    .inspectorColumnWidth(min: 320, ideal: 360, max: 560)
            }
        }
        .onChange(of: model.inspectorShown) { _, shown in if shown && model.mode == .receive { makeRoomForInspector() } }
        .onChange(of: model.mode) { _, mode in if mode == .receive && model.inspectorShown { makeRoomForInspector() } }
        .navigationTitle(tr(title))
        .navigationSubtitle(tr(subtitle))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Modus", selection: $model.mode) {
                    ForEach(AppMode.allCases) { m in Label(tr(m.rawValue), systemImage: m.icon).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .help("Empfangen (⌘1), Senden (⌘2), Analysieren (⌘3)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                SettingsLink {
                    Label("Erweitert", systemImage: "slider.horizontal.3")
                }
                .help("Erweiterte Einstellungen: Netzwerk, Synchronisation, NMOS, Adressbereiche (⌘,)")
                if model.mode == .receive {
                    ExternalOutputMenu()
                    Button {
                        model.inspectorShown.toggle()
                    } label: {
                        Label("Diagnose", systemImage: "gauge.with.dots.needle.50percent")
                    }
                    .help("Diagnose ein-/ausblenden (⌘I)")
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importFiles(urls)
            return true
        }
        .fileImporter(isPresented: $model.showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "sdp") ?? .plainText, .plainText, .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
        .sheet(item: $model.editor) { req in
            SourceEditorView(request: req)
        }
        .sheet(isPresented: $model.showOnboarding) {
            ExplainerView()
        }
        .sheet(isPresented: $model.showManualEntry) {
            ManualEntryView()
        }
        .sheet(isPresented: $model.showAddNode) {
            AddNodeView()
        }
        .alert("Hinweis", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) { model.alert = nil }
        } message: {
            Text(tr(model.alert ?? ""))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            model.isFullScreen = true
            columns = .detailOnly
            model.inspectorShown = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            model.isFullScreen = false
            columns = .all
        }
        .onChange(of: model.selection) { _, new in
            model.activate(new)
        }
        .onAppear { model.applyAppearance(); model.checkDevices() }
        .onChange(of: model.audioDevices.devices.map(\.uid)) { _, _ in model.checkDevices() }
        .onChange(of: model.interfaces.changeCounter) { _, _ in model.checkDevices() }
        .onChange(of: model.settings.audioDeviceUID) { _, _ in model.deviceNotice = nil; model.checkDevices() }
        .onChange(of: model.settings.interfaceName) { _, _ in model.deviceNotice = nil; model.checkDevices() }
        .buttonBorderShape(.capsule)
        .task {
            if let dir = SnapshotRunner.outputDir { await SnapshotRunner.run(model: model, dir: dir) }
        }
    }

    private var title: String {
        switch model.mode {
        case .receive: return model.player.current?.name ?? "2110 Viewer"
        case .send: return model.sender.isSending ? "Sendet: \(model.sender.sourceTitle)" : "Senden"
        case .analyze: return model.analysis.selected?.url.lastPathComponent ?? "Analyse"
        }
    }
}

/// Seitenleiste im Modus „Senden“: Ziele im Netz
struct SendSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Empfänger im Netz") {
                if model.discovery.destinations.isEmpty {
                    Label("Keine gefunden", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.discovery.destinations) { d in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tr(d.title))
                            Text(tr(d.deviceLabel)).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "rectangle.connected.to.line.below").foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Seitenleiste im Modus „Analysieren“: Mitschnitte mit ihren Strömen,
/// wie Ordner in Mail oder Dateien in Xcode.
struct AnalysisSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let a = model.analysis
        List(selection: Binding<String?>(get: { selectionTag }, set: { select($0) })) {
            Section("Mitschnitte") {
                if a.entries.isEmpty && !a.liveRunning {
                    Text("Noch keine").foregroundStyle(.secondary)
                }
                ForEach(a.entries) { e in
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(e.id) || a.selectedID == e.id },
                                                        set: { if $0 { expanded.insert(e.id) } else { expanded.remove(e.id) } })) {
                        if let r = e.report {
                            ForEach(r.orderedStreams, id: \.key) { st in
                                StreamRow(stream: st, missing: a.isLive(e) && a.liveMissing.contains(st.key))
                                    .tag("s|\(e.id.uuidString)|\(st.key)")
                            }
                            Label("PTP und IGMP", systemImage: "clock.arrow.2.circlepath")
                                .tag("s|\(e.id.uuidString)|\(AnalysisModel.network)")
                        }
                    } label: {
                        EntryRow(entry: e, live: a.isLive(e))
                            .tag("e|\(e.id.uuidString)")
                            .contextMenu {
                                if a.isLive(e) { Button("Live beenden") { a.stopLive() } }
                                Button("Entfernen") { if a.isLive(e) { a.stopLive() }; a.remove(e.id) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var selectionTag: String? {
        let a = model.analysis
        guard let id = a.selectedID else { return nil }
        guard let k = a.selectedStream else { return "e|\(id.uuidString)" }
        return "s|\(id.uuidString)|\(k)"
    }

    private func select(_ tag: String?) {
        guard let tag else { return }
        let parts = tag.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let id = UUID(uuidString: parts[1]) else { return }
        let a = model.analysis
        a.selectedID = id
        if parts.count == 3 {
            a.selectedStream = parts[2]
        } else {
            a.selectedStream = nil
        }
        expanded.insert(id)
    }
}

private struct EntryRow: View {
    let entry: AnalysisModel.Entry
    let live: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: live ? "dot.radiowaves.left.and.right" : "doc.text.magnifyingglass")
                .foregroundStyle(live ? Color.red : Color.accentColor)
                .symbolEffect(.pulse, options: .repeating, isActive: live)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr(live ? entry.url.lastPathComponent.replacingOccurrences(of: " (Live)", with: "") : entry.url.lastPathComponent))
                    .lineLimit(1)
                Text(tr(live ? "Live" : entry.report.map { "\($0.streams.count) Ströme, \(String(format: "%.1f", locale: .current, $0.capture.duration_s)) s" } ?? (entry.error ?? "")))
                    .font(.caption).foregroundStyle(live ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct StreamRow: View {
    let stream: AnalysisReport.Stream
    let missing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: stream.kind == "video" ? "film" : stream.kind == "audio" ? "waveform" : "text.alignleft")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr(stream.summary)).lineLimit(1)
                Text(tr(stream.destination)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Circle()
                .fill(missing ? Color.secondary.opacity(0.4) : stream.worstLevel >= 2 ? Color.red : stream.worstLevel == 1 ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
                .help(tr(missing ? "Im letzten Abschnitt nicht empfangen" : stream.worstLevel >= 2 ? "Fehler" : stream.worstLevel == 1 ? "Hinweise" : "In Ordnung"))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("\(stream.kindTitle), \(stream.summary), \(stream.destination)"))
    }
}

extension ContentView {
    /// Wie Xcode: Reicht die Fensterbreite für Seitenleiste, Bild und Diagnose
    /// nicht, wird das Fenster breiter. Nur wenn auch der Bildschirm zu schmal
    /// ist, weicht die Seitenleiste.
    func makeRoomForInspector() {
        guard !model.isFullScreen, let w = NSApp.keyWindow ?? NSApp.mainWindow, let screen = w.screen else { return }
        let needed: CGFloat = (columns == .detailOnly ? 0 : 260) + 600 + 380
        guard w.frame.width < needed else { return }
        let vis = screen.visibleFrame
        var f = w.frame
        f.size.width = min(needed, vis.width)
        if f.maxX > vis.maxX { f.origin.x = max(vis.minX, vis.maxX - f.width) }
        w.setFrame(f, display: true, animate: true)
        if f.width < needed { columns = .detailOnly }
    }

    /// Untertitel nur, wenn er etwas anderes sagt als der Titel.
    var subtitle: String {
        guard model.mode == .receive, model.player.isDemo else { return "" }
        let s = "Demo: Testbild und Testton"
        return title == s ? "" : s
    }
}


import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var sidebarAutoHidden = false

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
                case .receive:
                    PlayerView()
                        .inspector(isPresented: $model.inspectorShown) {
                            DiagnosticsView()
                                .inspectorColumnWidth(min: 320, ideal: 360, max: 560)
                        }
                case .send: SendView()
                case .analyze: AnalysisView()
                }
            }
        }
        .navigationTitle(tr(title))
        .navigationSubtitle(tr(subtitle))
        .onChange(of: model.inspectorShown) { _, shown in fitInspector(shown) }
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
                Button {
                    model.explainerPage = 1
                    model.showOnboarding = true
                } label: {
                    Label("So funktioniert ST 2110", systemImage: "questionmark.circle")
                }
                .help("Erklärung: Essenzen, Multicast, PTP, NMOS")
                SettingsLink {
                    Label("Erweitert", systemImage: "slider.horizontal.3")
                }
                .help("Erweiterte Einstellungen: Netzwerk, Synchronisation, NMOS, Adressbereiche (⌘,)")
                if model.mode == .receive {
                    ExternalOutputMenu()
                    Button {
                        model.inspectorShown.toggle()
                    } label: {
                        Label("Diagnose", systemImage: "sidebar.trailing")
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
        .onAppear { model.applyAppearance() }
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
            Section("Empfänger im Netz (NMOS)") {
                if model.discovery.destinations.isEmpty {
                    Text("Keine gefunden. Senden geht trotzdem: Der Strom ist per Multicast und als NMOS-Quelle verfügbar.")
                        .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.discovery.destinations) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr(d.title))
                        Text(tr(d.deviceLabel)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Hinweis") {
                Text("Blackmagic-Geräte wählen den 2110-Viewer-Strom im LCD-Menü unter „Outputs“ oder per NMOS-Controller. Mit „Verbinden“ stellt 2110 Viewer das Routing selbst per IS-05 her.")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.sidebar)
    }
}

/// Seitenleiste im Modus „Analysieren“: geöffnete Mitschnitte
struct AnalysisSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var a = model.analysis
        List(selection: $a.selectedID) {
            Section("Mitschnitte") {
                if a.entries.isEmpty {
                    Text("pcap- oder pcapng-Dateien hierher ziehen.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(a.entries) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr(e.url.lastPathComponent)).lineLimit(1)
                        Text(tr(e.report.map { "\($0.streams.count) Ströme, \(String(format: "%.1f", locale: .current, $0.capture.duration_s)) s" } ?? (e.error ?? "")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(e.id)
                    .contextMenu { Button("Entfernen") { a.remove(e.id) } }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

extension ContentView {
    /// Untertitel nur, wenn er etwas anderes sagt als der Titel.
    var subtitle: String {
        guard model.mode == .receive, model.player.isDemo else { return "" }
        let s = "Demo: Testbild und Testton"
        return title == s ? "" : s
    }

    /// Ist das Fenster für Seitenleiste, Bild und Diagnose zu schmal, weicht die
    /// Seitenleiste, solange die Diagnose offen ist (statt den Inhalt abzuschneiden).
    func fitInspector(_ shown: Bool) {
        let width = NSApp.keyWindow?.frame.width ?? NSApp.windows.first?.frame.width ?? 0
        if shown, columns != .detailOnly, width > 0, width < 1500 {
            withAnimation { columns = .detailOnly }
            sidebarAutoHidden = true
        } else if !shown, sidebarAutoHidden {
            withAnimation { columns = .all }
            sidebarAutoHidden = false
        }
    }
}

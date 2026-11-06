import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 420)
        } detail: {
            PlayerView()
                .inspector(isPresented: $model.inspectorShown) {
                    DiagnosticsView()
                        .inspectorColumnWidth(min: 320, ideal: 400, max: 560)
                }
        }
        .navigationTitle(model.player.current?.name ?? "ST 2110 Monitor")
        .navigationSubtitle(model.player.isDemo ? "DEMO – Testbild und Testton" : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SettingsLink {
                    Label("Erweitert", systemImage: "slider.horizontal.3")
                }
                .help("Erweiterte Einstellungen: Netzwerk, Synchronisation, NMOS, Adressbereiche (⌘,)")
                Button {
                    model.inspectorShown.toggle()
                } label: {
                    Label("Diagnose", systemImage: "waveform.path.ecg.rectangle")
                }
                .help("Diagnose ein-/ausblenden (⌘I)")
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
            OnboardingView()
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
            Text(model.alert ?? "")
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
    }
}

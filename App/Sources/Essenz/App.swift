import AppKit
import ST2110Core
import SwiftUI

/// Einstieg: „--selftest“ prüft ohne Oberfläche die eingebettete
/// Medienkomponente (für Abnahme und CI), sonst startet die App.
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            GStreamerEnvironment.setUp()
            if let e = GStreamerEnvironment.initError {
                print("FEHLER \(e)")
                exit(1)
            }
            var out = [CChar](repeating: 0, count: 16384)
            let fails = st_selftest(5, GStreamerEnvironment.bundled ? 1 : 0, &out, out.count)
            print(String(cString: out), terminator: "")
            print("Bundle: \(GStreamerEnvironment.bundled ? "eingebettetes GStreamer" : "Entwicklungsumgebung")")
            exit(fails == 0 ? 0 : 1)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-screenshots"), i + 1 < CommandLine.arguments.count {
            SnapshotRunner.outputDir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        EssenzApp.main()
    }
}

struct EssenzApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Essenz", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1400, height: 860)
        .commands { AppCommands(model: model) }

        Settings {
            AdvancedSettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neue Quelle …") { model.newSource() }
                .keyboardShortcut("n")
            Button("SDP-Datei öffnen …") { model.showImporter = true }
                .keyboardShortcut("o")
            Button("SDP aus Zwischenablage einfügen") { model.pasteSDP() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("Manuelle Eingabe (Experte) …") { model.showManualEntry = true }
            Button("NMOS-Gerät per Adresse hinzufügen …") { model.showAddNode = true }
        }
        CommandGroup(after: .sidebar) {
            Button("Empfangen") { model.mode = .receive }.keyboardShortcut("1", modifiers: [.command])
            Button("Senden") { model.mode = .send }.keyboardShortcut("2", modifiers: [.command])
            Button("Analysieren") { model.mode = .analyze }.keyboardShortcut("3", modifiers: [.command])
            Divider()
        }
        CommandMenu("Wiedergabe") {
            Button(model.player.isActive ? "Stopp" : "Start") { model.togglePlay() }
                .keyboardShortcut(.return, modifiers: [.command])
            Button("Demo: Testbild und Testton") {
                if model.selection == .demo { model.activate(.demo) } else { model.selection = .demo }
            }
            Divider()
            Button(model.settings.muted ? "Ton einschalten" : "Stummschalten") {
                model.settings.muted.toggle()
                model.player.setMute(model.settings.muted)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Lauter") {
                model.settings.volume = min(1.5, model.settings.volume + 0.1)
                model.player.setVolume(model.settings.volume)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            Button("Leiser") {
                model.settings.volume = max(0, model.settings.volume - 0.1)
                model.player.setVolume(model.settings.volume)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            Button("Nächstes Kanalpaar") { model.player.nextPair(1) }
                .keyboardShortcut("]", modifiers: [.command])
            Button("Vorheriges Kanalpaar") { model.player.nextPair(-1) }
                .keyboardShortcut("[", modifiers: [.command])
            Divider()
            Button(model.inspectorShown ? "Diagnose ausblenden" : "Diagnose einblenden") { model.inspectorShown.toggle() }
                .keyboardShortcut("i", modifiers: [.command])
            Button("Vollbild") { NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [.command, .control])
        }
        CommandGroup(replacing: .help) {
            Button("So funktioniert ST 2110") { model.explainerPage = 0; model.showOnboarding = true }
            Button("Erste Schritte und Berechtigungen") { model.explainerPage = ExplainerView.pageCount - 1; model.showOnboarding = true }
        }
    }
}

import AppKit
import MetalKit
import Observation
import SwiftUI

/// Bildausgabe auf einem zweiten Bildschirm (Monitor, Beamer, Kontrollmonitor):
/// randloses Fenster über die ganze Fläche des gewählten Bildschirms, nur das
/// Videobild, ohne Bedienelemente. Die Bedienung bleibt im Hauptfenster.
/// Zeichnet mit einem eigenen Renderer aus derselben Bildquelle wie die Vorschau.
@MainActor
@Observable
final class ExternalOutput {
    struct Display: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
        let size: CGSize
        let isMain: Bool
        var title: String { "\(name) (\(Int(size.width))×\(Int(size.height)))" }
    }

    private(set) var displays: [Display] = []
    private(set) var activeDisplay: CGDirectDisplayID?
    private(set) var message: String?
    var isActive: Bool { activeDisplay != nil }
    var activeName: String? { displays.first { $0.id == activeDisplay }?.name }
    func dismissMessage() { message = nil }
    var windowNumber: Int? { window?.windowNumber }

    /// Nur für den CI-Durchlauf: Varianten, um die schwarze Ausgabe einzugrenzen.
    func debugSetLevelNormal() { window?.level = .normal; window?.orderFrontRegardless() }
    func debugShowRed() {
        guard let w = window else { return }
        let v = NSView(frame: w.contentView?.bounds ?? .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.red.cgColor
        v.autoresizingMask = [.width, .height]
        w.contentView?.addSubview(v)
    }
    var debugSummary: String {
        guard let window, let renderer else { return "keine Ausgabe" }
        let v = window.contentView
        return "Fenster \(Int(window.frame.width))×\(Int(window.frame.height)) sichtbar \(window.isVisible) Ebene \(window.level.rawValue), Ansicht \(Int(v?.frame.width ?? 0))×\(Int(v?.frame.height ?? 0)) Layer \(v?.layer.map { String(describing: type(of: $0)) } ?? "–"), " + renderer.debugSummary
    }

    private var window: NSWindow?
    private var renderer: VideoRenderer?
    private var observer: NSObjectProtocol?
    private let sink: VideoFrameSink
    private static let lastKey = "externalOutputDisplayName"

    init(sink: VideoFrameSink) {
        self.sink = sink
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// Bildschirme außer dem, auf dem das Hauptfenster liegt, stehen vorne.
    var externalDisplays: [Display] { displays.filter { !$0.isMain } }

    func refresh() {
        let mainScreen = NSApp?.mainWindow?.screen ?? NSScreen.main
        displays = NSScreen.screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Display(id: CGDirectDisplayID(n.uint32Value), name: s.localizedName, size: s.frame.size, isMain: s == mainScreen)
        }
    }

    /// Schaltet die Ausgabe ein bzw. auf einen anderen Bildschirm um.
    func show(on id: CGDirectDisplayID) {
        refresh()
        guard let screen = Self.screen(for: id) else {
            message = "Dieser Bildschirm ist nicht mehr angeschlossen."
            return
        }
        message = nil
        let w = window ?? makeWindow()
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        activeDisplay = id
        UserDefaults.standard.set(screen.localizedName, forKey: Self.lastKey)
        if displays.first(where: { $0.id == id })?.isMain == true {
            message = "Die Ausgabe liegt auf dem Bildschirm des Hauptfensters. Esc oder ⌘⇧B beendet sie."
        }
    }

    /// Ein- und ausschalten; ohne Wahl wird der zuletzt benutzte bzw. der erste
    /// externe Bildschirm genommen.
    func toggle() {
        if isActive { hide(); return }
        refresh()
        let last = UserDefaults.standard.string(forKey: Self.lastKey)
        let pick = externalDisplays.first { $0.name == last } ?? externalDisplays.first
        if let pick { show(on: pick.id) } else {
            message = "Kein zweiter Bildschirm angeschlossen. Monitor oder Beamer anschließen; in den Systemeinstellungen › Displays „Erweitern“ statt „Spiegeln“ wählen."
        }
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        renderer = nil
        activeDisplay = nil
    }

    private func screensChanged() {
        refresh()
        if let id = activeDisplay {
            if let screen = Self.screen(for: id) {
                window?.setFrame(screen.frame, display: true)
            } else {
                hide()
                message = "Der Ausgabebildschirm wurde getrennt. Die Ausgabe ist aus."
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let r = VideoRenderer(sink: sink)
        let w = OutputWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.onEscape = { [weak self] in self?.hide() }
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        // über der Menüleiste des Ausgabebildschirms, auf allen Spaces
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.title = "2110 Viewer – Ausgabe"
        // Gleicher Aufbau wie das Bild im Hauptfenster (SwiftUI um eine MTKView);
        // eine nackte MTKView als contentView blieb auf manchen Macs schwarz.
        let host = NSHostingView(rootView: OutputContent(renderer: r))
        host.setAccessibilityLabel("Videoausgabe auf zweitem Bildschirm")
        w.contentView = host
        renderer = r
        window = w
        return w
    }

    private static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }
}

/// Randloses Fenster, das Tastatureingaben annimmt (Esc beendet die Ausgabe).
private final class OutputWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// Inhalt der Ausgabe: nur das Bild auf Schwarz, Mauszeiger ausgeblendet.
private struct OutputContent: View {
    let renderer: VideoRenderer

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(renderer: renderer)
        }
        .ignoresSafeArea()
        .onContinuousHover { _ in NSCursor.setHiddenUntilMouseMoves(true) }
    }
}

/// Menü für Symbolleiste und Wiedergabe-Steuerung.
struct ExternalOutputMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let out = model.output
        Menu {
            if out.displays.isEmpty { Text("Keine Bildschirme gefunden") }
            Section("Ausgabe auf Bildschirm") {
                ForEach(out.displays) { d in
                    Toggle(isOn: Binding(get: { out.activeDisplay == d.id },
                                         set: { $0 ? model.showOutput(on: d.id) : out.hide() })) {
                        Text(tr(d.isMain ? d.title + " (Hauptfenster)" : d.title))
                    }
                }
            }
            if out.isActive {
                Divider()
                Button("Ausgabe beenden") { out.hide() }
            }
        } label: {
            Label("Zweiter Bildschirm", systemImage: out.isActive ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
        }
        .help("Bild randlos auf einem zweiten Bildschirm oder Beamer ausgeben (⌘⇧B)")
        .onAppear { out.refresh() }
    }
}

import AppKit
import ST2110Core
import ST2110Kit
import SwiftUI

/// Bildschirmfoto- und Funktionsdurchlauf (`2110 Viewer --render-screenshots DIR`):
/// spielt die wichtigsten Abläufe durch, speichert Fenster als PNG und
/// schreibt einen Bericht. Läuft im macOS-CI; dient der Usability-Prüfung und
/// der Webseite.
@MainActor
enum SnapshotRunner {
    static var outputDir: URL?
    private static var report = ""

    static func run(model: AppModel, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log("2110 Viewer \(model.appVersion), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        await wait(2)
        if let w = mainWindow { w.setContentSize(NSSize(width: 1440, height: 900)); w.center() }

        for (ap, name) in [(1, "hell"), (2, "dunkel")] {
            model.settings.appearance = ap
            for p in 0..<ExplainerView.pageCount {
                model.explainerPage = p
                model.showOnboarding = true
                await wait(1.2)
                shotSheet("erklaerung-\(p + 1)-\(name)")
            }
            model.showOnboarding = false
            await wait(0.6)
        }
        model.settings.onboardingDone = true

        // Empfang: Demo
        for (ap, name) in [(2, "dunkel"), (1, "hell")] {
            model.settings.appearance = ap
            model.mode = .receive
            if model.selection != .demo { model.selection = .demo } else if !model.player.isActive { model.activate(.demo) }
            await wait(3)
            shot("empfangen-demo-\(name)")
        }
        model.inspectorShown = true
        await wait(1)
        shot("empfangen-demo-diagnose-hell")
        model.inspectorShown = false
        model.player.stop()

        // Senden (Unicast über Loopback, damit kein Netz nötig ist)
        let s = model.sender
        s.source = .syncTest
        s.format = .p1080_25
        s.audioChannels = 2
        s.videoAddress = "127.0.0.1"
        s.audioAddress = "127.0.0.1"
        s.port = 47100
        s.audioPort = 47102
        s.usePTP = false
        s.announceNMOS = true
        model.mode = .send
        await s.start()
        await wait(3)
        model.settings.appearance = 1
        await wait(0.5)
        shot("senden-hell")
        model.settings.appearance = 2
        await wait(0.5)
        shot("senden-dunkel")
        if let st = s.stats { log(String(format: "Sender: %llu Bilder, %.0f Mbit/s, verspätet %llu, Fehler %llu %@", st.frames_sent, st.video_mbps, st.late_packets, st.send_errors, cString(st.last_error))) }
        if let m = s.message { log("Sender-Meldung: \(m)") }

        // Eigenen Strom empfangen
        var src = SavedSource(name: "Eigener 2110-Viewer-Strom (Loopback)", origin: .sdp, videoSDP: s.videoSDP, audioSDP: s.audioSDP)
        src.id = UUID()
        model.upsert(src)
        model.mode = .receive
        model.selection = .saved(src.id)
        await wait(6)
        shot("empfangen-eigener-strom-dunkel")
        if let st = model.player.stats {
            log(String(format: "Empfang: Zustand %@, %.3f B/s, %d×%d, Pakete %llu, verloren %llu, gezeigt %llu, Audio %llu, Sync n=%llu Ø %+.2f ms",
                       String(cString: st_state_name(st.state)), st.v_fps_measured, st.v_width_seen, st.v_height_seen,
                       st.v_packets, st.v_lost, st.v_frames_rendered, st.a_packets, st.sync_measurements, st.sync_offset_avg_ms))
        } else {
            log("Empfang: keine Statistik")
        }

        // Aufzeichnen und analysieren
        model.recordAndAnalyze(seconds: 4)
        for _ in 0..<60 where model.analysis.entries.isEmpty || model.analysis.busyFile != nil { await wait(1) }
        s.stop()
        model.player.stop()
        model.mode = .analyze
        await wait(1.5)
        shot("analysieren-dunkel")
        model.settings.appearance = 1
        await wait(0.8)
        shot("analysieren-hell")
        if let r = model.analysis.selected?.report {
            for st in r.streams {
                log("Analyse: \(st.kindTitle) \(st.summary) \(st.destination), Pakete \(st.packets), verloren \(st.lost), Befunde: \(st.findings.map(\.text).joined(separator: " | "))")
            }
        } else {
            log("Analyse: \(model.analysis.selected?.error ?? "kein Ergebnis")")
        }
        model.analysis.selectedStream = AnalysisModel.network
        await wait(0.8)
        shot("analysieren-netz-hell")

        model.mode = .receive
        model.settings.appearance = 0
        try? report.write(to: dir.appendingPathComponent("bericht.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private static var mainWindow: NSWindow? { NSApp.windows.first { $0.isVisible && $0.sheetParent == nil && $0.className.contains("AppKitWindow") } ?? NSApp.windows.first { $0.isVisible && $0.sheetParent == nil } }

    private static func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private static func log(_ s: String) {
        report += s + "\n"
        print(s)
    }

    private static func shot(_ name: String) {
        guard let w = mainWindow else { log("Kein Fenster für \(name)"); return }
        save(w, name)
    }

    private static func shotSheet(_ name: String) {
        guard let w = mainWindow?.attachedSheet ?? NSApp.windows.first(where: { $0.sheetParent != nil }) else { log("Kein Blatt für \(name)"); return }
        save(w, name)
    }

    private static func save(_ w: NSWindow, _ name: String) {
        guard let view = w.contentView?.superview ?? w.contentView, let dir = outputDir else { return }
        view.layoutSubtreeIfNeeded()
        // Bevorzugt das Systemwerkzeug: nimmt das Fenster so auf, wie der Window Server
        // es zeigt (Liquid Glass, Metal, Schatten). cacheDisplay ist nur der Rückfall.
        let url = dir.appendingPathComponent("\(name).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(w.windowNumber), url.path]
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0, let img = NSImage(contentsOf: url), img.size.width > 0 {
                log("Bild: \(name).png (\(Int(img.size.width))×\(Int(img.size.height)), screencapture)")
                return
            }
        }
        let rect = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            log("Bild: \(name).png (\(Int(rect.width))×\(Int(rect.height)))")
        }
    }
}

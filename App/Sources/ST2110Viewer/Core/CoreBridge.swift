import Foundation
import ST2110Core

// MARK: - C-Zeichenketten in festen Feldern

func cString<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        let n = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<n], as: UTF8.self)
    }
}

func setCString<T>(_ field: inout T, _ s: String) {
    withUnsafeMutableBytes(of: &field) { raw in
        let bytes = Array(s.utf8.prefix(raw.count - 1))
        for i in 0..<raw.count { raw[i] = 0 }
        for (i, b) in bytes.enumerated() { raw[i] = b }
    }
}

// MARK: - SDP

enum Support: Int, Comparable {
    case ok = 0, warning = 1, unsupported = 2
    static func < (a: Support, b: Support) -> Bool { a.rawValue < b.rawValue }
}

/// Eine Medienbeschreibung aus einer SDP (Swift-Hülle um st_sdp_media).
struct SDPMedia {
    var raw: st_sdp_media

    enum Kind { case video, audio, data, unknown }

    var kind: Kind {
        switch raw.kind {
        case ST_MEDIA_VIDEO: return .video
        case ST_MEDIA_AUDIO: return .audio
        case ST_MEDIA_DATA: return .data
        default: return .unknown
        }
    }
    var encoding: String { cString(raw.encoding) }
    var destination: String { cString(raw.dest_addr) }
    var port: Int { Int(raw.port) }
    var sourceAddress: String { cString(raw.source_addr) }
    var originAddress: String { cString(raw.origin_addr) }
    var senderAddress: String? {
        let s = sourceAddress
        if !s.isEmpty { return s }
        let o = originAddress
        return (o.isEmpty || o == "0.0.0.0" || o == "127.0.0.1") ? nil : o
    }
    var sessionName: String { cString(raw.session_name) }
    var title: String { cString(raw.media_title) }
    var width: Int { Int(raw.width) }
    var height: Int { Int(raw.height) }
    var depth: Int { Int(raw.depth) }
    var sampling: String { cString(raw.sampling) }
    var colorimetry: String { cString(raw.colorimetry) }
    var tcs: String { cString(raw.tcs) }
    var range: String { cString(raw.range) }
    var fps: Double { raw.fps_den > 0 ? Double(raw.fps_num) / Double(raw.fps_den) : 0 }
    var interlaced: Bool { raw.interlaced != 0 }
    var channels: Int { max(Int(raw.channels), kind == .audio ? 1 : 0) }
    var clockRate: Int { Int(raw.clock_rate) }
    var ptimeMs: Double { raw.ptime_ms }
    var payloadType: Int { Int(raw.payload_type) }
    var hasPTP: Bool { raw.has_ptp_refclk != 0 }
    var ptpGrandmaster: String { cString(raw.ptp_gmid) }
    var ptpDomain: Int { Int(raw.ptp_domain) }
    var refclk: String { cString(raw.refclk_raw) }
    var dup: Bool { raw.dup_group != 0 }

    var summary: String {
        switch kind {
        case .video:
            let f = fps == fps.rounded() ? String(Int(fps)) : String(format: "%.2f", fps)
            return "\(width)×\(height)\(interlaced ? "i" : "p")\(f), \(sampling), \(depth) Bit"
        case .audio:
            let pt = ptimeMs > 0 ? String(format: ", %@ ms", ptimeMs < 1 ? "0,125" : String(format: "%.0f", ptimeMs)) : ""
            return "\(channels) Kanäle, \(encoding), \(clockRate / 1000) kHz\(pt)"
        default:
            return encoding
        }
    }

    var check: (Support, String) {
        var r = raw
        var msg = [CChar](repeating: 0, count: 1024)
        let s = st_check_media(&r, &msg, msg.count)
        let text = String(cString: msg)
        switch s {
        case ST_SUPPORT_OK: return (.ok, text)
        case ST_SUPPORT_WARNING: return (.warning, text)
        default: return (.unsupported, text)
        }
    }

    static func parse(_ text: String) -> (media: [SDPMedia], error: String?) {
        var arr = [st_sdp_media](repeating: st_sdp_media(), count: 16)
        var err = [CChar](repeating: 0, count: 512)
        let n = text.withCString { st_sdp_parse($0, &arr, 16, &err, err.count) }
        if n < 0 { return ([], String(cString: err)) }
        return (arr.prefix(Int(n)).map { SDPMedia(raw: $0) }, nil)
    }

    static func write(_ m: st_sdp_media) -> String? {
        var mm = m
        var out = [CChar](repeating: 0, count: 4096)
        let n = st_sdp_write(&mm, &out, out.count)
        return n > 0 ? String(cString: out) : nil
    }
}

// MARK: - GStreamer-Umgebung

enum GStreamerEnvironment {
    private(set) static var initError: String?
    private(set) static var missingPlugins: String = ""
    private(set) static var bundled = false
    private static var done = false

    /// Muss vor dem ersten GStreamer-Aufruf laufen. Richtet die im App-Bundle
    /// mitgelieferten Plugins und Hilfsprogramme ein (keine Systeminstallation nötig).
    static func setUp() {
        guard !done else { return }
        done = true
        let fm = FileManager.default
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let bundledPlugins = contents.appendingPathComponent("PlugIns")
        let dev = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GSTREAMER_PREFIX"] ?? "/nonexistent")
        var plugins: URL?
        var helpers: URL?
        if fm.fileExists(atPath: bundledPlugins.appendingPathComponent("libgstcoreelements.dylib").path) {
            // Ausgeliefertes App-Bundle (flaches Apple-Layout)
            bundled = true
            plugins = bundledPlugins
            helpers = contents.appendingPathComponent("Helpers")
        } else if fm.fileExists(atPath: dev.appendingPathComponent("lib/gstreamer-1.0").path) {
            // Entwicklung mit vendor/gstreamer
            plugins = dev.appendingPathComponent("lib/gstreamer-1.0")
            helpers = dev.appendingPathComponent("libexec/gstreamer-1.0")
        }
        if let plugins, let helpers {
            setenv("GST_PLUGIN_SYSTEM_PATH_1_0", plugins.path, 1)
            setenv("GST_PLUGIN_SYSTEM_PATH", plugins.path, 1)
            setenv("GST_PLUGIN_PATH_1_0", "", 1)
            setenv("GST_PLUGIN_SCANNER_1_0", helpers.appendingPathComponent("gst-plugin-scanner").path, 1)
            setenv("GST_PLUGIN_SCANNER", helpers.appendingPathComponent("gst-plugin-scanner").path, 1)
            setenv("GST_PTP_HELPER_1_0", helpers.appendingPathComponent("gst-ptp-helper").path, 1)
            setenv("GST_PTP_HELPER", helpers.appendingPathComponent("gst-ptp-helper").path, 1)
        }
        // ORC (Laufzeit-Codeerzeugung) abschalten: C-Ersatzfunktionen genügen und
        // vertragen sich mit der „Hardened Runtime“ notarisierter Apps.
        setenv("ORC_CODE", "backup", 0)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("2110 Viewer", isDirectory: true)
        try? fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
        setenv("GST_REGISTRY_1_0", caches.appendingPathComponent("gst-registry-\(version).bin").path, 1)
        setenv("GST_REGISTRY", caches.appendingPathComponent("gst-registry-\(version).bin").path, 1)

        var err = [CChar](repeating: 0, count: 512)
        if st_init(&err, err.count) != 0 {
            initError = String(cString: err)
            return
        }
        var missing = [CChar](repeating: 0, count: 512)
        if st_check_plugins(&missing, missing.count) > 0 {
            missingPlugins = String(cString: missing)
        }
    }

    static var version: String { String(cString: st_gstreamer_version()) }
}

// MARK: - Empfänger

/// Dünne, thread-sichere Hülle um st_receiver. Alle Aufrufe außer den
/// Callbacks erfolgen über die serielle Warteschlange des PlayerController.
final class CoreReceiver: @unchecked Sendable {
    private var handle: OpaquePointer?
    let frameSink: VideoFrameSink
    let onEvent: (st_event, Int32, String) -> Void

    init(frameSink: VideoFrameSink, onEvent: @escaping (st_event, Int32, String) -> Void) {
        self.frameSink = frameSink
        self.onEvent = onEvent
    }

    deinit {
        if let h = handle { st_receiver_free(h) }
    }

    func start(config: st_receiver_config) -> String? {
        var cfg = config
        var cb = st_callbacks()
        cb.user = Unmanaged.passUnretained(self).toOpaque()
        cb.video_frame = { user, frame in
            guard let user, let frame else { return }
            let me = Unmanaged<CoreReceiver>.fromOpaque(user).takeUnretainedValue()
            me.frameSink.push(frame.pointee)
        }
        cb.event = { user, ev, code, msg in
            guard let user else { return }
            let me = Unmanaged<CoreReceiver>.fromOpaque(user).takeUnretainedValue()
            me.onEvent(ev, code, msg.map { String(cString: $0) } ?? "")
        }
        var err = [CChar](repeating: 0, count: 1024)
        guard let h = st_receiver_new(&cfg, &cb, &err, err.count) else {
            return String(cString: err)
        }
        handle = h
        if st_receiver_start(h, &err, err.count) != 0 {
            return String(cString: err)
        }
        return nil
    }

    func stop() {
        if let h = handle {
            st_receiver_free(h)
            handle = nil
        }
    }

    func stats() -> st_stats? {
        guard let h = handle else { return nil }
        var s = st_stats()
        st_receiver_get_stats(h, &s)
        return s
    }

    func levels() -> [Float] {
        guard let h = handle else { return [] }
        var buf = [Float](repeating: -120, count: Int(ST_MAX_AUDIO_CHANNELS))
        let n = st_receiver_get_levels(h, &buf, Int32(buf.count))
        return Array(buf.prefix(Int(max(0, n))))
    }

    func startRecording(path: String, seconds: Int) -> String? {
        guard let h = handle else { return "Kein Empfang aktiv." }
        var err = [CChar](repeating: 0, count: 512)
        return st_receiver_start_recording(h, path, Int32(seconds), 4_000_000_000, &err, err.count) == 0 ? nil : String(cString: err)
    }

    func stopRecording() { if let h = handle { st_receiver_stop_recording(h) } }

    func setVolume(_ v: Double) { if let h = handle { st_receiver_set_volume(h, v) } }
    func setMute(_ m: Bool) { if let h = handle { st_receiver_set_mute(h, m ? 1 : 0) } }
    func setMonitor(left: Int, right: Int) { if let h = handle { st_receiver_set_monitor_channels(h, Int32(left), Int32(right)) } }
    func setAudioDelay(ms: Int) { if let h = handle { st_receiver_set_audio_delay_ms(h, Int32(ms)) } }
}

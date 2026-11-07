import AppKit
import Foundation
import ST2110Core

/// Bericht des Analysators (JSON aus st_analysis_json).
struct AnalysisReport: Decodable {
    struct Finding: Decodable, Hashable { let level: Int; let text: String }
    struct Stat: Decodable, Hashable { let min: Double; let avg: Double; let max: Double; let n: Int }
    struct Series: Decodable { let t: [Double]; let v: [Double?] }
    struct Capture: Decodable {
        let format: String
        let linktype: Int
        let packets: Int
        let udp_packets: Int
        let fragments: Int
        let truncated: Int
        let duration_s: Double
        let timestamp_resolution_ns: Int
        let software_capture: Bool
        let comment: String
        let findings: [Finding]?
    }
    struct Video: Decodable {
        let width: Int, height: Int, interlaced: Bool, pgroup_bytes: Int
        let fps: Double?
        let frames: Int, frames_without_marker: Int
        let packets_per_frame: Stat, frame_duration_ms: Stat, frame_interval_ms: Stat, rtp_latency_ms: Stat, cinst: Stat, vrx: Stat
        let limits: [String: Double?]
        let st2110_21_class: String
        let vrx_underflow_frames: Int
        let thumbnail: Bool
        let series: [String: Series]
    }
    struct Audio: Decodable {
        let samples_per_packet: Int, channels: Int, channels_from_sdp: Bool, bytes_per_sample: Int, payload_bytes: Int
        let ptime_ms: Double?
        let tsdf_us: Stat, rtp_latency_ms: Stat
        let series: [String: Series]
    }
    struct Anc: Decodable {
        struct D: Decodable, Hashable { let did: Int; let sdid: Int; let count: Int }
        let did_sdid: [D]
    }
    struct Stream: Decodable, Identifiable {
        let index: Int
        let kind: String
        let source: String
        let destination: String
        let ssrc: UInt32
        let payload_type: Int
        let packets: Int
        let bytes: Int
        let duration_s: Double?
        let rate_mbps: Double?
        let lost: Int, duplicates: Int, reordered: Int, ssrc_changes: Int
        let sdp_matched: Bool
        let iat_us: Stat
        let iat_histogram: [Int]
        let video: Video?
        let audio: Audio?
        let anc: Anc?
        let findings: [Finding]
        var id: Int { index }

        var kindTitle: String {
            switch kind {
            case "video": return "Video (ST 2110-20)"
            case "audio": return "Audio (ST 2110-30)"
            case "anc": return "Zusatzdaten (ST 2110-40)"
            default: return "Unbekannter RTP-Strom"
            }
        }
        var summary: String {
            if let v = video, v.width > 0 {
                let f = (v.fps ?? 0).rounded() == (v.fps ?? 0) ? String(Int(v.fps ?? 0)) : String(format: "%.2f", v.fps ?? 0)
                return "\(v.width)×\(v.height)\(v.interlaced ? "i" : "p")\(f)"
            }
            if let a = audio { return "\(a.channels) Kanäle · \(String(format: "%g", a.ptime_ms ?? 0)) ms" }
            return kindTitle
        }
        var worstLevel: Int { findings.map(\.level).max() ?? 0 }
    }
    struct PTP: Decodable, Identifiable {
        let domain: Int, grandmaster: String, masters: Int
        let announce: Int, sync: Int, follow_up: Int, delay_req: Int, delay_resp: Int
        let two_step: Bool
        let priority1: Int, priority2: Int, clock_class: Int, clock_accuracy: Int, time_source: Int, utc_offset: Int, steps_removed: Int
        let sync_rate: Double?, announce_rate: Double?
        var id: Int { domain }
    }
    struct IGMP: Decodable {
        struct Group: Decodable, Hashable { let group: String; let joins: Int; let leaves: Int }
        let queries: Int, v3_queries: Int, querier: String, groups: [Group]
    }
    let capture: Capture
    let streams: [Stream]
    let ptp: [PTP]
    let igmp: IGMP
}

struct AnalysisError: LocalizedError { let errorDescription: String? }

private final class ProgressBox: @unchecked Sendable {
    let fn: (Double) -> Void
    var last = -1.0
    init(_ f: @escaping (Double) -> Void) { fn = f }
}

@MainActor
@Observable
final class AnalysisModel {
    struct Entry: Identifiable {
        let id = UUID()
        let url: URL
        let date: Date
        var report: AnalysisReport?
        var thumbnails: [Int: NSImage] = [:]
        var error: String?
    }

    private(set) var entries: [Entry] = []
    var selectedID: UUID?
    var selectedStream: Int?
    private(set) var progress: Double?
    private(set) var busyFile: String?
    var sdpTexts: [String] = []

    var selected: Entry? { entries.first { $0.id == selectedID } }

    func open(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        busyFile = url.lastPathComponent
        progress = 0
        let sdps = sdpTexts
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { [weak self] in
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return AnalysisModel.analyze(url: url, sdps: sdps) { p in
                    Task { @MainActor in self?.progress = p }
                }
            }.value
            do {
                guard let self else { return }
                var e = Entry(url: url, date: Date())
                switch result {
                case .success(let (r, thumbs)):
                    e.report = r
                    e.thumbnails = thumbs
                case .failure(let err):
                    e.error = err.localizedDescription
                }
                self.entries.insert(e, at: 0)
                self.selectedID = e.id
                self.selectedStream = e.report?.streams.first(where: { $0.kind == "video" })?.index ?? e.report?.streams.first?.index
                self.progress = nil
                self.busyFile = nil
            }
        }
    }

    nonisolated static func analyze(url: URL, sdps: [String], progress: @escaping (Double) -> Void) -> Result<(AnalysisReport, [Int: NSImage]), Error> {
        var cStrings = sdps.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.forEach { free($0) } }
        let box = ProgressBox(progress)
        let user = Unmanaged.passUnretained(box).toOpaque()
        var err = [CChar](repeating: 0, count: 512)
        let a: OpaquePointer? = cStrings.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                st_analyze_file(url.path, p, { u, f in
                    let b = Unmanaged<ProgressBox>.fromOpaque(u!).takeUnretainedValue()
                    if f - b.last >= 0.01 || f >= 1 { b.last = f; b.fn(f) }
                    return 0
                }, user, &err, err.count)
            }
        }
        guard let a else { return .failure(AnalysisError(errorDescription: String(cString: err))) }
        defer { st_analysis_free(a) }
        guard let js = st_analysis_json(a) else { return .failure(AnalysisError(errorDescription: "Kein Bericht.")) }
        let data = Data(String(cString: js).utf8)
        do {
            let r = try JSONDecoder().decode(AnalysisReport.self, from: data)
            var thumbs: [Int: NSImage] = [:]
            for s in r.streams where s.video?.thumbnail == true {
                let w = 640, h = s.video!.height > 0 ? 640 * s.video!.height / max(1, s.video!.width) : 360
                var px = [UInt8](repeating: 0, count: w * h * 4)
                if st_analysis_thumbnail(a, Int32(s.index), &px, Int32(w), Int32(h)) == 0,
                   let provider = CGDataProvider(data: Data(px) as CFData),
                   let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                    thumbs[s.index] = NSImage(cgImage: cg, size: NSSize(width: w, height: h))
                }
            }
            return .success((r, thumbs))
        } catch {
            return .failure(AnalysisError(errorDescription: "Bericht nicht lesbar: \(error.localizedDescription)"))
        }
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if selectedID == id { selectedID = entries.first?.id }
    }

    func exportJSON(_ e: Entry) {
        guard e.report != nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = e.url.deletingPathExtension().lastPathComponent + "-analyse.json"
        guard panel.runModal() == .OK, let out = panel.url else { return }
        let sdps = sdpTexts
        Task.detached {
            var cs = sdps.map { strdup($0) }
            cs.append(nil)
            defer { cs.forEach { free($0) } }
            var err = [CChar](repeating: 0, count: 256)
            let a: OpaquePointer? = cs.withUnsafeBufferPointer { b in
                b.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: b.count) { st_analyze_file(e.url.path, $0, nil, nil, &err, err.count) }
            }
            if let a, let js = st_analysis_json(a) {
                try? String(cString: js).write(to: out, atomically: true, encoding: .utf8)
                st_analysis_free(a)
            }
        }
    }
}

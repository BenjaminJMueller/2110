import Foundation

/// Eine über NMOS gefundene Quelle: ein Videosender und die dazugehörigen
/// Audiosender desselben Geräts (z. B. „SDI 1“ des 2110 IP Converter 3x3G).
public struct DiscoveredSource: Identifiable, Hashable, Sendable {
    public var id: String               // device_id + Gruppe
    public var title: String            // z. B. „Kamera 1 (SDI 1)“
    public var deviceLabel: String
    public var nodeLabel: String
    public var group: String
    public var video: NMOSSender?
    public var videoFlow: NMOSFlow?
    public var audio: [NMOSSender]
    public var audioFlows: [String: NMOSFlow]
    public var apiBase: URL
    public var connectionAPI: URL?
    public var host: String?
    public var pairingCertain: Bool     // true = per BCP-002-01 Gruppierung zugeordnet

    /// Kurzbeschreibung des Videoformats aus dem NMOS-Flow (vor dem SDP-Abruf)
    public var formatSummary: String? {
        guard let f = videoFlow else { return nil }
        var s = ""
        if let w = f.frame_width, let h = f.frame_height { s += "\(w)×\(h)" }
        s += f.isInterlaced ? "i" : "p"
        if let r = f.grain_rate {
            let v = r.value
            s += v == v.rounded() ? "\(Int(v))" : String(format: "%.2f", v)
        }
        if let bd = f.components?.first?.bit_depth { s += ", \(bd) Bit" }
        return s
    }
}

public enum SourceGrouping {
    /// Ordnet Sender zu Quellen. Reihenfolge der Regeln:
    /// 1. BCP-002-01 Grouphint-Tags (vom 3x3G laut Hersteller unterstützt)
    /// 2. gleiche Nummer im Label (z. B. „SDI 2 Video“ ↔ „SDI 2 Audio“) – als „vermutet“ gekennzeichnet
    /// 3. sonst: jeder Videosender einzeln, Audio frei zuordenbar
    public static func group(_ inv: NMOSInventory) -> [DiscoveredSource] {
        let flows = Dictionary(inv.flows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let devices = Dictionary(inv.devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let nodes = Dictionary(inv.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func format(_ s: NMOSSender) -> NMOSFormat {
            if let fid = s.flow_id, let f = flows[fid], let fmt = f.format { return fmt }
            let l = (s.label ?? "").lowercased()
            if l.contains("video") { return .video }
            if l.contains("audio") { return .audio }
            if l.contains("anc") || l.contains("data") { return .data }
            return .unknown
        }

        var result: [DiscoveredSource] = []
        let byDevice = Dictionary(grouping: inv.senders.filter { ($0.transport ?? "").contains("rtp") || $0.transport == nil },
                                  by: { $0.device_id ?? "?" })
        for (deviceID, senders) in byDevice {
            let dev = devices[deviceID]
            let node = dev?.node_id.flatMap { nodes[$0] }
            let deviceLabel = dev?.label ?? node?.label ?? "Gerät"
            let nodeLabel = node?.label ?? node?.hostname ?? ""
            let host = node?.api?.endpoints?.first?.host ?? inv.baseURL.host

            var groups: [String: (video: [NMOSSender], audio: [NMOSSender], certain: Bool)] = [:]
            var order: [String] = []
            for s in senders.sorted(by: { ($0.label ?? "") < ($1.label ?? "") }) {
                let fmt = format(s)
                guard fmt == .video || fmt == .audio else { continue }
                var key: String
                var certain = false
                if let hint = s.groupHints.first {
                    key = hint.group
                    certain = true
                } else if let n = firstNumber(in: s.label ?? "") {
                    key = "#\(n)"
                } else {
                    key = s.id
                }
                if groups[key] == nil { groups[key] = ([], [], certain); order.append(key) }
                if fmt == .video { groups[key]!.video.append(s) } else { groups[key]!.audio.append(s) }
                groups[key]!.certain = groups[key]!.certain || certain
            }
            for key in order {
                guard let g = groups[key] else { continue }
                // Mehrere Videos in einer Gruppe: einzeln anbieten
                let videos: [NMOSSender?] = g.video.isEmpty ? [nil] : g.video
                for v in videos {
                    let groupName = key.hasPrefix("#") ? (v?.label ?? key) : key
                    let title: String
                    if let v, let l = v.label, !l.isEmpty {
                        title = key.hasPrefix("#") || key == v.id ? stripMedia(l) : "\(key)"
                    } else {
                        title = groupName
                    }
                    var aFlows: [String: NMOSFlow] = [:]
                    for a in g.audio { if let fid = a.flow_id, let f = flows[fid] { aFlows[a.id] = f } }
                    result.append(DiscoveredSource(
                        id: "\(deviceID)/\(key)/\(v?.id ?? "-")",
                        title: title,
                        deviceLabel: deviceLabel,
                        nodeLabel: nodeLabel,
                        group: groupName,
                        video: v,
                        videoFlow: v?.flow_id.flatMap { flows[$0] },
                        audio: g.audio,
                        audioFlows: aFlows,
                        apiBase: inv.baseURL,
                        connectionAPI: dev?.connectionAPI,
                        host: host,
                        pairingCertain: g.certain && g.video.count <= 1))
                }
            }
        }
        return result.sorted { ($0.deviceLabel, $0.title) < ($1.deviceLabel, $1.title) }
    }

    static func firstNumber(in s: String) -> Int? {
        var digits = ""
        for ch in s {
            if ch.isNumber { digits.append(ch) } else if !digits.isEmpty { break }
        }
        return Int(digits)
    }

    static func stripMedia(_ label: String) -> String {
        var l = label
        for w in [" Video", " video", "-Video", "_Video", " Vid"] { l = l.replacingOccurrences(of: w, with: "") }
        return l.trimmingCharacters(in: .whitespaces)
    }
}


/// Ein Ziel im Netz, an das Essenz senden kann (z. B. SDI-Ausgang 1 eines
/// 2110 IP Converter 3x3G): Video- und Audioempfänger derselben Gruppe.
public struct DiscoveredDestination: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var deviceLabel: String
    public var video: NMOSReceiver?
    public var audio: [NMOSReceiver]
    public var connectionAPI: URL?
    public var pairingCertain: Bool
    public var connectedSenderIDs: [String] {
        ([video] + audio.map { Optional($0) }).compactMap { $0?.subscription?.sender_id }
    }
}

extension SourceGrouping {
    public static func destinations(_ inv: NMOSInventory) -> [DiscoveredDestination] {
        let devices = Dictionary(inv.devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [DiscoveredDestination] = []
        let byDevice = Dictionary(grouping: inv.receivers.filter { ($0.transport ?? "rtp").contains("rtp") }, by: { $0.device_id ?? "?" })
        for (deviceID, recs) in byDevice {
            let dev = devices[deviceID]
            var groups: [String: (v: [NMOSReceiver], a: [NMOSReceiver], certain: Bool)] = [:]
            var order: [String] = []
            for r in recs.sorted(by: { ($0.label ?? "") < ($1.label ?? "") }) {
                let fmt: NMOSFormat = r.format ?? ((r.label ?? "").lowercased().contains("audio") ? .audio : .video)
                guard fmt == .video || fmt == .audio else { continue }
                var key = r.id
                var certain = false
                if let h = r.groupHints.first { key = h.group; certain = true }
                else if let n = firstNumber(in: r.label ?? "") { key = "#\(n)" }
                if groups[key] == nil { groups[key] = ([], [], certain); order.append(key) }
                if fmt == .video { groups[key]!.v.append(r) } else { groups[key]!.a.append(r) }
            }
            for k in order {
                guard let g = groups[k] else { continue }
                let v = g.v.first
                let title = k.hasPrefix("#") ? stripMedia(v?.label ?? g.a.first?.label ?? k) : k
                out.append(DiscoveredDestination(id: "\(deviceID)/\(k)", title: title, deviceLabel: dev?.label ?? "Gerät",
                                                 video: v, audio: g.a, connectionAPI: dev?.connectionAPI,
                                                 pairingCertain: g.certain))
            }
        }
        return out.sorted { ($0.deviceLabel, $0.title) < ($1.deviceLabel, $1.title) }
    }
}

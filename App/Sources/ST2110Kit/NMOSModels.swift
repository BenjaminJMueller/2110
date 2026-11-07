import Foundation

// AMWA NMOS IS-04 (Discovery & Registration) v1.3 und IS-05 (Connection
// Management) v1.1 – nur die Felder, die für Empfang und Bedienung nötig sind.
// Alle Felder optional, damit abweichende Geräte nicht zum Abbruch führen.

public enum NMOSFormat: String, Codable, Sendable {
    case video = "urn:x-nmos:format:video"
    case audio = "urn:x-nmos:format:audio"
    case data = "urn:x-nmos:format:data"
    case mux = "urn:x-nmos:format:mux"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NMOSFormat(rawValue: raw) ?? .unknown
    }
}

public struct NMOSRational: Codable, Hashable, Sendable {
    public var numerator: Int
    public var denominator: Int?
    public var value: Double { Double(numerator) / Double(denominator ?? 1) }
}

public struct NMOSEndpoint: Codable, Hashable, Sendable {
    public var host: String?
    public var port: Int?
    public var `protocol`: String?
}

public struct NMOSNode: Codable, Hashable, Sendable {
    public var id: String
    public var label: String?
    public var description: String?
    public var hostname: String?
    public var href: String?
    public var api: API?
    public struct API: Codable, Hashable, Sendable {
        public var versions: [String]?
        public var endpoints: [NMOSEndpoint]?
    }
}

public struct NMOSControl: Codable, Hashable, Sendable {
    public var href: String
    public var type: String
}

public struct NMOSDevice: Codable, Hashable, Sendable {
    public var id: String
    public var label: String?
    public var description: String?
    public var type: String?
    public var node_id: String?
    public var senders: [String]?
    public var controls: [NMOSControl]?
    public var tags: [String: [String]]?

    /// Basis-URL der IS-05 Connection API (z. B. http://10.0.0.5/x-nmos/connection/v1.1/)
    public var connectionAPI: URL? {
        let c = controls?.filter { $0.type.hasPrefix("urn:x-nmos:control:sr-ctrl/") }
            .sorted { $0.type > $1.type }.first
        return c.flatMap { URL(string: $0.href) }
    }
}

public struct NMOSComponent: Codable, Hashable, Sendable {
    public var name: String?
    public var width: Int?
    public var height: Int?
    public var bit_depth: Int?
}

public struct NMOSFlow: Codable, Hashable, Sendable {
    public var id: String
    public var label: String?
    public var format: NMOSFormat?
    public var media_type: String?
    public var source_id: String?
    public var device_id: String?
    public var frame_width: Int?
    public var frame_height: Int?
    public var interlace_mode: String?
    public var colorspace: String?
    public var transfer_characteristic: String?
    public var grain_rate: NMOSRational?
    public var components: [NMOSComponent]?
    public var sample_rate: NMOSRational?
    public var bit_depth: Int?
    public var tags: [String: [String]]?

    public var isInterlaced: Bool {
        guard let m = interlace_mode else { return false }
        return m != "progressive"
    }
}

public struct NMOSSource: Codable, Hashable, Sendable {
    public var id: String
    public var label: String?
    public var format: NMOSFormat?
    public var device_id: String?
    public var channels: [Channel]?
    public var tags: [String: [String]]?
    public struct Channel: Codable, Hashable, Sendable {
        public var label: String?
        public var symbol: String?
    }
}

public struct NMOSSender: Codable, Hashable, Sendable {
    public var id: String
    public var version: String?
    public var label: String?
    public var description: String?
    public var flow_id: String?
    public var transport: String?
    public var device_id: String?
    public var manifest_href: String?
    public var tags: [String: [String]]?
    public var subscription: Subscription?
    public struct Subscription: Codable, Hashable, Sendable {
        public var receiver_id: String?
        public var active: Bool?
    }

    /// BCP-002-01 „Natural Grouping“: ["<Gruppe>:<Rolle>"]
    public var groupHints: [(group: String, role: String)] {
        let values = tags?["urn:x-nmos:tag:grouphint/v1.0"] ?? []
        return values.map { v in
            if let i = v.firstIndex(of: ":") {
                return (String(v[..<i]), String(v[v.index(after: i)...]))
            }
            return (v, "")
        }
    }
}

public struct NMOSReceiver: Codable, Hashable, Sendable {
    public var id: String
    public var version: String?
    public var label: String?
    public var description: String?
    public var format: NMOSFormat?
    public var transport: String?
    public var device_id: String?
    public var tags: [String: [String]]?
    public var caps: Caps?
    public var subscription: Subscription?
    public struct Caps: Codable, Hashable, Sendable {
        public var media_types: [String]?
    }
    public struct Subscription: Codable, Hashable, Sendable {
        public var sender_id: String?
        public var active: Bool?
    }
    public var groupHints: [(group: String, role: String)] {
        (tags?["urn:x-nmos:tag:grouphint/v1.0"] ?? []).map { v in
            if let i = v.firstIndex(of: ":") { return (String(v[..<i]), String(v[v.index(after: i)...])) }
            return (v, "")
        }
    }
}

/// IS-05 Sender-Parameter (aktiv bzw. vorbereitet)
public struct IS05SenderParams: Codable, Hashable, Sendable {
    public var master_enable: Bool?
    public var receiver_id: String?
    public var transport_params: [TransportParams]?
    public struct TransportParams: Codable, Hashable, Sendable {
        public var destination_ip: String?
        public var destination_port: IntOrAuto?
        public var source_ip: String?
        public var rtp_enabled: Bool?
    }
}

/// IS-05 erlaubt bei Ports den Wert "auto".
public enum IntOrAuto: Codable, Hashable, Sendable {
    case value(Int)
    case auto
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .value(i) } else { self = .auto }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .value(let i): try c.encode(i)
        case .auto: try c.encode("auto")
        }
    }
    public var intValue: Int? { if case .value(let i) = self { return i }; return nil }
}

/// Inventar eines Knotens (Node API) bzw. einer Registry (Query API)
public struct NMOSInventory: Sendable {
    public var baseURL: URL
    public var isRegistry: Bool
    public var nodes: [NMOSNode] = []
    public var devices: [NMOSDevice] = []
    public var sources: [NMOSSource] = []
    public var flows: [NMOSFlow] = []
    public var senders: [NMOSSender] = []
    public var receivers: [NMOSReceiver] = []
    public var fetchedAt = Date()

    public init(baseURL: URL, isRegistry: Bool) {
        self.baseURL = baseURL
        self.isRegistry = isRegistry
    }
}

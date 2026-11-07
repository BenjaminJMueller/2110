import Foundation

/// Gespeicherte Quelle. Video- und Audio-SDP werden getrennt gehalten, damit
/// getrennt gelieferte Beschreibungen derselben Quelle zugeordnet werden können.
public struct SavedSource: Codable, Identifiable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case sdp        // Datei, Drag-and-drop, Texteingabe
        case manual     // Experteneingabe
        case nmos       // über NMOS gefunden
    }

    public var id: UUID
    public var name: String
    public var origin: Origin
    public var videoSDP: String?
    public var audioSDP: String?
    /// Bei mehreren Audioströmen in einer SDP: Index des gewählten m=-Abschnitts
    public var audioMediaIndex: Int?
    public var nmos: NMOSReference?
    public var interfaceName: String?
    public var monitorLeft: Int?
    public var monitorRight: Int?
    public var createdAt: Date
    public var lastUsed: Date?

    public init(id: UUID = UUID(), name: String, origin: Origin, videoSDP: String? = nil,
                audioSDP: String? = nil, nmos: NMOSReference? = nil) {
        self.id = id
        self.name = name
        self.origin = origin
        self.videoSDP = videoSDP
        self.audioSDP = audioSDP
        self.nmos = nmos
        self.createdAt = Date()
    }
}

public struct NMOSReference: Codable, Hashable, Sendable {
    public var apiBase: URL
    public var connectionAPI: URL?
    public var videoSenderID: String?
    public var audioSenderID: String?
    public var videoSenderVersion: String?
    public var audioSenderVersion: String?

    public init(apiBase: URL, connectionAPI: URL?, videoSenderID: String?, audioSenderID: String?) {
        self.apiBase = apiBase
        self.connectionAPI = connectionAPI
        self.videoSenderID = videoSenderID
        self.audioSenderID = audioSenderID
    }
}

/// Speichert Quellen als JSON in ~/Library/Application Support/ST2110 Monitor/.
public final class SourceStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Essenz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("sources.json")
    }

    public func load() -> [SavedSource] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([SavedSource].self, from: data)) ?? []
    }

    public func save(_ sources: [SavedSource]) {
        lock.lock(); defer { lock.unlock() }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(sources) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Zerlegt SDP-Text in Medienabschnitte, damit eine gemeinsame SDP mit Video
/// und Audio in zwei getrennte Beschreibungen (gleicher Sitzungsteil) aufgeteilt
/// werden kann.
public enum SDPText {
    public enum Kind: String, Sendable { case video, audio, other }

    public struct Section: Sendable {
        public var kind: Kind
        public var text: String      // vollständige SDP: Sitzungsteil + dieser Abschnitt
        public var mLine: String
    }

    public static func sections(_ sdp: String) -> [Section] {
        let lines = sdp.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var session: [String] = []
        var media: [[String]] = []
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("m=") { media.append([t]) }
            else if media.isEmpty { session.append(t) }
            else { media[media.count - 1].append(t) }
        }
        // a=group:DUP gehört zur Sitzung, ist aber für einen einzelnen Abschnitt falsch.
        let sessionClean = session.filter { !$0.hasPrefix("a=group:") }
        return media.map { m in
            let kind: Kind
            if m[0].hasPrefix("m=video") {
                kind = m.contains(where: { $0.lowercased().contains("smpte291") }) ? .other : .video
            } else if m[0].hasPrefix("m=audio") {
                kind = .audio
            } else {
                kind = .other
            }
            return Section(kind: kind, text: (sessionClean + m).joined(separator: "\r\n") + "\r\n", mLine: m[0])
        }
    }

    /// Sieht der Text nach SDP aus?
    public static func looksLikeSDP(_ s: String) -> Bool {
        s.contains("v=0") || s.range(of: "\nm=") != nil || s.hasPrefix("m=")
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstrakter HTTP-Zugriff (für Tests austauschbar).
public protocol HTTPFetching: Sendable {
    func get(_ url: URL) async throws -> (Data, Int)
    func send(_ url: URL, method: String, body: Data) async throws -> (Data, Int)
}

public struct URLSessionFetcher: HTTPFetching {
    let session: URLSession
    public init(timeout: TimeInterval = 4) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }
    public func get(_ url: URL) async throws -> (Data, Int) {
        let (d, r) = try await session.data(from: url)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }
    public func send(_ url: URL, method: String, body: Data) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (d, r) = try await session.data(for: req)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum NMOSError: LocalizedError, Equatable {
    case http(Int, String)
    case noAPI(String)
    case noSDP(String)
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let url): return "Das Gerät antwortete mit HTTP \(code) (\(url))."
        case .noAPI(let host): return "Unter \(host) wurde keine NMOS-Schnittstelle (IS-04) gefunden."
        case .noSDP(let label): return "Für „\(label)“ stellt das Gerät keine SDP-Beschreibung bereit (manifest_href fehlt). Möglicherweise ist der Sender deaktiviert."
        case .decode(let what): return "Antwort des Geräts nicht lesbar: \(what)."
        }
    }
}

public struct NMOSClient: Sendable {
    public let http: HTTPFetching
    public static let supportedVersions = ["v1.3", "v1.2", "v1.1", "v1.0"]

    public init(http: HTTPFetching = URLSessionFetcher()) {
        self.http = http
    }

    /// Ermittelt aus einer beliebigen Benutzereingabe („10.0.0.5“, „10.0.0.5:8080“,
    /// „http://host/x-nmos/node/v1.3/“) die Basis-URL der Node bzw. Query API.
    public func resolveBase(_ input: String, registry: Bool = false) async throws -> URL {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        guard var url = URL(string: s), url.host != nil else { throw NMOSError.noAPI(input) }
        let api = registry ? "query" : "node"
        if url.path.contains("/x-nmos/") {
            if !url.path.hasSuffix("/") { url = URL(string: url.absoluteString + "/")! }
            return url
        }
        let root = URL(string: "\(url.scheme ?? "http")://\(url.host!)\(url.port.map { ":\($0)" } ?? "")/x-nmos/\(api)/")!
        let (data, code) = try await http.get(root)
        if code == 200, let versions = try? JSONDecoder().decode([String].self, from: data) {
            let clean = versions.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            if let v = Self.supportedVersions.first(where: { clean.contains($0) }) {
                return root.appendingPathComponent(v + "/", isDirectory: true)
            }
        }
        // Manche Geräte liefern die Versionsliste nicht; v1.3 direkt probieren.
        let v13 = root.appendingPathComponent("v1.3/", isDirectory: true)
        let (_, c2) = try await http.get(v13.appendingPathComponent(registry ? "senders" : "self"))
        if c2 == 200 { return v13 }
        throw NMOSError.noAPI(url.host ?? input)
    }

    func list<T: Decodable>(_ base: URL, _ path: String, _ type: T.Type) async throws -> T {
        let url = base.appendingPathComponent(path)
        let (data, code) = try await http.get(url)
        guard code == 200 else { throw NMOSError.http(code, url.absoluteString) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NMOSError.decode("\(path): \(error.localizedDescription)")
        }
    }

    /// Lädt Geräte, Flows und Sender eines Knotens bzw. einer Registry.
    public func inventory(base: URL, isRegistry: Bool) async throws -> NMOSInventory {
        var inv = NMOSInventory(baseURL: base, isRegistry: isRegistry)
        if isRegistry {
            inv.nodes = (try? await list(base, "nodes", [NMOSNode].self)) ?? []
        } else if let node = try? await list(base, "self", NMOSNode.self) {
            inv.nodes = [node]
        }
        inv.devices = try await list(base, "devices", [NMOSDevice].self)
        inv.sources = (try? await list(base, "sources", [NMOSSource].self)) ?? []
        inv.flows = (try? await list(base, "flows", [NMOSFlow].self)) ?? []
        inv.senders = try await list(base, "senders", [NMOSSender].self)
        inv.receivers = (try? await list(base, "receivers", [NMOSReceiver].self)) ?? []
        inv.fetchedAt = Date()
        return inv
    }

    public func sender(base: URL, id: String) async throws -> NMOSSender {
        try await list(base, "senders/\(id)", NMOSSender.self)
    }

    /// SDP eines Senders: zuerst manifest_href (IS-04), sonst IS-05 transportfile.
    public func sdp(for sender: NMOSSender, connectionAPI: URL?) async throws -> String {
        var urls: [URL] = []
        if let m = sender.manifest_href, let u = URL(string: m) { urls.append(u) }
        if let c = connectionAPI {
            urls.append(c.appendingPathComponent("single/senders/\(sender.id)/transportfile"))
        }
        for u in urls {
            if let (data, code) = try? await http.get(u), code == 200,
               let text = String(data: data, encoding: .utf8), text.contains("m=") {
                return text
            }
        }
        throw NMOSError.noSDP(sender.label ?? sender.id)
    }

    // MARK: IS-05

    public func activeParams(connectionAPI: URL, senderID: String) async throws -> IS05SenderParams {
        try await list(connectionAPI, "single/senders/\(senderID)/active", IS05SenderParams.self)
    }

    /// Verbindet einen Empfänger (z. B. SDI-Ausgang eines 2110 IP Converter) per
    /// IS-05 mit einem Sender: SDP als transport_file, sofort aktiv.
    /// Achtung: ändert das Routing des Geräts.
    public func connectReceiver(connectionAPI: URL, receiverID: String, senderID: String?, sdp: String?, enable: Bool) async throws {
        var body: [String: Any] = [
            "master_enable": enable,
            "activation": ["mode": "activate_immediate"],
        ]
        if enable {
            body["sender_id"] = senderID ?? NSNull()
            if let sdp { body["transport_file"] = ["data": sdp, "type": "application/sdp"] }
        } else {
            body["sender_id"] = NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let url = connectionAPI.appendingPathComponent("single/receivers/\(receiverID)/staged")
        let (resp, code) = try await http.send(url, method: "PATCH", body: data)
        guard code == 200 || code == 202 else {
            let msg = String(data: resp, encoding: .utf8) ?? ""
            throw NMOSError.http(code, url.absoluteString + (msg.isEmpty ? "" : " – \(msg.prefix(300))"))
        }
    }

    /// Aktiviert einen Sender und setzt optional Ziel-Multicastadresse/-port.
    /// Achtung: verändert die Gerätekonfiguration für alle Empfänger im Netz.
    public func activateSender(connectionAPI: URL, senderID: String, enable: Bool,
                               destinationIP: String? = nil, destinationPort: Int? = nil) async throws {
        var body: [String: Any] = [
            "master_enable": enable,
            "activation": ["mode": "activate_immediate"],
        ]
        if destinationIP != nil || destinationPort != nil {
            var leg: [String: Any] = [:]
            if let ip = destinationIP { leg["destination_ip"] = ip }
            if let p = destinationPort { leg["destination_port"] = p }
            body["transport_params"] = [leg]
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let url = connectionAPI.appendingPathComponent("single/senders/\(senderID)/staged")
        let (resp, code) = try await http.send(url, method: "PATCH", body: data)
        guard code == 200 || code == 202 else {
            let msg = String(data: resp, encoding: .utf8) ?? ""
            throw NMOSError.http(code, url.absoluteString + (msg.isEmpty ? "" : " – \(msg.prefix(200))"))
        }
    }
}

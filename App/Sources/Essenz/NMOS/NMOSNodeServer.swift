import Foundation
import Network
import ST2110Kit

/// Minimaler NMOS-Knoten (IS-04 Node API v1.3, IS-05 Connection API v1.1 für
/// Sender) über HTTP, angekündigt per mDNS (_nmos-node._tcp). So finden
/// NMOS-fähige Empfänger und Controller den Essenz-Sender ohne Registry.
/// Optional zusätzlich Registrierung bei einer Registry (IS-04 Registration API).
final class NMOSNodeServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Essenz NMOS-Knoten")
    private let lock = NSLock()
    private var resources: NMOSNodeResources?
    private var sdpVideo: String?
    private var sdpAudio: String?
    private var heartbeat: Timer?
    private var registryBase: URL?
    private(set) var port: Int = 0
    var onMasterEnable: ((Bool) -> Void)?
    var onStatus: ((String) -> Void)?

    func start(name: String, completion: @escaping (Int?) -> Void) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: .any)
            l.service = NWListener.Service(name: name, type: "_nmos-node._tcp", domain: nil,
                                           txtRecord: NWTXTRecord(["api_proto": "http", "api_ver": "v1.0,v1.1,v1.2,v1.3",
                                                                   "api_auth": "false", "pri": "100"]))
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    let p = Int(l.port?.rawValue ?? 0)
                    self?.port = p
                    completion(p)
                case .failed(let e):
                    self?.onStatus?("NMOS-Knoten konnte nicht starten: \(e.localizedDescription)")
                    completion(nil)
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            onStatus?("NMOS-Knoten konnte nicht starten: \(error.localizedDescription)")
            completion(nil)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async { self.heartbeat?.invalidate(); self.heartbeat = nil }
        if let base = registryBase, let id = current?.ids.node {
            var req = URLRequest(url: base.appendingPathComponent("resource/nodes/\(id)"))
            req.httpMethod = "DELETE"
            URLSession.shared.dataTask(with: req).resume()
        }
        registryBase = nil
    }

    func update(resources r: NMOSNodeResources, sdpVideo v: String?, sdpAudio a: String?) {
        lock.lock()
        resources = r
        sdpVideo = v
        sdpAudio = a
        lock.unlock()
    }

    private var current: NMOSNodeResources? { lock.lock(); defer { lock.unlock() }; return resources }

    // MARK: Registry

    func register(registry: URL) {
        registryBase = registry
        Task { await self.postAll() }
        DispatchQueue.main.async {
            self.heartbeat?.invalidate()
            self.heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let self, let base = self.registryBase, let id = self.current?.ids.node else { return }
                var req = URLRequest(url: base.appendingPathComponent("health/nodes/\(id)"))
                req.httpMethod = "POST"
                URLSession.shared.dataTask(with: req) { _, resp, _ in
                    if (resp as? HTTPURLResponse)?.statusCode == 404 { Task { await self.postAll() } }
                }.resume()
            }
        }
    }

    private func postAll() async {
        guard let base = registryBase, let r = current else { return }
        var items: [(String, Any)] = [("node", r.node), ("device", r.device)]
        items += r.sources.map { ("source", $0) }
        items += r.flows.map { ("flow", $0) }
        items += r.senders.map { ("sender", $0) }
        for (type, data) in items {
            var req = URLRequest(url: base.appendingPathComponent("resource"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = NMOSNodeResources.json(["type": type, "data": data])
            if let (_, resp) = try? await URLSession.shared.data(for: req), let code = (resp as? HTTPURLResponse)?.statusCode, code >= 300 {
                onStatus?("Registry lehnt \(type) ab (HTTP \(code)).")
            }
        }
    }

    // MARK: HTTP

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let parts = lines.first?.split(separator: " ") ?? []
                let method = parts.count > 0 ? String(parts[0]) : "GET"
                let path = parts.count > 1 ? String(parts[1]) : "/"
                let len = lines.compactMap { l -> Int? in
                    let kv = l.split(separator: ":", maxSplits: 1)
                    return kv.count == 2 && kv[0].lowercased() == "content-length" ? Int(kv[1].trimmingCharacters(in: .whitespaces)) : nil
                }.first ?? 0
                let bodyStart = range.upperBound
                if buf.count - bodyStart < len, !done, err == nil {
                    self.receive(c, buffer: buf)
                    return
                }
                let body = buf.count >= bodyStart + len ? buf[bodyStart..<(bodyStart + len)] : Data()
                let (status, type, out) = self.route(method: method, path: path, body: Data(body))
                var resp = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(out.count)\r\n"
                resp += "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
                var d = Data(resp.utf8)
                d.append(out)
                c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
            } else if done || err != nil || buf.count > 1_000_000 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private func route(method: String, path rawPath: String, body: Data) -> (String, String, Data) {
        let json = "application/json"
        let ok = "200 OK"
        guard let r = current else { return ("503 Service Unavailable", json, Data("{}".utf8)) }
        var path = rawPath.components(separatedBy: "?")[0]
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        func j(_ o: Any) -> (String, String, Data) { (ok, json, NMOSNodeResources.json(o)) }
        func find(_ list: [[String: Any]], _ id: String) -> (String, String, Data) {
            if let x = list.first(where: { ($0["id"] as? String) == id }) { return j(x) }
            return ("404 Not Found", json, Data("{\"code\":404,\"error\":\"not found\"}".utf8))
        }
        let senderIDs = r.senders.compactMap { $0["id"] as? String }
        let comps = path.split(separator: "/").map(String.init)
        switch comps {
        case ["sdp", "video.sdp"]: return (ok, "application/sdp", Data((sdpVideo ?? "").utf8))
        case ["sdp", "audio.sdp"]: return (ok, "application/sdp", Data((sdpAudio ?? "").utf8))
        case ["x-nmos"]: return j(["node/", "connection/"])
        case ["x-nmos", "node"]: return j(["v1.3/"])
        case ["x-nmos", "node", "v1.3"]: return j(["self/", "sources/", "flows/", "devices/", "senders/", "receivers/"])
        case ["x-nmos", "node", "v1.3", "self"]: return j(r.node)
        case ["x-nmos", "node", "v1.3", "devices"]: return j([r.device])
        case ["x-nmos", "node", "v1.3", "sources"]: return j(r.sources)
        case ["x-nmos", "node", "v1.3", "flows"]: return j(r.flows)
        case ["x-nmos", "node", "v1.3", "senders"]: return j(r.senders)
        case ["x-nmos", "node", "v1.3", "receivers"]: return j([Any]())
        case _ where comps.count == 5 && comps.starts(with: ["x-nmos", "node", "v1.3"]):
            switch comps[3] {
            case "devices": return find([r.device], comps[4])
            case "sources": return find(r.sources, comps[4])
            case "flows": return find(r.flows, comps[4])
            case "senders": return find(r.senders, comps[4])
            default: break
            }
        case ["x-nmos", "connection"]: return j(["v1.1/"])
        case ["x-nmos", "connection", "v1.1"]: return j(["single/"])
        case ["x-nmos", "connection", "v1.1", "single"]: return j(["senders/", "receivers/"])
        case ["x-nmos", "connection", "v1.1", "single", "senders"]: return j(senderIDs.map { $0 + "/" })
        case ["x-nmos", "connection", "v1.1", "single", "receivers"]: return j([String]())
        default: break
        }
        if comps.count >= 6, comps.starts(with: ["x-nmos", "connection", "v1.1", "single", "senders"]), senderIDs.contains(comps[5]) {
            let isVideo = comps[5] == r.ids.videoSender
            let leaf = comps.count > 6 ? comps[6] : ""
            switch leaf {
            case "": return j(["constraints/", "staged/", "active/", "transportfile/", "transporttype/"])
            case "constraints": return j([["source_ip": [String: Any](), "destination_ip": [String: Any](), "destination_port": [String: Any]()]])
            case "transporttype": return j("urn:x-nmos:transport:rtp.mcast")
            case "transportfile": return (ok, "application/sdp", Data(((isVideo ? sdpVideo : sdpAudio) ?? "").utf8))
            case "active": return j(r.transportParams(video: isVideo))
            case "staged":
                if method == "PATCH", let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let en = o["master_enable"] as? Bool {
                    DispatchQueue.main.async { self.onMasterEnable?(en) }
                }
                return j(r.transportParams(video: isVideo))
            default: break
            }
        }
        return ("404 Not Found", json, Data("{\"code\":404,\"error\":\"not found\"}".utf8))
    }
}

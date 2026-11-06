import Foundation
import Network
import ST2110Kit

/// NMOS-Erkennung:
///  • Peer-to-Peer per mDNS/DNS-SD (_nmos-node._tcp) – laut Blackmagic vom
///    2110 IP Converter 3x3G unterstützt, keine Registry nötig
///  • Registry (Query API) per mDNS (_nmos-query._tcp) oder manuell eingetragen
///  • manuell eingetragene Geräteadressen
///  • Suche in einem einstellbaren Adressbereich (falls mDNS im Netz blockiert ist)
@MainActor
@Observable
final class NMOSDiscovery {
    struct Endpoint: Hashable {
        enum Origin: String { case mdns = "mDNS", registry = "Registry", manual = "manuell", scan = "Adressbereich" }
        var base: URL
        var isRegistry: Bool
        var origin: Origin
        var label: String
    }

    private(set) var endpoints: [Endpoint] = []
    private(set) var inventories: [URL: NMOSInventory] = [:]
    private(set) var errors: [URL: String] = [:]
    private(set) var sources: [DiscoveredSource] = []
    private(set) var isScanning = false
    private(set) var scanProgress = 0.0
    private(set) var lastRefresh: Date?
    private(set) var browserState = "aus"

    let client = NMOSClient()
    private var browsers: [NWBrowser] = []
    private var resolvers: [NWConnection] = []
    private var refreshTask: Task<Void, Never>?
    private var pendingResolve: Set<String> = []

    func start(settings: AppSettings) {
        stop()
        if settings.mdnsDiscovery {
            browse(type: "_nmos-node._tcp", registry: false)
            browse(type: "_nmos-query._tcp", registry: true)
        } else {
            browserState = "aus (in „Erweitert“ deaktiviert)"
        }
        for n in settings.manualNodes { addManual(n, registry: false) }
        if !settings.registryURL.trimmingCharacters(in: .whitespaces).isEmpty {
            addManual(settings.registryURL, registry: true)
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        resolvers.forEach { $0.cancel() }
        resolvers.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func browse(type: String, registry: Bool) {
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: params)
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.browserState = "aktiv"
                case .failed(let e): self?.browserState = "Fehler: \(e.localizedDescription)"
                case .waiting(let e): self?.browserState = "wartet: \(e.localizedDescription) – evtl. Zugriff auf „Lokales Netzwerk“ nicht erlaubt"
                default: break
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                for r in results { self?.resolve(r, registry: registry) }
            }
        }
        b.start(queue: .main)
        browsers.append(b)
    }

    private func resolve(_ result: NWBrowser.Result, registry: Bool) {
        guard case let .service(name, _, _, _) = result.endpoint else { return }
        let key = "\(registry)-\(name)"
        guard !pendingResolve.contains(key), !endpoints.contains(where: { $0.label == name && $0.origin == .mdns }) else { return }
        pendingResolve.insert(key)
        var proto = "http"
        if case let .bonjour(txt) = result.metadata, let p = txt["api_proto"] { proto = p }
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: result.endpoint, using: params)
        c.stateUpdateHandler = { [weak self] st in
            if case .ready = st, case let .hostPort(host, port)? = c.currentPath?.remoteEndpoint {
                var h = "\(host)"
                if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                let url = URL(string: "\(proto)://\(h):\(port.rawValue)/")
                c.cancel()
                Task { @MainActor in
                    guard let self, let url else { return }
                    self.pendingResolve.remove(key)
                    if let base = try? await self.client.resolveBase(url.absoluteString, registry: registry) {
                        self.add(Endpoint(base: base, isRegistry: registry, origin: registry ? .registry : .mdns, label: name))
                    }
                }
            } else if case .failed = st {
                c.cancel()
                Task { @MainActor in self?.pendingResolve.remove(key) }
            }
        }
        c.start(queue: .main)
        resolvers.append(c)
    }

    func addManual(_ input: String, registry: Bool) {
        Task {
            do {
                let base = try await client.resolveBase(input, registry: registry)
                add(Endpoint(base: base, isRegistry: registry, origin: registry ? .registry : .manual, label: input))
            } catch {
                errors[URL(string: "manual://\(input)")!] = error.localizedDescription
            }
        }
    }

    /// Prüft eine einzelne Adresse und meldet einen Fehlertext zurück (für die Eingabemaske).
    func probe(_ input: String, registry: Bool) async -> String? {
        do {
            let base = try await client.resolveBase(input, registry: registry)
            add(Endpoint(base: base, isRegistry: registry, origin: registry ? .registry : .manual, label: input))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func add(_ e: Endpoint) {
        guard !endpoints.contains(where: { $0.base == e.base }) else { return }
        endpoints.append(e)
        Task { await refresh(e) }
    }

    func refreshAll() async {
        for e in endpoints { await refresh(e) }
        lastRefresh = Date()
    }

    private func refresh(_ e: Endpoint) async {
        do {
            let inv = try await client.inventory(base: e.base, isRegistry: e.isRegistry)
            inventories[e.base] = inv
            errors[e.base] = nil
        } catch {
            errors[e.base] = error.localizedDescription
        }
        rebuild()
    }

    private func rebuild() {
        var seen = Set<String>()
        var all: [DiscoveredSource] = []
        // Node-APIs zuerst (aktuellere Daten), dann Registry
        let invs = inventories.values.sorted { !$0.isRegistry && $1.isRegistry }
        for inv in invs {
            for s in SourceGrouping.group(inv) {
                let key = s.video?.id ?? s.audio.first?.id ?? s.id
                if seen.insert(key).inserted { all.append(s) }
            }
        }
        sources = all
    }

    /// Durchsucht die in „Erweitert“ eingestellten Adressbereiche nach NMOS-Knoten.
    func scan(ranges: String, ports: String) async -> String {
        guard let rs = AddressRange.parseList(ranges), !rs.isEmpty else {
            return "Adressbereich nicht lesbar. Beispiel: 192.168.10.1-254 oder 192.168.10.0/24"
        }
        let portList = PortList.parse(ports) ?? [80]
        let addrs = rs.flatMap { $0.addresses }
        guard addrs.count <= 4096 else { return "Bereich zu groß (\(addrs.count) Adressen, maximal 4096)." }
        isScanning = true
        scanProgress = 0
        defer { isScanning = false }
        let quick = NMOSClient(http: URLSessionFetcher(timeout: 0.8))
        var targets: [String] = []
        for a in addrs { for p in portList { targets.append("\(a):\(p)") } }
        var found = 0
        var done = 0
        let total = targets.count
        await withTaskGroup(of: URL?.self) { group in
            var it = targets.makeIterator()
            for _ in 0..<min(48, total) {
                if let t = it.next() { group.addTask { try? await quick.resolveBase(t, registry: false) } }
            }
            while let r = await group.next() {
                done += 1
                scanProgress = Double(done) / Double(max(total, 1))
                if let base = r {
                    found += 1
                    add(Endpoint(base: base, isRegistry: false, origin: .scan, label: base.host ?? "?"))
                }
                if let t = it.next() { group.addTask { try? await quick.resolveBase(t, registry: false) } }
            }
        }
        return found == 0 ? "Keine NMOS-Knoten in \(addrs.count) Adressen gefunden." : "\(found) NMOS-Knoten gefunden."
    }
}

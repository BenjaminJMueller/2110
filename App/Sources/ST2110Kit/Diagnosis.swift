import Foundation

/// Erzeugt verständliche Hinweise aus dem Empfangszustand. Grundsatz: Nur was
/// gemessen ist, wird als Tatsache formuliert; Ursachen, die nur vermutet
/// werden können, sind als „mögliche Ursache“ gekennzeichnet.
public struct Hint: Identifiable, Hashable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case info = 0, warning = 1, error = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public enum Certainty: Sendable { case measured, suspected }

    public var id: String
    public var severity: Severity
    public var certainty: Certainty
    public var title: String
    public var detail: String

    public init(id: String, severity: Severity, certainty: Certainty, title: String, detail: String) {
        self.id = id
        self.severity = severity
        self.certainty = certainty
        self.title = title
        self.detail = detail
    }
}

public struct InterfaceSnapshot: Hashable, Sendable {
    public var name: String
    public var displayName: String
    public var ipv4: String?
    public var netmask: String?
    public var isUp: Bool
    public var isWireless: Bool
    public var linkSpeedBps: UInt64

    public init(name: String, displayName: String, ipv4: String?, netmask: String?, isUp: Bool,
                isWireless: Bool, linkSpeedBps: UInt64) {
        self.name = name
        self.displayName = displayName
        self.ipv4 = ipv4
        self.netmask = netmask
        self.isUp = isUp
        self.isWireless = isWireless
        self.linkSpeedBps = linkSpeedBps
    }

    public func contains(_ address: String) -> Bool {
        guard let ip = ipv4.flatMap(IPv4.init), let m = netmask.flatMap(IPv4.init),
              let other = IPv4(address) else { return false }
        return ip.inSubnet(of: other, mask: m)
    }

    public var speedText: String? {
        guard linkSpeedBps > 0 else { return nil }
        if linkSpeedBps >= 1_000_000_000 { return "\(linkSpeedBps / 1_000_000_000) Gbit/s" }
        return "\(linkSpeedBps / 1_000_000) Mbit/s"
    }
}

public enum InterfaceChoice {
    /// Wählt die sinnvollste Schnittstelle: im Netz des Senders > kabelgebunden
    /// mit IPv4 (schnellste zuerst) > beliebig mit IPv4.
    public static func preferred(_ list: [InterfaceSnapshot], senderAddresses: [String]) -> InterfaceSnapshot? {
        let usable = list.filter { $0.isUp && $0.ipv4 != nil && $0.name != "lo0" }
        for a in senderAddresses where !(IPv4(a)?.isMulticast ?? true) {
            if let hit = usable.first(where: { $0.contains(a) }) { return hit }
        }
        let wired = usable.filter { !$0.isWireless && !$0.name.hasPrefix("utun") && !$0.name.hasPrefix("bridge") && !$0.name.hasPrefix("awdl") && !$0.name.hasPrefix("llw") }
        if let best = wired.max(by: { $0.linkSpeedBps < $1.linkSpeedBps }) { return best }
        return usable.first
    }
}

public struct DiagnosisInput: Sendable {
    public enum State: Sendable { case stopped, starting, waiting, receiving, stalled, error }
    public var state: State
    public var secondsInState: Double
    public var expectsVideo: Bool
    public var expectsAudio: Bool
    public var videoPackets: UInt64
    public var audioPackets: UInt64
    public var videoLost: UInt64
    public var audioLost: UInt64
    public var videoRateMbps: Double
    public var framesDropped: UInt64
    public var interface: InterfaceSnapshot?
    public var otherInterfaces: [InterfaceSnapshot]
    public var senderAddress: String?
    public var multicastGroups: [String]
    public var ptpRequested: Bool
    public var ptpActive: Bool
    public var ptpDomainsSeen: Int
    public var ptpGrandmasterMatchesSDP: Int    // -1 unbekannt
    public var nmosSenderEnabled: Bool?
    public var socketBufferBytes: Int
    public var latencyRaised: Bool
    public var latencyMs: Double

    public init(state: State) {
        self.state = state
        secondsInState = 0
        expectsVideo = false
        expectsAudio = false
        videoPackets = 0
        audioPackets = 0
        videoLost = 0
        audioLost = 0
        videoRateMbps = 0
        framesDropped = 0
        otherInterfaces = []
        multicastGroups = []
        ptpRequested = false
        ptpActive = false
        ptpDomainsSeen = 0
        ptpGrandmasterMatchesSDP = -1
        socketBufferBytes = 0
        latencyRaised = false
        latencyMs = 0
    }
}

public enum Diagnosis {
    public static func hints(_ d: DiagnosisInput) -> [Hint] {
        var out: [Hint] = []
        let iface = d.interface

        if let i = iface, d.state != .stopped {
            if !i.isUp {
                out.append(Hint(id: "if-down", severity: .error, certainty: .measured,
                                title: "Netzwerkschnittstelle ohne Verbindung",
                                detail: "„\(i.displayName)“ hat keine Verbindung. Kabel oder Adapter prüfen."))
            } else if i.ipv4 == nil {
                out.append(Hint(id: "if-noip", severity: .error, certainty: .measured,
                                title: "Schnittstelle ohne IPv4-Adresse",
                                detail: "„\(i.displayName)“ hat keine IPv4-Adresse. ST 2110 benötigt IPv4. Unter Systemeinstellungen › Netzwerk eine Adresse im Netz der Blackmagic-Geräte vergeben (oder DHCP)."))
            }
            if i.isWireless {
                out.append(Hint(id: "if-wifi", severity: .warning, certainty: .measured,
                                title: "WLAN ausgewählt",
                                detail: "ST 2110 braucht 1 bis 2,6 Gbit/s je HD-Strom, das schafft WLAN nicht. Ethernet wählen, etwa einen 10-GbE-Adapter."))
            } else if i.linkSpeedBps > 0 && i.linkSpeedBps < 2_500_000_000 && d.expectsVideo {
                out.append(Hint(id: "if-slow", severity: .warning, certainty: .measured,
                                title: "Verbindung zu langsam für unkomprimiertes HD-Video",
                                detail: "Die Schnittstelle hat \(i.speedText ?? "?"). 1080p25 braucht etwa 1,1 Gbit/s, 1080p50 etwa 2,2 Gbit/s. 10-GbE verwenden."))
            }
            if let s = d.senderAddress, IPv4(s) != nil, !(IPv4(s)?.isMulticast ?? false), i.ipv4 != nil, !i.contains(s) {
                let alt = d.otherInterfaces.first(where: { $0.contains(s) && $0.name != i.name })
                out.append(Hint(id: "if-subnet", severity: .warning, certainty: .suspected,
                                title: "Möglicherweise falsche Netzwerkschnittstelle",
                                detail: "Der Sender (\(s)) liegt nicht im Netz von „\(i.displayName)“ (\(i.ipv4 ?? "")/\(i.netmask ?? ""))."
                                    + (alt.map { " Die Schnittstelle „\($0.displayName)“ (\($0.name)) passt zum Sender." } ?? "")))
            }
        }

        switch d.state {
        case .waiting where d.secondsInState >= 3:
            let missing = [d.expectsVideo && d.videoPackets == 0 ? "Video" : nil,
                           d.expectsAudio && d.audioPackets == 0 ? "Audio" : nil].compactMap { $0 }
            out.append(Hint(id: "no-packets", severity: .error, certainty: .measured,
                            title: "Keine Daten empfangen",
                            detail: "Seit \(Int(d.secondsInState)) s sind keine Pakete für \(missing.joined(separator: " und ")) angekommen (Gruppe \(d.multicastGroups.joined(separator: ", ")))."))
            if d.nmosSenderEnabled == false {
                out.append(Hint(id: "nmos-disabled", severity: .error, certainty: .measured,
                                title: "Sender ist am Gerät deaktiviert",
                                detail: "Laut NMOS ist der Sender aus. Unter „Erweitert“ lässt er sich einschalten."))
            }
            out.append(Hint(id: "mc-causes", severity: .info, certainty: .suspected,
                            title: "Mögliche Ursachen",
                            detail: "• Falsche Netzwerkschnittstelle gewählt\n• Switch leitet Multicast nicht weiter (IGMP-Snooping ohne IGMP-Querier, laut Blackmagic ist IGMPv3 nötig)\n• Sender nicht aktiv oder andere Multicast-Adresse als in der SDP\n• macOS-Firewall blockiert eingehende Daten für diese App\n• Zugriff auf „Lokales Netzwerk“ für diese App nicht erlaubt (Systemeinstellungen › Datenschutz & Sicherheit)"))
            if d.ptpRequested && d.ptpDomainsSeen > 0 {
                out.append(Hint(id: "ptp-seen", severity: .info, certainty: .measured,
                                title: "Netz grundsätzlich erreichbar",
                                detail: "PTP kommt an, das Netz steht. Vermutlich betrifft es nur die Multicast-Ströme."))
            }
        case .stalled:
            out.append(Hint(id: "stalled", severity: .error, certainty: .measured,
                            title: "Signal unterbrochen",
                            detail: "Seit \(Int(d.secondsInState)) s keine Pakete. Die App verbindet sich neu, sobald wieder Daten kommen."))
            out.append(Hint(id: "stalled-causes", severity: .info, certainty: .suspected,
                            title: "Mögliche Ursachen",
                            detail: "• Sender neu gestartet oder umkonfiguriert\n• SDI-Signal am Blackmagic-Gerät fehlt\n• Kabel/Adapter getrennt\n• Multicast-Mitgliedschaft am Switch abgelaufen (IGMP-Querier fehlt)"))
        default:
            break
        }

        if d.state == .receiving {
            if d.expectsVideo && d.videoPackets == 0 && d.secondsInState > 3 {
                out.append(Hint(id: "video-missing", severity: .warning, certainty: .measured,
                                title: "Nur Audio empfangen",
                                detail: "Audio kommt an, Video nicht. Videoadresse und Port in der SDP prüfen."))
            }
            if d.expectsAudio && d.audioPackets == 0 && d.secondsInState > 3 {
                out.append(Hint(id: "audio-missing", severity: .warning, certainty: .measured,
                                title: "Nur Video empfangen",
                                detail: "Video kommt an, Audio nicht. Audio-SDP prüfen oder Audiosender am Gerät einschalten."))
            }
            let vTotal = d.videoPackets + d.videoLost
            if vTotal > 10_000 {
                let ratio = Double(d.videoLost) / Double(vTotal)
                if ratio > 0.0001 {
                    out.append(Hint(id: "loss", severity: ratio > 0.001 ? .warning : .info, certainty: .measured,
                                    title: String(format: "Video-Paketverlust %.2f %%", ratio * 100),
                                    detail: "Möglich: Adapter oder Switch überlastet, Mac ausgelastet oder Empfangspuffer zu klein (\(d.socketBufferBytes / 1024 / 1024) MB, macOS erlaubt höchstens 8 MB)."))
                }
            }
            if d.ptpRequested && !d.ptpActive {
                out.append(Hint(id: "ptp-fallback", severity: .warning, certainty: .measured,
                                title: "Ohne PTP wiedergegeben",
                                detail: "Kein PTP verfügbar. Bild und Ton bleiben über ihre Zeitstempel lippensynchron, nur nicht am Studiotakt."))
            }
            if d.ptpActive && d.ptpGrandmasterMatchesSDP == 0 {
                out.append(Hint(id: "ptp-gm", severity: .warning, certainty: .measured,
                                title: "Anderer Grandmaster als in der SDP",
                                detail: "Der Mac folgt einem anderen Grandmaster als in der SDP angegeben. Vielleicht hat er gewechselt oder die SDP ist alt."))
            }
            if d.latencyRaised {
                out.append(Hint(id: "latency", severity: .info, certainty: .measured,
                                title: "Wiedergabepuffer erhöht",
                                detail: String(format: "Daten kamen spät, der Puffer steht jetzt auf %.0f ms. Bild und Ton bleiben synchron.", d.latencyMs)))
            }
        }
        return out.sorted { $0.severity > $1.severity }
    }
}

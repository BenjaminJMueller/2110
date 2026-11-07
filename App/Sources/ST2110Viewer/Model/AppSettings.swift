import Foundation

/// Benutzereinstellungen (UserDefaults). Technische Parameter erscheinen in der
/// Oberfläche gebündelt unter „Erweitert“.
struct AppSettings: Codable, Equatable {
    enum SyncChoice: Int, Codable, CaseIterable, Identifiable {
        case automatic = 0      // PTP versuchen, sonst RTP-abgestimmt
        case rtpAligned = 1
        case preview = 2
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .automatic: return "Automatisch (PTP, sonst RTP-Zeitstempel)"
            case .rtpAligned: return "Zeitlich abgestimmt über RTP-Zeitstempel (ohne PTP)"
            case .preview: return "Einfache Vorschau (nicht lippensynchron)"
            }
        }
    }

    var interfaceName: String = ""          // leer = automatisch
    var sync: SyncChoice = .automatic
    var ptpDomain: Int = -1                 // -1 = aus SDP (sonst 127)
    var ptpTimeoutSeconds: Int = 4
    var latencyMs: Int = 120
    var autoLatency: Bool = true
    var useSourceFilter: Bool = true
    var socketBufferMB: Int = 0             // 0 = automatisch (so groß wie möglich)

    var audioDeviceUID: String = ""         // leer = Systemausgang
    var volume: Double = 0.8
    var muted: Bool = false
    var audioDelayMs: Int = 0

    // NMOS und Adressbereiche
    var mdnsDiscovery: Bool = true
    var registryURL: String = ""
    var manualNodes: [String] = []
    var scanRanges: String = ""             // z. B. „192.168.10.1-254“
    var scanPorts: String = "80, 8080"
    var multicastRange: String = "239.0.0.0/8"
    var defaultVideoPort: Int = 5004
    var defaultAudioPort: Int = 5004

    var appearance: Int = 0                 // 0 System, 1 Hell, 2 Dunkel
    var onboardingDone: Bool = false
    var allowSenderControl: Bool = false    // IS-05-Schreibzugriffe erst nach Freischaltung

    static let key = "AppSettings.v1"

    static func load() -> AppSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return AppSettings() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    init() {}

    // Tolerant gegenüber neuen/entfernten Feldern
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.defaults
        interfaceName = (try? c.decode(String.self, forKey: .interfaceName)) ?? d.interfaceName
        sync = (try? c.decode(SyncChoice.self, forKey: .sync)) ?? d.sync
        ptpDomain = (try? c.decode(Int.self, forKey: .ptpDomain)) ?? d.ptpDomain
        ptpTimeoutSeconds = (try? c.decode(Int.self, forKey: .ptpTimeoutSeconds)) ?? d.ptpTimeoutSeconds
        latencyMs = (try? c.decode(Int.self, forKey: .latencyMs)) ?? d.latencyMs
        autoLatency = (try? c.decode(Bool.self, forKey: .autoLatency)) ?? d.autoLatency
        useSourceFilter = (try? c.decode(Bool.self, forKey: .useSourceFilter)) ?? d.useSourceFilter
        socketBufferMB = (try? c.decode(Int.self, forKey: .socketBufferMB)) ?? d.socketBufferMB
        audioDeviceUID = (try? c.decode(String.self, forKey: .audioDeviceUID)) ?? d.audioDeviceUID
        volume = (try? c.decode(Double.self, forKey: .volume)) ?? d.volume
        muted = (try? c.decode(Bool.self, forKey: .muted)) ?? d.muted
        audioDelayMs = (try? c.decode(Int.self, forKey: .audioDelayMs)) ?? d.audioDelayMs
        mdnsDiscovery = (try? c.decode(Bool.self, forKey: .mdnsDiscovery)) ?? d.mdnsDiscovery
        registryURL = (try? c.decode(String.self, forKey: .registryURL)) ?? d.registryURL
        manualNodes = (try? c.decode([String].self, forKey: .manualNodes)) ?? d.manualNodes
        scanRanges = (try? c.decode(String.self, forKey: .scanRanges)) ?? d.scanRanges
        scanPorts = (try? c.decode(String.self, forKey: .scanPorts)) ?? d.scanPorts
        multicastRange = (try? c.decode(String.self, forKey: .multicastRange)) ?? d.multicastRange
        defaultVideoPort = (try? c.decode(Int.self, forKey: .defaultVideoPort)) ?? d.defaultVideoPort
        defaultAudioPort = (try? c.decode(Int.self, forKey: .defaultAudioPort)) ?? d.defaultAudioPort
        appearance = (try? c.decode(Int.self, forKey: .appearance)) ?? d.appearance
        onboardingDone = (try? c.decode(Bool.self, forKey: .onboardingDone)) ?? d.onboardingDone
        allowSenderControl = (try? c.decode(Bool.self, forKey: .allowSenderControl)) ?? d.allowSenderControl
    }

    private static let defaults = AppSettings()
}

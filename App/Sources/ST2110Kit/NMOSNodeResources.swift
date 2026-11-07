import Foundation

/// IS-04-Ressourcen, mit denen Essenz sich beim Senden als NMOS-Knoten
/// anbietet (Peer-to-Peer per mDNS bzw. bei einer Registry). Dadurch erscheint
/// der Essenz-Sender in der Quellenliste von NMOS-fähigen Empfängern, z. B. im
/// LCD-Menü eines Blackmagic 2110 IP Converter.
public struct NMOSNodeResources: Sendable {
    public struct Identity: Codable, Hashable, Sendable {
        public var node: String
        public var device: String
        public var videoSource: String
        public var audioSource: String
        public var videoFlow: String
        public var audioFlow: String
        public var videoSender: String
        public var audioSender: String

        public static func make() -> Identity {
            func u() -> String { UUID().uuidString.lowercased() }
            return Identity(node: u(), device: u(), videoSource: u(), audioSource: u(), videoFlow: u(),
                            audioFlow: u(), videoSender: u(), audioSender: u())
        }
    }

    public var ids: Identity
    public var label: String
    public var hostname: String
    public var hostIP: String
    public var port: Int
    public var interfaceName: String
    public var video: Video?
    public var audio: Audio?
    public var active: Bool
    public var version: String

    public struct Video: Sendable {
        public var width: Int, height: Int, fpsNum: Int, fpsDen: Int
        public var destination: String, port: Int
        public init(width: Int, height: Int, fpsNum: Int, fpsDen: Int, destination: String, port: Int) {
            self.width = width; self.height = height; self.fpsNum = fpsNum; self.fpsDen = fpsDen
            self.destination = destination; self.port = port
        }
    }
    public struct Audio: Sendable {
        public var channels: Int
        public var destination: String, port: Int
        public init(channels: Int, destination: String, port: Int) {
            self.channels = channels; self.destination = destination; self.port = port
        }
    }

    public init(ids: Identity, label: String, hostname: String, hostIP: String, port: Int, interfaceName: String,
                video: Video?, audio: Audio?, active: Bool) {
        self.ids = ids; self.label = label; self.hostname = hostname; self.hostIP = hostIP; self.port = port
        self.interfaceName = interfaceName; self.video = video; self.audio = audio; self.active = active
        let now = Date().timeIntervalSince1970
        version = "\(Int(now)):\(Int((now - floor(now)) * 1e9))"
    }

    var base: String { "http://\(hostIP):\(port)" }

    private func common(_ id: String, _ label: String) -> [String: Any] {
        ["id": id, "version": version, "label": label, "description": label, "tags": [String: [String]]()]
    }

    public var node: [String: Any] {
        var n = common(ids.node, label)
        n["href"] = "\(base)/"
        n["hostname"] = hostname
        n["api"] = ["versions": ["v1.3"], "endpoints": [["host": hostIP, "port": port, "protocol": "http"]]]
        n["caps"] = [String: Any]()
        n["services"] = [Any]()
        n["clocks"] = [["name": "clk0", "ref_type": "ptp", "traceable": false, "version": "IEEE1588-2008",
                        "gmid": "00-00-00-00-00-00-00-00", "locked": false]]
        n["interfaces"] = [["name": interfaceName, "chassis_id": NSNull(), "port_id": "00-00-00-00-00-00"]]
        return n
    }

    public var device: [String: Any] {
        var d = common(ids.device, label)
        d["type"] = "urn:x-nmos:device:generic"
        d["node_id"] = ids.node
        d["senders"] = [video != nil ? ids.videoSender : nil, audio != nil ? ids.audioSender : nil].compactMap { $0 }
        d["receivers"] = [String]()
        d["controls"] = [["href": "\(base)/x-nmos/connection/v1.1/", "type": "urn:x-nmos:control:sr-ctrl/v1.1"]]
        return d
    }

    public var sources: [[String: Any]] {
        var out: [[String: Any]] = []
        if video != nil {
            var s = common(ids.videoSource, "\(label) Video")
            s["format"] = "urn:x-nmos:format:video"
            s["caps"] = [String: Any](); s["device_id"] = ids.device; s["parents"] = [String](); s["clock_name"] = "clk0"
            s["grain_rate"] = ["numerator": video!.fpsNum, "denominator": video!.fpsDen]
            out.append(s)
        }
        if let a = audio {
            var s = common(ids.audioSource, "\(label) Audio")
            s["format"] = "urn:x-nmos:format:audio"
            s["caps"] = [String: Any](); s["device_id"] = ids.device; s["parents"] = [String](); s["clock_name"] = "clk0"
            s["channels"] = (0..<a.channels).map { ["label": "Kanal \($0 + 1)"] }
            out.append(s)
        }
        return out
    }

    public var flows: [[String: Any]] {
        var out: [[String: Any]] = []
        if let v = video {
            var f = common(ids.videoFlow, "\(label) Video")
            f["format"] = "urn:x-nmos:format:video"; f["media_type"] = "video/raw"
            f["source_id"] = ids.videoSource; f["device_id"] = ids.device; f["parents"] = [String]()
            f["grain_rate"] = ["numerator": v.fpsNum, "denominator": v.fpsDen]
            f["frame_width"] = v.width; f["frame_height"] = v.height; f["interlace_mode"] = "progressive"
            f["colorspace"] = "BT709"; f["transfer_characteristic"] = "SDR"
            f["components"] = [["name": "Y", "width": v.width, "height": v.height, "bit_depth": 10],
                               ["name": "Cb", "width": v.width / 2, "height": v.height, "bit_depth": 10],
                               ["name": "Cr", "width": v.width / 2, "height": v.height, "bit_depth": 10]]
            out.append(f)
        }
        if audio != nil {
            var f = common(ids.audioFlow, "\(label) Audio")
            f["format"] = "urn:x-nmos:format:audio"; f["media_type"] = "audio/L24"
            f["source_id"] = ids.audioSource; f["device_id"] = ids.device; f["parents"] = [String]()
            f["sample_rate"] = ["numerator": 48000, "denominator": 1]; f["bit_depth"] = 24
            out.append(f)
        }
        return out
    }

    public var senders: [[String: Any]] {
        var out: [[String: Any]] = []
        let groupTag = ["urn:x-nmos:tag:grouphint/v1.0": ["\(label):Video"]]
        if video != nil {
            var s = common(ids.videoSender, "\(label) Video")
            s["flow_id"] = ids.videoFlow; s["transport"] = "urn:x-nmos:transport:rtp.mcast"; s["device_id"] = ids.device
            s["manifest_href"] = "\(base)/sdp/video.sdp"; s["interface_bindings"] = [interfaceName]
            s["subscription"] = ["receiver_id": NSNull(), "active": active]; s["tags"] = groupTag
            out.append(s)
        }
        if audio != nil {
            var s = common(ids.audioSender, "\(label) Audio")
            s["flow_id"] = ids.audioFlow; s["transport"] = "urn:x-nmos:transport:rtp.mcast"; s["device_id"] = ids.device
            s["manifest_href"] = "\(base)/sdp/audio.sdp"; s["interface_bindings"] = [interfaceName]
            s["subscription"] = ["receiver_id": NSNull(), "active": active]
            s["tags"] = ["urn:x-nmos:tag:grouphint/v1.0": ["\(label):Audio 1"]]
            out.append(s)
        }
        return out
    }

    /// IS-05 aktive Parameter eines Senders
    public func transportParams(video isVideo: Bool) -> [String: Any] {
        let dst = isVideo ? video?.destination : audio?.destination
        let port = isVideo ? video?.port : audio?.port
        return ["master_enable": active, "receiver_id": NSNull(),
                "activation": ["mode": NSNull(), "requested_time": NSNull(), "activation_time": NSNull()],
                "transport_params": [["source_ip": hostIP, "destination_ip": dst ?? "", "source_port": port ?? 5004,
                                      "destination_port": port ?? 5004, "rtp_enabled": active]]]
    }

    public static func json(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

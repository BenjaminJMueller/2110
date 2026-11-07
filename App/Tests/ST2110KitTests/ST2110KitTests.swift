import XCTest
@testable import ST2110Kit

/// Synthetische NMOS-Antworten (nach AMWA IS-04 v1.3 aufgebaut, NICHT von
/// echter Blackmagic-Hardware mitgeschnitten).
struct FixtureFetcher: HTTPFetching {
    let files: [String: String]   // Pfadende -> Dateiname
    func get(_ url: URL) async throws -> (Data, Int) {
        for (suffix, file) in files where url.absoluteString.hasSuffix(suffix) {
            let u = Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Fixtures")!
            return (try Data(contentsOf: u), 200)
        }
        if url.absoluteString.hasSuffix("/x-nmos/node/") { return (Data("[\"v1.2/\",\"v1.3/\"]".utf8), 200) }
        return (Data(), 404)
    }
    func send(_ url: URL, method: String, body: Data) async throws -> (Data, Int) { (Data("{}".utf8), 200) }
}

final class ST2110KitTests: XCTestCase {
    let fetcher = FixtureFetcher(files: [
        "v1.3/self": "node_self.json", "v1.3/devices": "devices.json", "v1.3/flows": "flows.json",
        "v1.3/senders": "senders.json", "v1.sdp": "v1.sdp",
    ])

    func testResolveAndInventoryAndGrouping() async throws {
        let client = NMOSClient(http: fetcher)
        let base = try await client.resolveBase("192.168.10.21")
        XCTAssertEqual(base.absoluteString, "http://192.168.10.21/x-nmos/node/v1.3/")
        let inv = try await client.inventory(base: base, isRegistry: false)
        XCTAssertEqual(inv.senders.count, 5)
        let groups = SourceGrouping.group(inv)
        // Kamera 1 (Grouphint) + SDI 2 (Nummer im Label); ANC wird ignoriert
        XCTAssertEqual(groups.count, 2)
        let cam1 = try XCTUnwrap(groups.first { $0.title == "Kamera 1" })
        XCTAssertEqual(cam1.video?.id, "snd-v1")
        XCTAssertEqual(cam1.audio.map(\.id), ["snd-a1"])
        XCTAssertTrue(cam1.pairingCertain)
        XCTAssertEqual(cam1.formatSummary, "1920×1080p25, 10 Bit")
        XCTAssertEqual(cam1.connectionAPI?.absoluteString, "http://192.168.10.21/x-nmos/connection/v1.1/")
        let sdi2 = try XCTUnwrap(groups.first { $0.video?.id == "snd-v2" })
        XCTAssertEqual(sdi2.audio.map(\.id), ["snd-a2"])
        XCTAssertFalse(sdi2.pairingCertain)
        XCTAssertTrue(sdi2.videoFlow?.isInterlaced ?? false)
        let sdp = try await client.sdp(for: cam1.video!, connectionAPI: nil)
        XCTAssertTrue(sdp.contains("m=video"))
        do {
            _ = try await client.sdp(for: sdi2.video!, connectionAPI: nil)
            XCTFail("SDP ohne manifest_href darf nicht gelingen")
        } catch {}
    }

    func testAddressRanges() {
        XCTAssertEqual(AddressRange.parse("192.168.10.1-254")?.count, 254)
        XCTAssertEqual(AddressRange.parse("10.0.0.0/24")?.count, 256)
        XCTAssertEqual(AddressRange.parse("239.1.1.1")?.count, 1)
        XCTAssertNil(AddressRange.parse("300.1.1.1"))
        let list = AddressRange.parseList("239.0.0.0/8, 192.168.1.10-192.168.1.20")!
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[0].contains(IPv4("239.21.1.1")!))
        XCTAssertFalse(list[0].contains(IPv4("238.1.1.1")!))
        XCTAssertTrue(IPv4("239.1.2.3")!.isMulticast)
        XCTAssertEqual(PortList.parse("80, 8080"), [80, 8080])
        XCTAssertNil(PortList.parse("80, 99999"))
    }

    func testSDPSplitting() {
        let combined = """
        v=0\r\no=- 1 1 IN IP4 10.0.0.1\r\ns=Kombi\r\nt=0 0\r\na=group:DUP a b\r\n\
        m=video 5004 RTP/AVP 96\r\nc=IN IP4 239.1.1.1/64\r\na=rtpmap:96 raw/90000\r\n\
        m=audio 5004 RTP/AVP 97\r\nc=IN IP4 239.1.1.2/64\r\na=rtpmap:97 L24/48000/8\r\n\
        m=video 5004 RTP/AVP 100\r\nc=IN IP4 239.1.1.3/64\r\na=rtpmap:100 smpte291/90000\r\n
        """
        let s = SDPText.sections(combined)
        XCTAssertEqual(s.map(\.kind), [.video, .audio, .other])
        XCTAssertTrue(s[1].text.hasPrefix("v=0"))
        XCTAssertTrue(s[1].text.contains("L24/48000/8"))
        XCTAssertFalse(s[1].text.contains("m=video"))
        XCTAssertFalse(s[0].text.contains("a=group"))
    }

    func testInterfaceChoiceAndDiagnosis() {
        let wifi = InterfaceSnapshot(name: "en0", displayName: "WLAN", ipv4: "192.168.178.20", netmask: "255.255.255.0", isUp: true, isWireless: true, linkSpeedBps: 1_000_000_000)
        let tb = InterfaceSnapshot(name: "en7", displayName: "Thunderbolt Ethernet", ipv4: "192.168.10.50", netmask: "255.255.255.0", isUp: true, isWireless: false, linkSpeedBps: 10_000_000_000)
        let usb = InterfaceSnapshot(name: "en5", displayName: "USB LAN", ipv4: "10.1.1.2", netmask: "255.255.0.0", isUp: true, isWireless: false, linkSpeedBps: 1_000_000_000)
        XCTAssertEqual(InterfaceChoice.preferred([wifi, usb, tb], senderAddresses: ["10.1.5.5"])?.name, "en5")
        XCTAssertEqual(InterfaceChoice.preferred([wifi, usb, tb], senderAddresses: [])?.name, "en7")
        var d = DiagnosisInput(state: .waiting)
        d.secondsInState = 5
        d.expectsVideo = true
        d.interface = wifi
        d.otherInterfaces = [wifi, tb]
        d.senderAddress = "192.168.10.21"
        let h = Diagnosis.hints(d)
        XCTAssertTrue(h.contains { $0.id == "no-packets" && $0.certainty == .measured })
        let subnet = h.first { $0.id == "if-subnet" }
        XCTAssertEqual(subnet?.certainty, .suspected)
        XCTAssertTrue(subnet?.detail.contains("Thunderbolt Ethernet") ?? false)
        XCTAssertTrue(h.contains { $0.id == "if-wifi" })
        XCTAssertTrue(h.contains { $0.id == "mc-causes" && $0.certainty == .suspected })
    }
}

final class NodeResourceTests: XCTestCase {
    func testNodeResourcesAreConsistent() throws {
        let ids = NMOSNodeResources.Identity.make()
        let r = NMOSNodeResources(ids: ids, label: "2110 Viewer", hostname: "mac.local", hostIP: "192.168.10.50", port: 8123,
                                  interfaceName: "en7",
                                  video: .init(width: 1920, height: 1080, fpsNum: 25, fpsDen: 1, destination: "239.50.0.1", port: 5004),
                                  audio: .init(channels: 2, destination: "239.50.0.2", port: 5004), active: true)
        // Die eigenen Ressourcen müssen sich mit dem eigenen IS-04-Client lesen lassen
        let node = try JSONDecoder().decode(NMOSNode.self, from: NMOSNodeResources.json(r.node))
        XCTAssertEqual(node.api?.endpoints?.first?.port, 8123)
        let dev = try JSONDecoder().decode(NMOSDevice.self, from: NMOSNodeResources.json(r.device))
        XCTAssertEqual(dev.connectionAPI?.absoluteString, "http://192.168.10.50:8123/x-nmos/connection/v1.1/")
        let flows = try JSONDecoder().decode([NMOSFlow].self, from: NMOSNodeResources.json(r.flows))
        let senders = try JSONDecoder().decode([NMOSSender].self, from: NMOSNodeResources.json(r.senders))
        var inv = NMOSInventory(baseURL: URL(string: "http://192.168.10.50:8123/x-nmos/node/v1.3/")!, isRegistry: false)
        inv.nodes = [node]; inv.devices = [dev]; inv.flows = flows; inv.senders = senders
        let groups = SourceGrouping.group(inv)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.formatSummary, "1920×1080p25, 10 Bit")
        XCTAssertTrue(groups.first?.pairingCertain ?? false)
        XCTAssertEqual(groups.first?.audio.count, 1)
    }

    func testDestinationsGrouping() throws {
        let recs = """
        [{"id":"r1","label":"SDI Out 1 Video","format":"urn:x-nmos:format:video","transport":"urn:x-nmos:transport:rtp.mcast","device_id":"d"},
         {"id":"r2","label":"SDI Out 1 Audio","format":"urn:x-nmos:format:audio","transport":"urn:x-nmos:transport:rtp.mcast","device_id":"d","subscription":{"sender_id":"s9","active":true}},
         {"id":"r3","label":"SDI Out 2 Video","format":"urn:x-nmos:format:video","transport":"urn:x-nmos:transport:rtp.mcast","device_id":"d"}]
        """
        var inv = NMOSInventory(baseURL: URL(string: "http://x/x-nmos/node/v1.3/")!, isRegistry: false)
        inv.receivers = try JSONDecoder().decode([NMOSReceiver].self, from: Data(recs.utf8))
        let d = SourceGrouping.destinations(inv)
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d.first?.title, "SDI Out 1")
        XCTAssertEqual(d.first?.audio.first?.id, "r2")
        XCTAssertEqual(d.first?.connectedSenderIDs, ["s9"])
    }
}

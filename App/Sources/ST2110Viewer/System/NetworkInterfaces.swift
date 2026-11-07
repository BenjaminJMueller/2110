import Darwin
import Foundation
import Network
import ST2110Kit
import SystemConfiguration

/// Netzwerkschnittstellen mit verständlichen Namen („Thunderbolt Ethernet“
/// statt „en7“), IPv4-Adresse, Netzmaske und Verbindungsgeschwindigkeit.
@Observable
final class NetworkInterfaceList {
    private(set) var interfaces: [InterfaceSnapshot] = []
    private(set) var changeCounter = 0
    private let monitor = NWPathMonitor()

    init() {
        refresh()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
        monitor.start(queue: DispatchQueue(label: "netmon"))
    }

    func refresh() {
        let new = Self.snapshot()
        if new != interfaces {
            interfaces = new
            changeCounter += 1
        }
    }

    func interface(named name: String) -> InterfaceSnapshot? {
        interfaces.first { $0.name == name }
    }

    static func snapshot() -> [InterfaceSnapshot] {
        var names: [String: (String, Bool)] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
                let display = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? ?? bsd
                let type = SCNetworkInterfaceGetInterfaceType(i) as String? ?? ""
                names[bsd] = (display, type == (kSCNetworkInterfaceTypeIEEE80211 as String))
            }
        }
        var ipv4: [String: (String, String)] = [:]
        var flagsUp: [String: Bool] = [:]
        var speed: [String: UInt64] = [:]
        var order: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            let name = String(cString: ifa.ifa_name)
            if !order.contains(name) { order.append(name) }
            let flags = Int32(ifa.ifa_flags)
            flagsUp[name] = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            if let addr = ifa.ifa_addr {
                if addr.pointee.sa_family == UInt8(AF_INET), ipv4[name] == nil {
                    ipv4[name] = (ipString(addr), ifa.ifa_netmask.map(ipString) ?? "255.255.255.0")
                } else if addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    speed[name] = UInt64(d.ifi_baudrate)
                }
            }
            p = ifa.ifa_next
        }
        return order.compactMap { n in
            guard n != "lo0", !n.hasPrefix("gif"), !n.hasPrefix("stf"), !n.hasPrefix("anpi"),
                  !n.hasPrefix("ap"), !n.hasPrefix("awdl"), !n.hasPrefix("llw"), !n.hasPrefix("utun") else { return nil }
            let info = names[n]
            // Nur Schnittstellen, die macOS als Netzwerkdienst kennt, oder mit IPv4
            guard info != nil || ipv4[n] != nil else { return nil }
            return InterfaceSnapshot(name: n, displayName: info?.0 ?? n, ipv4: ipv4[n]?.0, netmask: ipv4[n]?.1,
                                     isUp: flagsUp[n] ?? false, isWireless: info?.1 ?? false,
                                     linkSpeedBps: speed[n] ?? 0)
        }
    }

    private static func ipString(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var a = sin.pointee.sin_addr
            inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        }
        return String(cString: buf)
    }
}

extension InterfaceSnapshot {
    /// z. B. „Thunderbolt Ethernet (en7) – 192.168.10.50 – 10 Gbit/s“
    var menuTitle: String {
        var parts = ["\(displayName) (\(name))"]
        parts.append(ipv4 ?? "keine IPv4-Adresse")
        if let s = speedText { parts.append(s) }
        if !isUp { parts.append("nicht verbunden") }
        return parts.joined(separator: " – ")
    }
}

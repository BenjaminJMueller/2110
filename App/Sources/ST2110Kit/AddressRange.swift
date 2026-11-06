import Foundation

/// IPv4-Hilfen für einstellbare Adressen und Adressbereiche.
public struct IPv4: Hashable, Comparable, CustomStringConvertible, Sendable {
    public var value: UInt32

    public init(_ v: UInt32) { value = v }

    public init?(_ s: String) {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let b = UInt8(p) else { return nil }
            v = v << 8 | UInt32(b)
        }
        value = v
    }

    public var description: String {
        "\(value >> 24 & 0xff).\(value >> 16 & 0xff).\(value >> 8 & 0xff).\(value & 0xff)"
    }
    public var isMulticast: Bool { value >> 28 == 0xE }
    public var isLinkLocal: Bool { value >> 16 == 0xA9FE }
    public static func < (a: IPv4, b: IPv4) -> Bool { a.value < b.value }

    public func inSubnet(of other: IPv4, mask: IPv4) -> Bool {
        (value & mask.value) == (other.value & mask.value)
    }
}

/// Bereich wie „192.168.10.1-192.168.10.254“, „192.168.10.1-254“, „239.20.0.0/16“
/// oder eine Einzeladresse. Mehrere Bereiche durch Komma getrennt.
public struct AddressRange: Hashable, Sendable, CustomStringConvertible {
    public var first: IPv4
    public var last: IPv4

    public init(first: IPv4, last: IPv4) {
        self.first = min(first, last)
        self.last = max(first, last)
    }

    public static func parse(_ text: String) -> AddressRange? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let slash = t.firstIndex(of: "/") {
            guard let base = IPv4(String(t[..<slash])), let bits = Int(t[t.index(after: slash)...]),
                  (0...32).contains(bits) else { return nil }
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - UInt32(bits))
            return AddressRange(first: IPv4(base.value & mask), last: IPv4(base.value & mask | ~mask))
        }
        if let dash = t.firstIndex(of: "-") {
            let a = String(t[..<dash]).trimmingCharacters(in: .whitespaces)
            let b = String(t[t.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
            guard let start = IPv4(a) else { return nil }
            if let end = IPv4(b) { return AddressRange(first: start, last: end) }
            if let lastOctet = UInt8(b) {
                return AddressRange(first: start, last: IPv4(start.value & 0xFFFFFF00 | UInt32(lastOctet)))
            }
            return nil
        }
        guard let single = IPv4(t) else { return nil }
        return AddressRange(first: single, last: single)
    }

    public static func parseList(_ text: String) -> [AddressRange]? {
        let items = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var out: [AddressRange] = []
        for i in items {
            guard let r = parse(i) else { return nil }
            out.append(r)
        }
        return out
    }

    public var count: Int { Int(last.value - first.value) + 1 }
    public func contains(_ ip: IPv4) -> Bool { ip >= first && ip <= last }
    public var addresses: [IPv4] {
        guard count <= 65536 else { return [] }
        return (first.value...last.value).map(IPv4.init)
    }
    public var description: String { first == last ? first.description : "\(first)–\(last)" }
}

public enum PortList {
    public static func parse(_ text: String) -> [Int]? {
        let items = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
        var out: [Int] = []
        for i in items {
            guard let p = Int(i), (1...65535).contains(p) else { return nil }
            out.append(p)
        }
        return out.isEmpty ? nil : out
    }
}

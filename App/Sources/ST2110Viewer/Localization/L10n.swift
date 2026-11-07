import Foundation

/// Übersetzung der Oberfläche. Ausgangssprache ist Deutsch; die englische
/// Tabelle (App/Localization/en.json) liegt im App-Paket als
/// Resources/Translations-en.json. Feste Texte in SwiftUI übersetzt macOS über
/// en.lproj/Localizable.strings selbst; `tr` deckt alles ab, was erst zur
/// Laufzeit zusammengesetzt wird (Meldungen mit Werten, Texte aus dem C-Kern).
enum L10n {
    /// Englisch, sobald macOS die App nicht auf Deutsch zeigt.
    static let isEnglish: Bool = {
        guard let first = Bundle.main.preferredLocalizations.first else { return false }
        return !first.hasPrefix("de")
    }()

    fileprivate struct Template {
        let regex: NSRegularExpression
        let english: String
    }

    fileprivate static let table: [String: String] = {
        guard isEnglish,
              let url = Bundle.main.url(forResource: "Translations-en", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }()

    /// Einträge mit Platzhaltern (%@), längste zuerst, damit die genaueste Vorlage gewinnt.
    fileprivate static let templates: [Template] = {
        table.filter { $0.key.contains("%@") }
            .sorted { $0.key.count > $1.key.count }
            .compactMap { key, value in
                let parts = key.components(separatedBy: "%@").map(NSRegularExpression.escapedPattern(for:))
                let pattern = "^" + parts.joined(separator: "(.+?)") + "$"
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
                return Template(regex: re, english: value)
            }
    }()

    fileprivate static let lock = NSLock()
    fileprivate static var cache: [String: String] = [:]

    static func translate(_ s: String) -> String {
        guard isEnglish, !s.isEmpty else { return s }
        lock.lock()
        if let c = cache[s] { lock.unlock(); return c }
        lock.unlock()
        let result = lookup(s)
        lock.lock()
        if cache.count > 4000 { cache.removeAll() }
        cache[s] = result
        lock.unlock()
        return result
    }

    private static func lookup(_ s: String) -> String {
        if let t = table[s] { return t }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        for t in templates {
            guard let m = t.regex.firstMatch(in: s, range: range) else { continue }
            var values: [String] = []
            for i in 1..<m.numberOfRanges {
                // eingesetzte Werte ggf. ebenfalls übersetzen (z. B. „Kanal 3“ in einer Meldung)
                values.append(translate(ns.substring(with: m.range(at: i))))
            }
            return fill(t.english, values)
        }
        // Mehrzeilige Texte zeilenweise versuchen
        if s.contains("\n") {
            let lines = s.components(separatedBy: "\n")
            let out = lines.map { translate($0) }
            if out != lines { return out.joined(separator: "\n") }
        }
        return s
    }

    /// Setzt Werte in %@ bzw. %1$@ ein.
    private static func fill(_ format: String, _ values: [String]) -> String {
        var out = ""
        var next = 0
        var i = format.startIndex
        while i < format.endIndex {
            let c = format[i]
            if c == "%" {
                let rest = format[i...]
                if rest.hasPrefix("%@") {
                    out += next < values.count ? values[next] : ""
                    next += 1
                    i = format.index(i, offsetBy: 2)
                    continue
                }
                // %n$@
                let digits = rest.dropFirst().prefix { $0.isNumber }
                if !digits.isEmpty, rest.dropFirst(1 + digits.count).hasPrefix("$@"), let n = Int(digits) {
                    out += n - 1 < values.count ? values[n - 1] : ""
                    i = format.index(i, offsetBy: 3 + digits.count)
                    continue
                }
            }
            out.append(c)
            i = format.index(after: i)
        }
        return out
    }
}

/// Übersetzt einen zur Laufzeit zusammengesetzten Text (Deutsch → Englisch).
@inline(__always)
func tr(_ s: String) -> String { L10n.translate(s) }

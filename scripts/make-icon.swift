// Zeichnet das App-Symbol (1024×1024 PNG). Aufruf: swift scripts/make-icon.swift ausgabe.png
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 100, dy: 100)
let path = NSBezierPath(roundedRect: rect, xRadius: 180, yRadius: 180)
NSGradient(colors: [NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.22, alpha: 1),
                    NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.55, alpha: 1)])!.draw(in: path, angle: 90)
// Farbbalken (Testbild)
let bars: [NSColor] = [.white, .yellow, .cyan, .green, .magenta, .red, .blue]
let barW = (rect.width - 120) / CGFloat(bars.count)
for (i, c) in bars.enumerated() {
    c.withAlphaComponent(0.9).setFill()
    NSRect(x: rect.minX + 60 + CGFloat(i) * barW, y: rect.midY + 20, width: barW - 6, height: 240).fill()
}
// Schrift
let style = NSMutableParagraphStyle()
style.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 230, weight: .heavy),
    .foregroundColor: NSColor.white,
    .paragraphStyle: style,
]
NSString(string: "2110").draw(in: NSRect(x: rect.minX, y: rect.minY + 90, width: rect.width, height: 290), withAttributes: attrs)
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

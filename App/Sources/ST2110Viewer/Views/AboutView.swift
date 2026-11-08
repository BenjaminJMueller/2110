import AppKit
import SwiftUI

/// „Über 2110 Viewer“: Herkunft, Version, Links.
struct AboutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 2) {
                Text("2110 Viewer").font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(tr("Version \(model.appVersion)")).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            VStack(spacing: 8) {
                Text("Entwickelt von Prof. Dr. Benjamin Müller für die Lehre an der Hochschule Ansbach.")
                Text("Die App ist Open Source und wird weiterentwickelt. Rückmeldungen und Fehlerberichte sind auf GitHub willkommen.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                link("Projektseite", tr("https://benjaminjmueller.github.io/2110/"))
                link("GitHub", "https://github.com/BenjaminJMueller/2110")
                link("Hochschule Ansbach", "https://www.hs-ansbach.de")
            }
            .controlButtonStyle()

            if model.updates.available {
                Button("Nach Updates suchen …") { model.updates.checkNow() }
                    .controlButtonStyle(prominent: true)
            }

            Text("Kein offizielles Produkt der Hochschule Ansbach. Nicht verbunden mit Blackmagic Design.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(width: 440)
    }

    private func link(_ title: String, _ url: String) -> some View {
        Button(tr(title)) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
            .help(url)
    }
}

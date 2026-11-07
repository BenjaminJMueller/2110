import SwiftUI

/// Einführung beim ersten Start: Ablauf und Berechtigungen verständlich erklärt.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Willkommen beim Essenz").font(.largeTitle.weight(.semibold))
            Text("Bild und Ton von Blackmagic-ST-2110-Geräten direkt über Ethernet ansehen und abhören.")
                .font(.title3).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                step(1, "cable.connector", "Mac mit dem ST-2110-Netz verbinden",
                     "Am besten über einen 10-GbE-Adapter (z. B. Thunderbolt) am Switch des Medienlabors – oder direkt am Ethernet-Anschluss des Blackmagic 2110 IP Converter 3x3G.")
                step(2, "list.bullet.rectangle", "Quelle auswählen",
                     "Blackmagic-Geräte erscheinen links automatisch unter „Im Netzwerk gefunden“. Alternativ SDP-Dateien in das Fenster ziehen.")
                step(3, "play.tv", "Bild sehen und Ton hören",
                     "Mit der Leertaste starten und stoppen. Abhörkanäle, Lautstärke und Ausgabegerät unten in der Leiste.")
            }

            GroupBox("Was macOS Sie fragen kann") {
                VStack(alignment: .leading, spacing: 8) {
                    permission("network", "Zugriff auf Geräte im lokalen Netzwerk",
                               "Nötig, um Blackmagic-Geräte zu finden und ihre Video- und Audioströme zu empfangen. Bitte „Erlauben“ wählen. Nachträglich: Systemeinstellungen › Datenschutz & Sicherheit › Lokales Netzwerk.")
                    permission("shield.lefthalf.filled", "Eingehende Verbindungen (nur bei aktiver Firewall)",
                               "Die Ströme kommen als eingehende Netzwerkdaten an. Bitte „Erlauben“ wählen. Dazu gehört auch das Hilfsprogramm „gst-ptp-helper“ für die PTP-Zeit.")
                    permission("hand.raised", "Keine weiteren Rechte",
                               "Die App braucht weder Mikrofon noch Kamera noch Administratorrechte und installiert keine Dienste.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Zum Ausprobieren ohne Netzwerk: „Demo: Testbild und Testton“ in der Seitenleiste.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Los geht’s") {
                    model.settings.onboardingDone = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlButtonStyle(prominent: true)
            }
        }
        .padding(28)
        .frame(width: 680)
    }

    private func step(_ n: Int, _ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 32).foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(n). \(title)").font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func permission(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

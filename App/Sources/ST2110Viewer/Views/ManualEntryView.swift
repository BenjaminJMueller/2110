import ST2110Core
import ST2110Kit
import SwiftUI

/// Experteneingabe der Streamparameter. Erzeugt daraus SDPs nach ST 2110-20/-30,
/// die anschließend wie jede andere Quelle geprüft und gespeichert werden.
struct ManualEntryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Manuelle Quelle"
    @State private var useVideo = true
    @State private var vAddr = "239.0.0.1"
    @State private var vPort = "5004"
    @State private var vSource = ""
    @State private var resolution = "1920x1080"
    @State private var fps = "25"
    @State private var depth = 10
    @State private var vPT = "96"
    @State private var colorimetry = "BT709"

    @State private var useAudio = true
    @State private var aAddr = "239.0.0.2"
    @State private var aPort = "5004"
    @State private var aSource = ""
    @State private var channels = 16
    @State private var ptime = 0.125
    @State private var bits = 24
    @State private var aPT = "97"

    @State private var usePTP = true
    @State private var gmid = ""
    @State private var domain = "127"
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manuelle Eingabe (Experte)").font(.title2.weight(.semibold))
            InfoRow("Nur nötig ohne NMOS und SDP-Datei.", info: "Nur nötig, wenn weder NMOS noch SDP-Dateien zur Verfügung stehen. Die Werte stehen in der Blackmagic-Software „Converters Setup“ (Registerkarte 2110) bzw. im LCD-Menü des Geräts.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack(alignment: .top, spacing: 20) {
                Form {
                    Toggle("Video empfangen", isOn: $useVideo)
                    Group {
                        TextField("Multicast-Adresse", text: $vAddr)
                        TextField("Port", text: $vPort)
                        TextField("Sender-IP (optional, für SSM)", text: $vSource)
                        Picker("Auflösung", selection: $resolution) {
                            Text("1920 × 1080").tag("1920x1080")
                            Text("1280 × 720").tag("1280x720")
                        }
                        Picker("Bildrate (progressiv)", selection: $fps) {
                            ForEach(["23.98", "24", "25", "29.97", "30", "50", "59.94", "60"], id: \.self) { Text(tr($0)).tag($0) }
                        }
                        Picker("Bittiefe (YCbCr 4:2:2)", selection: $depth) {
                            Text("10 Bit").tag(10)
                            Text("8 Bit").tag(8)
                        }
                        Picker("Farbraum", selection: $colorimetry) {
                            Text("BT.709").tag("BT709")
                            Text("BT.601").tag("BT601")
                        }
                        TextField("Payload-Typ", text: $vPT)
                    }
                    .disabled(!useVideo)
                }
                Form {
                    Toggle("Audio empfangen", isOn: $useAudio)
                    Group {
                        TextField("Multicast-Adresse", text: $aAddr)
                        TextField("Port", text: $aPort)
                        TextField("Sender-IP (optional, für SSM)", text: $aSource)
                        Stepper(tr("Kanäle: \(channels)"), value: $channels, in: 1...64)
                        Picker("Paketzeit", selection: $ptime) {
                            Text("1 ms").tag(1.0)
                            Text("0,125 ms").tag(0.125)
                        }
                        Picker("Format", selection: $bits) {
                            Text("L24 (24 Bit)").tag(24)
                            Text("L16 (16 Bit)").tag(16)
                        }
                        TextField("Payload-Typ", text: $aPT)
                    }
                    .disabled(!useAudio)
                    Divider()
                    Toggle("PTP-Zeitbezug angeben", isOn: $usePTP)
                    TextField("Grandmaster-ID (optional)", text: $gmid).disabled(!usePTP)
                    TextField("PTP-Domain", text: $domain).disabled(!usePTP)
                }
            }
            if let problem {
                Label(tr(problem), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Prüfen und übernehmen") { build() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 820)
    }

    private func build() {
        let ranges = AddressRange.parseList(model.settings.multicastRange) ?? []
        func checkAddr(_ s: String, _ label: String) -> Bool {
            guard let ip = IPv4(s) else { problem = "\(label): „\(s)“ ist keine gültige IPv4-Adresse."; return false }
            if ip.isMulticast, !ranges.isEmpty, !ranges.contains(where: { $0.contains(ip) }) {
                problem = "\(label): \(s) liegt außerhalb des eingestellten Multicast-Bereichs (\(model.settings.multicastRange)). Bereich unter „Erweitert“ anpassen, falls gewollt."
                return false
            }
            return true
        }
        var src = SavedSource(name: name, origin: .manual)
        if useVideo {
            guard checkAddr(vAddr, "Video"), let port = Int(vPort), (1...65535).contains(port) else {
                if problem == nil { problem = "Video: ungültiger Port." }
                return
            }
            var m = st_sdp_media()
            m.kind = ST_MEDIA_VIDEO
            m.port = Int32(port)
            m.payload_type = Int32(vPT) ?? 96
            m.clock_rate = 90000
            let wh = resolution.split(separator: "x").compactMap { Int32($0) }
            m.width = wh.first ?? 1920
            m.height = wh.last ?? 1080
            m.depth = Int32(depth)
            switch fps {
            case "23.98": m.fps_num = 24000; m.fps_den = 1001
            case "29.97": m.fps_num = 30000; m.fps_den = 1001
            case "59.94": m.fps_num = 60000; m.fps_den = 1001
            default: m.fps_num = Int32(fps) ?? 25; m.fps_den = 1
            }
            setCString(&m.encoding, "raw")
            setCString(&m.sampling, "YCbCr-4:2:2")
            setCString(&m.colorimetry, colorimetry)
            setCString(&m.dest_addr, vAddr)
            setCString(&m.source_addr, vSource)
            setCString(&m.session_name, name)
            applyClock(&m)
            src.videoSDP = SDPMedia.write(m)
        }
        if useAudio {
            guard checkAddr(aAddr, "Audio"), let port = Int(aPort), (1...65535).contains(port) else {
                if problem == nil { problem = "Audio: ungültiger Port." }
                return
            }
            var m = st_sdp_media()
            m.kind = ST_MEDIA_AUDIO
            m.port = Int32(port)
            m.payload_type = Int32(aPT) ?? 97
            m.clock_rate = 48000
            m.channels = Int32(channels)
            m.ptime_ms = ptime
            setCString(&m.encoding, bits == 16 ? "L16" : "L24")
            setCString(&m.dest_addr, aAddr)
            setCString(&m.source_addr, aSource)
            setCString(&m.session_name, name)
            applyClock(&m)
            src.audioSDP = SDPMedia.write(m)
        }
        guard src.videoSDP != nil || src.audioSDP != nil else {
            problem = "Bitte Video und/oder Audio aktivieren."
            return
        }
        dismiss()
        model.editor = EditorRequest(source: src, isNew: true)
    }

    private func applyClock(_ m: inout st_sdp_media) {
        m.ptp_domain = Int32(domain) ?? 127
        m.has_ptp_refclk = usePTP ? 1 : 0
        setCString(&m.ptp_gmid, gmid.trimmingCharacters(in: .whitespaces))
    }
}

/// NMOS-Gerät oder Registry per Adresse hinzufügen (falls mDNS nicht funktioniert).
struct AddNodeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var registry = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NMOS-Gerät hinzufügen").font(.title2.weight(.semibold))
            InfoRow("IP-Adresse des Geräts, z. B. 192.168.10.21", info: "Die Adresse steht im LCD-Menü unter „Setup › Netzwerk“. Optional mit Port oder vollständiger URL.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Adresse", text: $address).textFieldStyle(.roundedBorder)
                .onSubmit { Task { await add() } }
            Toggle("Adresse ist eine NMOS-Registry (Query API)", isOn: $registry)
            if let message { Text(tr(message)).font(.callout).foregroundStyle(.secondary) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Hinzufügen") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func add() async {
        busy = true
        defer { busy = false }
        if let err = await model.discovery.probe(address, registry: registry) {
            message = err + " Prüfen Sie Adresse, Netzwerkschnittstelle und ob das Gerät eingeschaltet ist."
        } else {
            if registry {
                model.settings.registryURL = address
            } else if !model.settings.manualNodes.contains(address) {
                model.settings.manualNodes.append(address)
            }
            dismiss()
        }
    }
}

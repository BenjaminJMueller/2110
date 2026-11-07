import AppKit
import ST2110Kit
import SwiftUI
import UniformTypeIdentifiers

/// Quelle anlegen/bearbeiten: getrennte Felder für Video- und Audio-SDP
/// (Drag-and-drop, Datei, Einfügen, Texteingabe). Eine kombinierte SDP wird
/// automatisch auf beide Felder verteilt.
struct SourceEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var request: EditorRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.isNew ? "Neue Quelle" : "Quelle bearbeiten").font(.title2.weight(.semibold))
            TextField("Name", text: $request.source.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Name der Quelle")
            HStack(alignment: .top, spacing: 14) {
                SDPSlot(title: "Video-SDP", kind: .video, text: binding(\.videoSDP), onCombined: distribute)
                SDPSlot(title: "Audio-SDP", kind: .audio, text: binding(\.audioSDP), onCombined: distribute)
            }
            if audioCount > 1 {
                Picker("Audiostrom", selection: Binding(get: { request.source.audioMediaIndex ?? 0 },
                                                         set: { request.source.audioMediaIndex = $0 })) {
                    ForEach(0..<audioCount, id: \.self) { i in Text("Audiostrom \(i + 1)").tag(i) }
                }
                .frame(width: 260)
            }
            Text("Tipp: SDP-Dateien lassen sich auf die Felder ziehen. Eine SDP mit Video und Audio wird automatisch aufgeteilt.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") { save(play: false) }
                    .disabled(!canSave)
                Button("Speichern und abspielen") { save(play: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 520)
    }

    private var canSave: Bool {
        !(request.source.videoSDP ?? "").isEmpty || !(request.source.audioSDP ?? "").isEmpty
    }

    private var audioCount: Int {
        SDPMedia.parse(request.source.audioSDP ?? "").media.filter { $0.kind == .audio }.count
    }

    private func binding(_ kp: WritableKeyPath<SavedSource, String?>) -> Binding<String> {
        Binding(get: { request.source[keyPath: kp] ?? "" },
                set: { request.source[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    private func distribute(_ text: String) {
        for s in SDPText.sections(text) {
            if s.kind == .video { request.source.videoSDP = s.text }
            if s.kind == .audio && (request.source.audioSDP ?? "").isEmpty { request.source.audioSDP = s.text }
        }
    }

    private func save(play: Bool) {
        model.upsert(request.source)
        dismiss()
        if play {
            if model.selection == .saved(request.source.id) {
                model.activate(.saved(request.source.id))
            } else {
                model.selection = .saved(request.source.id)
            }
        }
    }
}

private struct SDPSlot: View {
    let title: String
    let kind: SDPText.Kind
    @Binding var text: String
    let onCombined: (String) -> Void
    @State private var targeted = false
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Datei …") { importing = true }.controlSize(.small)
                Button("Einfügen") {
                    if let s = NSPasteboard.general.string(forType: .string) { accept(s) }
                }
                .controlSize(.small)
                Button("Leeren") { text = "" }.controlSize(.small).disabled(text.isEmpty)
            }
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: targeted ? 2 : 1))
                .overlay {
                    if text.isEmpty {
                        Text("SDP hierher ziehen, einfügen oder eintippen")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    for u in urls {
                        let a = u.startAccessingSecurityScopedResource()
                        defer { if a { u.stopAccessingSecurityScopedResource() } }
                        if let s = try? String(contentsOf: u, encoding: .utf8) { accept(s) }
                    }
                    return true
                } isTargeted: { targeted = $0 }
                .accessibilityLabel(title)
            ValidationLine(text: text, kind: kind)
        }
        .frame(maxWidth: .infinity)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "sdp") ?? .plainText, .plainText, .data]) { r in
            if case .success(let u) = r {
                let a = u.startAccessingSecurityScopedResource()
                defer { if a { u.stopAccessingSecurityScopedResource() } }
                if let s = try? String(contentsOf: u, encoding: .utf8) { accept(s) }
            }
        }
    }

    private func accept(_ s: String) {
        let secs = SDPText.sections(s)
        if secs.contains(where: { $0.kind == .video }) && secs.contains(where: { $0.kind == .audio }) {
            onCombined(s)
        } else if let mine = secs.first(where: { $0.kind == kind }) {
            text = secs.filter { $0.kind == kind }.count > 1 ? s : mine.text
        } else {
            text = s
        }
    }
}

private struct ValidationLine: View {
    let text: String
    let kind: SDPText.Kind

    var body: some View {
        let r = result
        if let r {
            Label {
                Text(r.1).font(.caption).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: r.0 == .ok ? "checkmark.circle.fill" : r.0 == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(r.0 == .ok ? .green : r.0 == .warning ? .orange : .red)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var result: (Support, String)? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let (media, err) = SDPMedia.parse(text)
        if let err { return (.unsupported, err) }
        let wanted: SDPMedia.Kind = kind == .video ? .video : .audio
        guard let m = media.first(where: { $0.kind == wanted }) else {
            return (.unsupported, kind == .video ? "Kein Videostrom in dieser SDP." : "Kein Audiostrom in dieser SDP.")
        }
        let (s, msg) = m.check
        let base = "\(m.summary) · \(m.destination):\(m.port)"
        return (s, msg.isEmpty ? "Unterstützt: \(base)" : "\(base) – \(msg)")
    }
}

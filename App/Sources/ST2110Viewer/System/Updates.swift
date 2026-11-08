import Foundation
import Observation
import Sparkle

/// Updates über Sparkle. Die Versionsliste (appcast.xml) liegt beim jeweils
/// neuesten GitHub-Release; jedes Update ist mit einem EdDSA-Schlüssel signiert,
/// dessen öffentlicher Teil in der Info.plist steht (SUPublicEDKey).
@MainActor
@Observable
final class Updates {
    /// Nur im fertigen App-Bundle mit Schlüssel aktiv (nicht bei „swift run“ oder Bildschirmfotos).
    let available: Bool
    private let controller: SPUStandardUpdaterController?

    var automaticChecks: Bool {
        get { access(keyPath: \.automaticChecks); return controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            withMutation(keyPath: \.automaticChecks) { controller?.updater.automaticallyChecksForUpdates = newValue }
        }
    }

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let ok = Bundle.main.bundleURL.pathExtension == "app"
            && !key.isEmpty && !key.hasPrefix("@")
            && SnapshotRunner.outputDir == nil
        available = ok
        controller = ok ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
    }

    func checkNow() { controller?.checkForUpdates(nil) }
}

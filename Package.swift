// swift-tools-version:5.10
//
// 2110 Viewer – native macOS-App (SwiftUI) mit eingebettetem GStreamer.
//
// GStreamer wird NICHT systemweit installiert. scripts/fetch-gstreamer.sh lädt
// die offiziellen macOS-Pakete von gstreamer.freedesktop.org, prüft die
// Prüfsummen und entpackt sie nach vendor/gstreamer (ohne Administratorrechte).
// Ein anderer Ort lässt sich mit der Umgebungsvariable GSTREAMER_PREFIX angeben.

import Foundation
import PackageDescription

let root = Context.packageDirectory
let gst = Context.environment["GSTREAMER_PREFIX"] ?? "\(root)/vendor/gstreamer"

let package = Package(
    name: "ST2110Viewer",
    defaultLocalization: "de",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ST2110Viewer", targets: ["ST2110Viewer"]),
    ],
    dependencies: [
        // Updates (MIT, siehe packaging/licenses/Sparkle-LICENSE.txt)
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // C-Empfangskern (auch unter Linux mit make baubar und getestet)
        .target(
            name: "ST2110Core",
            path: "core",
            exclude: ["tests", "tools", "Makefile"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .define("_DARWIN_C_SOURCE"),
                .unsafeFlags([
                    "-I\(gst)/include/gstreamer-1.0",
                    "-I\(gst)/include/glib-2.0",
                    "-I\(gst)/lib/glib-2.0/include",
                    "-I\(gst)/include",
                    "-Wno-deprecated-declarations",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(gst)/lib",
                    "-lgstreamer-1.0", "-lgstbase-1.0", "-lgstapp-1.0", "-lgstvideo-1.0",
                    "-lgstnet-1.0", "-lgobject-2.0", "-lglib-2.0", "-lgio-2.0",
                    // Zur Laufzeit liegen die Bibliotheken im App-Bundle
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    // Für „swift run“ während der Entwicklung
                    "-Xlinker", "-rpath", "-Xlinker", "\(gst)/lib",
                ]),
            ]
        ),
        // Plattformneutrale Logik ohne GStreamer (NMOS, Quellen, Diagnose) – testbar
        .target(
            name: "ST2110Kit",
            path: "App/Sources/ST2110Kit"
        ),
        .executableTarget(
            name: "ST2110Viewer",
            dependencies: ["ST2110Core", "ST2110Kit", .product(name: "Sparkle", package: "Sparkle")],
            path: "App/Sources/ST2110Viewer",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Network"),
            ]
        ),
        .testTarget(
            name: "ST2110KitTests",
            dependencies: ["ST2110Kit"],
            path: "App/Tests/ST2110KitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)

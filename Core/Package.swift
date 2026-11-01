// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TCTriggerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TCTriggerKit", targets: ["TCTriggerKit"]),
        .executable(name: "ltcgen", targets: ["ltcgen"]),
        .executable(name: "ltcmon", targets: ["ltcmon"]),
    ],
    targets: [
        // C code: vendored libltc (LGPL-3.0, see libltc/COPYING) plus the real-time audio core.
        .target(
            name: "CTCCore",
            path: "Sources/CTCCore",
            exclude: ["libltc/COPYING", "libltc/AUTHORS", "libltc/README-vendored.md"],
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("libltc"),
            ],
            linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio")]
        ),
        .target(
            name: "TCTriggerKit",
            dependencies: ["CTCCore"],
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
        ),
        .executableTarget(
            name: "ltcgen",
            dependencies: ["TCTriggerKit"]
        ),
        .executableTarget(
            name: "ltcmon",
            dependencies: ["TCTriggerKit"]
        ),
        .testTarget(
            name: "TCTriggerKitTests",
            dependencies: ["TCTriggerKit", "CTCCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)

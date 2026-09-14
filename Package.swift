// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Osmotic",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Osmotic", targets: ["Osmotic"]),
        .library(name: "OsmoticCore", targets: ["OsmoticCore"]),
    ],
    targets: [
        // Protocol logic with no UI: DUML framing, BLE advert decoding, the camera datalink, the
        // CompositePack manifest decoder and the HTTP downloader. Nonisolated on purpose — the
        // datalink runs on its own thread and the app decides where everything else runs.
        .target(
            name: "OsmoticCore",
            path: "Sources/OsmoticCore"
        ),
        .executableTarget(
            name: "Osmotic",
            dependencies: ["OsmoticCore"],
            path: "Sources/Osmotic",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "OsmoticCoreTests",
            dependencies: ["OsmoticCore"],
            path: "Tests/OsmoticCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)

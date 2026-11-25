// swift-tools-version: 6.0
import PackageDescription

// Code shared by Bench on the Mac and the Bench companion on iPhone.
let package = Package(
    name: "BenchKit",
    platforms: [.macOS("15.0"), .iOS("26.0")],
    products: [
        .library(name: "BenchKit", targets: ["BenchKit"]),
    ],
    targets: [
        .target(name: "BenchKit", resources: [.copy("Resources/IconPreviews")]),
        // Recorded sessions and the results expected from them are read
        // from the source folder (see Golden.swift), not bundled.
        .testTarget(name: "BenchKitTests", dependencies: ["BenchKit"], exclude: ["Fixtures", "Goldens"]),
    ]
)

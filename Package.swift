// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hyperglyph",
    platforms: [.macOS(.v15)],
    products: [
        // Reusable trackpad-gesture engine: raw touch capture, tap-zone and
        // drawn-shape detection ($1 unistroke recognizer), trackpad haptics,
        // and action running. Depend on this to build your own trackpad tools.
        .library(name: "HyperglyphKit", targets: ["HyperglyphKit"]),
        // The menu-bar app.
        .executable(name: "Hyperglyph", targets: ["Hyperglyph"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Kyome22/OpenMultitouchSupport.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "HyperglyphKit",
            dependencies: [
                .product(name: "OpenMultitouchSupport", package: "OpenMultitouchSupport"),
            ],
            path: "Sources/HyperglyphKit",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .executableTarget(
            name: "Hyperglyph",
            dependencies: ["HyperglyphKit"],
            path: "Sources/Hyperglyph",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "HyperglyphKitTests",
            dependencies: ["HyperglyphKit"],
            path: "Tests/HyperglyphKitTests",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)

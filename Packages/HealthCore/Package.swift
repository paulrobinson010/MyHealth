// swift-tools-version: 5.9
import PackageDescription

/// The analysis engine behind both MyHealth apps.
///
/// Pure Swift with no UI and no platform frameworks, so the macOS app, the
/// watchOS app and `swift test` all compile the same sources.
let package = Package(
    name: "HealthCore",
    platforms: [.macOS(.v14), .watchOS(.v10), .iOS(.v17)],
    products: [
        .library(name: "HealthCore", targets: ["HealthCore"])
    ],
    targets: [
        .target(name: "HealthCore"),
        .testTarget(name: "HealthCoreTests", dependencies: ["HealthCore"])
    ]
)

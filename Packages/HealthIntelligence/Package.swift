// swift-tools-version: 5.9
import PackageDescription

/// The Apple Intelligence layer, shared by the Mac and iPhone apps.
///
/// Separate from HealthCore because HealthCore must stay free of platform
/// frameworks — it compiles on watchOS and on Linux under `swift test`. This
/// package is where `FoundationModels` is allowed to appear, always behind
/// `canImport` so a build without it still succeeds.
let package = Package(
    name: "HealthIntelligence",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "HealthIntelligence", targets: ["HealthIntelligence"])
    ],
    dependencies: [
        .package(path: "../HealthCore")
    ],
    targets: [
        .target(name: "HealthIntelligence", dependencies: ["HealthCore"]),
        .testTarget(name: "HealthIntelligenceTests", dependencies: ["HealthIntelligence"])
    ]
)

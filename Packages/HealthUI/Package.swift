// swift-tools-version: 5.9
import PackageDescription

/// SwiftUI shared by the Mac, iPhone and iPad apps.
///
/// Exists so a screen like the combined fitness-and-body view is written once
/// and behaves identically everywhere, rather than being reimplemented per
/// target and drifting.
let package = Package(
    name: "HealthUI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HealthUI", targets: ["HealthUI"])
    ],
    dependencies: [
        .package(path: "../HealthCore")
    ],
    targets: [
        .target(name: "HealthUI", dependencies: ["HealthCore"])
    ]
)

// swift-tools-version: 5.9
import PackageDescription

// This package exists so the pure-Swift analysis engine that powers MyHealth.app
// can be built and tested from the command line with `swift test`, on any
// platform, without opening Xcode. The macOS app target compiles the exact same
// sources directly (see MyHealth.xcodeproj).
let package = Package(
    name: "HealthCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HealthCore", targets: ["HealthCore"])
    ],
    targets: [
        .target(name: "HealthCore", path: "MyHealth/Core"),
        .testTarget(name: "HealthCoreTests", dependencies: ["HealthCore"], path: "Tests/HealthCoreTests")
    ]
)

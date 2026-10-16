// swift-tools-version: 6.0
import PackageDescription

// Peek compiles by default. Define `PEEK_DISABLED` (Swift Active Compilation Conditions) in the configurations
// that must not contain it, e.g. App Store builds, and every file compiles to nothing. See the README.
let package = Package(
    name: "Peek",
    platforms: [.iOS("16.6"), .macOS(.v13)],
    products: [
        .library(name: "Peek", targets: ["Peek"]),
        .library(name: "PeekCore", targets: ["PeekCore"]),
    ],
    targets: [
        .target(name: "PeekCore"),
        .target(name: "Peek", dependencies: ["PeekCore"]),
        .testTarget(name: "PeekCoreTests", dependencies: ["PeekCore"]),
    ],
    swiftLanguageModes: [.v6]
)

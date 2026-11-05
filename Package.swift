// swift-tools-version: 6.2
import PackageDescription

// ClawCore and the `claw` CLI build on macOS and Linux (CI runs the core tests on both).
// The SwiftUI app needs macOS, so its target exists only when the manifest is evaluated on macOS.
var products: [Product] = [
    .library(name: "ClawCore", targets: ["ClawCore"]),
    .executable(name: "claw", targets: ["claw"]),
]

var targets: [Target] = [
    .target(name: "ClawCore"),
    .executableTarget(name: "claw", dependencies: ["ClawCore"]),
    .testTarget(name: "ClawCoreTests", dependencies: ["ClawCore"]),
]

#if os(macOS)
    products.append(.executable(name: "ClawApp", targets: ["ClawApp"]))
    targets.append(
        .executableTarget(name: "ClawApp", dependencies: ["ClawCore"], resources: [.process("Resources")]))
#endif

let package = Package(
    name: "Claw",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)

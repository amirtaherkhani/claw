// swift-tools-version: 6.2
import PackageDescription

// ClefCore and the `clef` CLI build on macOS and Linux (CI runs the core tests on both).
// The SwiftUI app needs macOS, so its target exists only when the manifest is evaluated on macOS.
var products: [Product] = [
    .library(name: "ClefCore", targets: ["ClefCore"]),
    .executable(name: "clef", targets: ["clef"]),
]

var targets: [Target] = [
    .target(name: "ClefCore"),
    .executableTarget(name: "clef", dependencies: ["ClefCore"]),
    .testTarget(name: "ClefCoreTests", dependencies: ["ClefCore"]),
]

#if os(macOS)
    products.append(.executable(name: "ClefApp", targets: ["ClefApp"]))
    targets.append(.executableTarget(name: "ClefApp", dependencies: ["ClefCore"]))
#endif

let package = Package(
    name: "Clef",
    platforms: [.macOS(.v26)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)

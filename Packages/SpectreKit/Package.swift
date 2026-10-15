// swift-tools-version: 6.2
import PackageDescription

// SpectreKit: the client code every platform shares -- the session (over
// GDPKit), VideoToolbox decode and Metal presentation.
let package = Package(
    name: "SpectreKit",
    defaultLocalization: "en",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "SpectreKit", targets: ["SpectreKit"]),
    ],
    dependencies: [
        .package(path: "../GDPKit"),
    ],
    targets: [
        // Localizable.xcstrings: the words SpectreKit shows (docs/localization.md).
        .target(name: "SpectreKit", dependencies: ["GDPKit"], resources: [.process("Localizable.xcstrings")]),
        .testTarget(name: "SpectreKitTests", dependencies: ["SpectreKit"]),
    ]
)

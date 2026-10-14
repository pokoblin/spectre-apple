// swift-tools-version: 6.2
import PackageDescription

// SpectreKit: the client code every platform shares -- the session (over
// GDPKit), VideoToolbox decode and Metal presentation.
let package = Package(
    name: "SpectreKit",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "SpectreKit", targets: ["SpectreKit"]),
    ],
    dependencies: [
        .package(path: "../GDPKit"),
    ],
    targets: [
        .target(name: "SpectreKit", dependencies: ["GDPKit"]),
        .testTarget(name: "SpectreKitTests", dependencies: ["SpectreKit"]),
    ]
)

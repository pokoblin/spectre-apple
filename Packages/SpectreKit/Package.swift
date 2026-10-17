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
        // av1-test-720p.obu: the AV1 test stream (TestStream.av1), which
        // VideoToolbox can't encode here: 60 frames of ffmpeg's testsrc2 at
        // 1280×720, SVT-AV1 low delay (pred-struct=1, CBR 1 Mbit/s), one
        // keyframe, in the low-overhead bitstream format.
        .target(name: "SpectreKit", dependencies: ["GDPKit"],
                resources: [.process("Localizable.xcstrings"), .copy("TestSource/av1-test-720p.obu")]),
        .testTarget(name: "SpectreKitTests", dependencies: ["SpectreKit"]),
    ]
)

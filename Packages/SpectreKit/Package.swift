// swift-tools-version: 6.2
import PackageDescription

// SpectreKit: the client code every platform shares -- the session (over
// GDPKit), VideoToolbox and PyroWave decode and Metal presentation. PyroWave
// (the codec's native Metal port) is prebuilt into PyroWave.xcframework by
// scripts/build-pyrowave.sh.
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
        .binaryTarget(name: "PyroWave", path: "Artifacts/PyroWave.xcframework"),
        .target(name: "SpectreKit", dependencies: ["GDPKit", "PyroWave"],
                resources: [.process("Localizable.xcstrings"), .copy("TestSource/av1-test-720p.obu")],
                linkerSettings: [.linkedFramework("Metal"), .linkedFramework("IOSurface"), .linkedLibrary("c++")]),
        // pyrowave-host-720p.bin: one 1280×720 frame from the host's encoder
        // (PyroWave's Vulkan library at the pinned revision, on Linux), its
        // payload's length (UInt32) and payload, then the host's own decode
        // as Float32 block means: luma per 16×16, Cb and Cr per 8×8.
        .testTarget(name: "SpectreKitTests", dependencies: ["SpectreKit", "PyroWave"],
                    resources: [.copy("Fixtures/pyrowave-host-720p.bin")]),
    ]
)

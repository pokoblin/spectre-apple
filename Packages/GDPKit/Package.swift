// swift-tools-version: 6.2
import PackageDescription

// GDPKit: Swift over libgdp. The C++ (libgdp, protobuf, ngtcp2, OpenSSL,
// zstd and the C ABI in Native/) is prebuilt into GDPCore.xcframework by
// scripts/build-gdpcore.sh; Swift sees only Native/include/gdpcore.h.
let package = Package(
    name: "GDPKit",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "GDPKit", targets: ["GDPKit"]),
    ],
    targets: [
        .binaryTarget(name: "GDPCore", path: "Artifacts/GDPCore.xcframework"),
        .target(
            name: "GDPKit",
            dependencies: ["GDPCore"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .testTarget(name: "GDPKitTests", dependencies: ["GDPKit"]),
    ]
)

// swift-tools-version: 6.2
// Experiment: can Swift's C++ interop use libgdp's headers directly?
// See docs/prototype-findings.md (risk 1). Needs scripts/build-gdpcore.sh macos first.
import PackageDescription

let root = Context.packageDirectory + "/../.."
let protoGen = root + "/build/gdpcore/macos/cmake/libgdp/proto"
let vcpkgInclude = root + "/build/vcpkg/arm64-osx-spectre/arm64-osx-spectre/include"

let package = Package(
    name: "CxxInteropProbe",
    platforms: [.macOS("27.0")],
    targets: [
        .target(
            name: "LibGDPHeaders",
            cxxSettings: [.unsafeFlags(["-I", root + "/third_party/ghost/libgdp/include", "-I", protoGen,
                                        "-I", vcpkgInclude, "-std=c++20"])]
        ),
        .executableTarget(
            name: "Probe",
            dependencies: ["LibGDPHeaders"],
            swiftSettings: [.interoperabilityMode(.Cxx),
                            .unsafeFlags(["-Xcc", "-I", "-Xcc", root + "/third_party/ghost/libgdp/include",
                                          "-Xcc", "-I", "-Xcc", protoGen, "-Xcc", "-I", "-Xcc", vcpkgInclude,
                                          "-Xcc", "-std=c++20"])],
            linkerSettings: [.unsafeFlags(["-L", root + "/build/gdpcore/macos/out/lib", "-lGDPCore"])]
        ),
    ],
    cxxLanguageStandard: .cxx20
)

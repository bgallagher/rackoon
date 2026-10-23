// swift-tools-version:6.0
import PackageDescription

// The Mac app and its tools need AppKit; on Linux (the integration lab's CI job) only the core, the OpenSSH transport
// and their tests are built.
#if os(macOS)
let macProducts: [Product] = [
    .executable(name: "RackoonMac", targets: ["RackoonMac"]),
    .executable(name: "rackoon-probe", targets: ["RackoonProbe"]),
    .executable(name: "rackoon-pty", targets: ["RackoonPTY"]),
]
#else
let macProducts: [Product] = []
#endif

#if os(macOS)
let macTargets: [Target] = [
    .executableTarget(
        name: "RackoonMac",
        dependencies: [
            "RackoonCore", "RackoonSSHSystem",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            "RackoonPTY",   // built alongside the app; found next to its executable at run time
        ],
        path: "Apps/RackoonMac",
        exclude: ["Resources/SOURCES.md"],
        sources: ["Sources/RackoonMac"],
        resources: [.copy("Resources/themes.json"), .copy("Resources/rackoon-icon.png"), .copy("Resources/rackoon-icon-dev.png")]
    ),
    .executableTarget(
        name: "RackoonProbe",
        dependencies: ["RackoonSSHSystem"],
        path: "Apps/RackoonProbe/Sources/RackoonProbe"
    ),
    .executableTarget(
        name: "RackoonPTY",
        dependencies: ["RackoonCore"],
        path: "Apps/RackoonPTY/Sources/RackoonPTY"
    ),
    .testTarget(
        // The Mac app's own logic that needs AppKit (icon images on disk, uploads) or its models.
        name: "RackoonMacTests",
        dependencies: ["RackoonMac", "RackoonCore"],
        path: "Apps/RackoonMac/Tests/RackoonMacTests"
    ),
]
#else
let macTargets: [Target] = []
#endif

let package = Package(
    name: "Rackoon",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RackoonCore", targets: ["RackoonCore"]),
        .library(name: "RackoonSSHSystem", targets: ["RackoonSSHSystem"]),
    ] + macProducts,
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.99.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.1"),
    ],
    targets: [
        .target(
            name: "RackoonCore",
            path: "Packages/RackoonCore/Sources/RackoonCore"
        ),
        .target(
            name: "RackoonSSHSystem",
            dependencies: ["RackoonCore", .product(name: "Subprocess", package: "swift-subprocess")],
            path: "Packages/RackoonSSHSystem/Sources/RackoonSSHSystem"
        ),
        .testTarget(
            name: "RackoonSSHSystemTests",
            dependencies: ["RackoonSSHSystem"],
            path: "Packages/RackoonSSHSystem/Tests/RackoonSSHSystemTests"
        ),
        .testTarget(
            name: "RackoonCoreTests",
            dependencies: ["RackoonCore"],
            path: "Packages/RackoonCore/Tests/RackoonCoreTests"
        ),
    ] + macTargets
)

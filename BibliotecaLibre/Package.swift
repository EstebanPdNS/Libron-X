// swift-tools-version: 6.0
import PackageDescription

// Native non-Apple builds expose the portable core without AppKit/SwiftUI targets.
// The macOS products and target dependencies retain their existing names and APIs.
var products: [Product] = [
    .library(name: "LibronixCore", targets: ["LibronixCore"])
]
var targets: [Target] = [
    .systemLibrary(name: "CSQLite"),
    .target(name: "CLibronxCompression", publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]),
    .target(name: "LibronixCore", dependencies: [
        "CLibronxCompression",
        .target(name: "CSQLite", condition: .when(platforms: [.macOS, .linux])),
        .product(name: "Crypto", package: "swift-crypto",
                 condition: .when(platforms: [.linux, .windows]))
    ]),
    .testTarget(name: "LibronixCoreTests", dependencies: ["LibronixCore"], resources: [.copy("Fixtures")])
]
var inspectDependencies: [Target.Dependency] = [
    "LibronixCore",
    .product(name: "Crypto", package: "swift-crypto",
             condition: .when(platforms: [.linux, .windows]))
]

#if os(macOS)
products += [
    .library(name: "LibronixOutputMac", targets: ["LibronixOutputMac"]),
    .executable(name: "LibronX", targets: ["BibliotecaMac"]),
    .executable(name: "LibronXRebuild", targets: ["MacRebuild"])
]
targets += [
    .target(name: "LibronixOutputMac", dependencies: ["LibronixCore"]),
    .executableTarget(name: "BibliotecaMac", dependencies: ["LibronixCore", "LibronixOutputMac"]),
    .testTarget(name: "BibliotecaMacTests", dependencies: ["BibliotecaMac", "LibronixCore", "LibronixOutputMac"]),
    .executableTarget(name: "MacRebuild", dependencies: ["LibronixCore", "LibronixOutputMac"], resources: [.process("Resources")]),
    .testTarget(name: "MacRebuildTests", dependencies: ["MacRebuild", "LibronixCore"])
]
inspectDependencies.append("LibronixOutputMac")
#endif
products.append(.executable(name: "libronix-inspect", targets: ["LibronixInspect"]))
targets.append(.executableTarget(name: "LibronixInspect", dependencies: inspectDependencies))

let package = Package(
    name: "LibronX",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.3.1")
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)

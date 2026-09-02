// swift-tools-version: 6.0
// ota — the fleet's over-the-air release flow for Mac apps, in one place.
//
// Three products, one tag line:
//   OTAKit  the release primitives (version, binary facts, bundle, sign,
//           notarize, appcast, feed). No dependencies. What `ota` drives.
//   ota     the CLI. Installed once, on the Mac that holds the credentials.
//   OTA     the app-side library: the SUFeedURL-gated updater, CLIInstall,
//           BuildInfo. Depends on Sparkle. Apps depend on this product only.
import PackageDescription

let package = Package(
    name: "ota",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OTAKit", targets: ["OTAKit"]),
        .library(name: "OTA", targets: ["OTA"]),
        .executable(name: "ota", targets: ["OTACLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(name: "OTAKit"),
        // `Sources/ota` would be `Sources/OTA` on a case-insensitive disk.
        .executableTarget(
            name: "OTACLI",
            dependencies: [
                "OTAKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "OTA",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "OTAKitTests", dependencies: ["OTAKit"]),
    ]
)

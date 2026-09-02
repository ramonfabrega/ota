// swift-tools-version: 6.0
// ota — the fleet's over-the-air release flow for Mac apps, in one place.
//
// Three products, one tag line:
//   OTAKit      the release primitives (version, binary facts, bundle, sign,
//               notarize, appcast, feed). No dependencies. What `ota` drives.
//   ota         the CLI. Installed once, on the Mac that holds the credentials.
//   OTA         the app-side identity: BuildInfo and CLIInstall. NO
//               DEPENDENCIES, deliberately — a consumer's CLI-side library
//               wants these and must not link Sparkle to get them (ccc's
//               CCCKit is what every test links).
//   OTAUpdater  the SUFeedURL-gated Sparkle updater. Imported only by the
//               executable target that embeds Sparkle.framework and carries
//               the @executable_path/../Frameworks rpath.
import PackageDescription

let package = Package(
    name: "ota",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OTAKit", targets: ["OTAKit"]),
        .library(name: "OTA", targets: ["OTA"]),
        .library(name: "OTAUpdater", targets: ["OTAUpdater"]),
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
        .target(name: "OTA"),
        .target(
            name: "OTAUpdater",
            dependencies: ["OTA", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "OTAKitTests", dependencies: ["OTAKit"]),
        // Linking OTA and NOT Sparkle is itself the check: if OTA ever grows
        // a Sparkle dependency again, this target stops building.
        .testTarget(name: "OTATests", dependencies: ["OTA"]),
    ]
)

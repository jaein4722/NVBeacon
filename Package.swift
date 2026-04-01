// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NVBeacon",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.3"),
    ],
    targets: [
        .executableTarget(
            name: "NVBeacon",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                    .when(platforms: [.macOS])
                ),
            ]
        ),
        .testTarget(
            name: "NVBeaconTests",
            dependencies: ["NVBeacon"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

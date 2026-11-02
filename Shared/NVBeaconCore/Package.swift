// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NVBeaconCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "NVBeaconCore", targets: ["NVBeaconCore"])],
    targets: [
        .target(name: "NVBeaconCore"),
        .testTarget(name: "NVBeaconCoreTests", dependencies: ["NVBeaconCore"]),
    ],
    swiftLanguageModes: [.v6]
)

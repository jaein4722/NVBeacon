// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NVBeaconMobile",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "NVBeaconMobile", targets: ["NVBeaconMobile"])],
    dependencies: [
        .package(path: "../../Shared/NVBeaconCore"),
        .package(url: "https://github.com/andrewkomkov/Citadel.git", revision: "e03900270579c155d4d63b42467e5e065a3a2e84"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/andrewkomkov/swift-nio-ssh.git", branch: "gantry-fixes"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3"..<"4.0.0"),
    ],
    targets: [
        .target(name: "NVBeaconMobile", dependencies: [
            .product(name: "NVBeaconCore", package: "NVBeaconCore"),
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "_CryptoExtras", package: "swift-crypto"),
        ]),
        .testTarget(name: "NVBeaconMobileTests", dependencies: [
            "NVBeaconMobile", .product(name: "NIOEmbedded", package: "swift-nio"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)

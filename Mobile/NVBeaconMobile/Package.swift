// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NVBeaconMobile",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "NVBeaconMobile", targets: ["NVBeaconMobile"])],
    dependencies: [
        .package(path: "../../Shared/NVBeaconCore"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4"..<"0.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3"..<"4.0.0"),
    ],
    targets: [
        .target(name: "NVBeaconMobile", dependencies: [
            .product(name: "NVBeaconCore", package: "NVBeaconCore"),
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "NVBeaconMobileTests", dependencies: [
            "NVBeaconMobile", .product(name: "NIOEmbedded", package: "swift-nio"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)

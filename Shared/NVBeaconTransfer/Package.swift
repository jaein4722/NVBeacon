// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NVBeaconTransfer",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "NVBeaconTransfer", targets: ["NVBeaconTransfer"])],
    dependencies: [.package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.4")],
    targets: [
        .target(name: "NVBeaconTransfer", dependencies: [.product(name: "SwiftASN1", package: "swift-asn1")]),
        .testTarget(name: "NVBeaconTransferTests", dependencies: ["NVBeaconTransfer"])
    ]
)

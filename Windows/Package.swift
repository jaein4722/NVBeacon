// swift-tools-version: 6.2
import PackageDescription

// The Windows client lives in its own package so the root macOS package
// (which depends on Sparkle and Apple-only frameworks) stays untouched.
let package = Package(
    name: "NVBeaconWindows",
    dependencies: [
        .package(path: "../Shared/NVBeaconCore"),
    ],
    targets: [
        .target(
            name: "NVBeaconWindowsKit",
            dependencies: [.product(name: "NVBeaconCore", package: "NVBeaconCore")]
        ),
        .executableTarget(
            name: "NVBeacon",
            dependencies: [
                "NVBeaconWindowsKit",
                .product(name: "NVBeaconCore", package: "NVBeaconCore"),
            ],
            linkerSettings: [
                // A tray app must not open a console window.
                .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]),
                .linkedLibrary("User32"),
                .linkedLibrary("Shell32"),
                .linkedLibrary("Gdi32"),
            ]
        ),
        .executableTarget(
            name: "nvbeacon-cli",
            dependencies: [
                "NVBeaconWindowsKit",
                .product(name: "NVBeaconCore", package: "NVBeaconCore"),
            ]
        ),
        // Prints its argv as JSON; tests use it to check Windows command-line quoting.
        .executableTarget(name: "ArgvEcho"),
        .testTarget(
            name: "NVBeaconWindowsKitTests",
            dependencies: ["NVBeaconWindowsKit", "ArgvEcho"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

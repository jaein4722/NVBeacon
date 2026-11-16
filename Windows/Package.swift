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
        // C wrapper over the WebView2 COM API. Needs the SDK headers from
        // scripts/fetch-webview2.ps1; WebView2Loader.dll is loaded at run time.
        .target(
            name: "CWebView2",
            cSettings: [.headerSearchPath("../../ThirdParty/webview2/pkg/build/native/include")],
            linkerSettings: [.linkedLibrary("Ole32"), .linkedLibrary("User32")]
        ),
        .executableTarget(
            name: "NVBeacon",
            dependencies: [
                "NVBeaconWindowsKit",
                "CWebView2",
                .product(name: "NVBeaconCore", package: "NVBeaconCore"),
            ],
            resources: [.copy("UI")],
            linkerSettings: [
                // A tray app must not open a console window.
                .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]),
                .linkedLibrary("User32"),
                .linkedLibrary("Shell32"),
                .linkedLibrary("Gdi32"),
                .linkedLibrary("Dwmapi"),
                .linkedLibrary("Ole32"),
                .linkedLibrary("Advapi32"),
                .linkedLibrary("Shcore"),
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

// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Hider",
    platforms: [
        // Sequoia is the floor — Plugin Playground's supported range.
        // Building with a newer SDK still unlocks Liquid Glass on Tahoe+.
        .macOS(.v15),
    ],
    products: [
        .library(name: "HiderCore", targets: ["HiderCore"]),
        .executable(name: "HiderApp", targets: ["HiderApp"]),
        .executable(name: "hiderctl", targets: ["hiderctl"]),
    ],
    targets: [
        .target(
            name: "NotifyBridge",
            path: "src",
            exclude: [
                "Hider-Bridging-Header.h",
                "Hider.m",
                "HiderApp.swift",
                "SettingsManager.swift",
                "ZKSwizzle",
                "tweak.h",
            ],
            sources: ["notify_bridge.c"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "HiderCore",
            dependencies: ["NotifyBridge"],
            path: "Sources/HiderCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "HiderApp",
            dependencies: ["HiderCore"],
            path: "src",
            exclude: [
                "Hider-Bridging-Header.h",
                "Hider.m",
                "ZKSwizzle",
                "notify_bridge.c",
                "include",
                "tweak.h",
            ],
            sources: ["HiderApp.swift", "SettingsManager.swift"],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "hiderctl",
            dependencies: ["HiderCore"],
            path: "Sources/hiderctl",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "HiderCoreTests",
            dependencies: ["HiderCore"],
            path: "Tests/HiderCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)

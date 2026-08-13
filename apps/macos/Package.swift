// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TodoAgentNative",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "TodoAgent", targets: ["TodoAgentApp"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Vendor/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "TodoAgentApp",
            dependencies: ["GhosttyKit"],
            path: "Sources/TodoAgentApp",
            exclude: ["TerminalResources/README.md"],
            resources: [
                .process("Resources"),
                .copy("TerminalResources/ghostty"),
                .copy("TerminalResources/terminfo"),
                .copy("TerminalResources/THIRD_PARTY_NOTICES.md"),
                .copy("TerminalResources/ThirdPartyLicenses"),
                .copy("TerminalResources/GPL-3.0.txt"),
                .copy("TerminalResources/todoagent-ghostty.conf"),
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-Wno-incomplete-umbrella"]),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "TodoAgentAppTests",
            dependencies: ["TodoAgentApp"],
            path: "Tests/TodoAgentAppTests"
        ),
    ]
)

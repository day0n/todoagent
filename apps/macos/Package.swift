// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TodoAgentNative",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "TodoAgent", targets: ["TodoAgentApp"]),
    ],
    targets: [
        .executableTarget(
            name: "TodoAgentApp",
            path: "Sources/TodoAgentApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TodoAgentAppTests",
            dependencies: ["TodoAgentApp"],
            path: "Tests/TodoAgentAppTests"
        ),
    ]
)

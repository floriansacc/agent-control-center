// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentctl", targets: ["agentctl"]),
        .executable(name: "AgentControlApp", targets: ["AgentControlApp"]),
    ],
    targets: [
        // Single source of truth: scanning, port attribution, focusing. Used by the app and,
        // through the agentctl binary, by the VS Code extension.
        .target(name: "AgentCore"),
        .executableTarget(name: "agentctl", dependencies: ["AgentCore"]),
        .executableTarget(name: "AgentControlApp", dependencies: ["AgentCore"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
    ],
    swiftLanguageModes: [.v5]
)

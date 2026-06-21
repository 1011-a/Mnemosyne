// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mnemosyne",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Mnemosyne", targets: ["Mnemosyne"]),
        .library(name: "DeepSeekOrchestrator", targets: ["DeepSeekOrchestrator"])
    ],
    targets: [
        // Reusable, app-agnostic DeepSeek tool-calling orchestrator SDK.
        .target(
            name: "DeepSeekOrchestrator",
            path: "Sources/DeepSeekOrchestrator",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "Mnemosyne",
            dependencies: ["DeepSeekOrchestrator"],
            path: "Sources/Mnemosyne",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MnemosyneTests",
            dependencies: ["Mnemosyne"],
            path: "Tests/MnemosyneTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "DeepSeekOrchestratorTests",
            dependencies: ["DeepSeekOrchestrator"],
            path: "Tests/DeepSeekOrchestratorTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)

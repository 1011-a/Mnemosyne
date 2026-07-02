// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mnemosyne",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Mnemosyne", targets: ["Mnemosyne"])
    ],
    dependencies: [
        // The top-level agent harness — the generic value-in/value-out tools live here, single-sourced.
        .package(url: "https://github.com/paean-ai/Fathom.git", from: "1.12.0")
    ],
    targets: [
        .executableTarget(
            name: "Mnemosyne",
            dependencies: [
                .product(name: "Fathom", package: "Fathom")
            ],
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
        )
    ]
)

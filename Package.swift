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
        // The top-level agent harness, consumed as a published package.
        .package(url: "https://github.com/paean-ai/Fathom.git", from: "0.5.0")
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

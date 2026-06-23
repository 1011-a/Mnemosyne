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
        // The top-level agent harness. Pinned to a LOCAL checkout during the SDK migration so the
        // app and Fathom can evolve together without a push/tag round-trip; switched back to the
        // published github.com/paean-ai/Fathom URL once the migration settles.
        .package(path: "../Fathom")
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

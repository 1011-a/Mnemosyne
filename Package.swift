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
    targets: [
        .executableTarget(
            name: "Mnemosyne",
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

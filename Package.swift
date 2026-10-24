// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "briglia-cli",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // Linux stand-ins for Apple-only frameworks: swift-crypto replaces
        // CryptoKit, OpenCombine replaces Combine. macOS keeps the system
        // frameworks (the products below are Linux-conditional).
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/OpenCombine/OpenCombine.git", from: "0.14.0"),
    ],
    targets: [
        .executableTarget(
            name: "briglia",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                .product(name: "OpenCombine", package: "OpenCombine", condition: .when(platforms: [.linux])),
                .product(name: "OpenCombineDispatch", package: "OpenCombine", condition: .when(platforms: [.linux])),
            ],
            path: "TelegramConcierge",
            resources: [
                .copy("Resources/BundledSkills"),
                .copy("Resources/MCPBundles"),
                .copy("Resources/QuickSetup"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "local-localizer",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "local-localizer", targets: ["LocalLocalizer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "LocalLocalizer",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)

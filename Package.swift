// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xcblame",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "xcblame", targets: ["xcblame"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "XcblameKit", exclude: ["Resources"]),
        .executableTarget(
            name: "xcblame",
            dependencies: [
                "XcblameKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "XcblameKitTests",
            dependencies: ["XcblameKit"]
        ),
        .testTarget(
            name: "xcblameTests",
            dependencies: ["xcblame", "XcblameKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

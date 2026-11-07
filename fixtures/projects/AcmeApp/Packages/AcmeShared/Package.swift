// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AcmeShared",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AcmeShared", targets: ["AcmeShared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax", exact: "602.0.0"),
    ],
    targets: [
        // A library (not macro) target using swift-syntax: compiled from source on every clean build.
        .target(
            name: "AcmeShared",
            dependencies: [.product(name: "SwiftSyntax", package: "swift-syntax")],
            plugins: ["AcmeGen"]
        ),
        .plugin(name: "AcmeGen", capability: .buildTool()),
    ]
)

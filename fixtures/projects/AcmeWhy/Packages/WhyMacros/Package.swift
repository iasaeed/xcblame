// swift-tools-version: 5.9
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "WhyMacros",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WhyMacros", targets: ["WhyMacros"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-syntax", from: "600.0.0")],
    targets: [
        .macro(name: "WhyMacrosA", dependencies: [.product(name: "SwiftCompilerPlugin", package: "swift-syntax")]),
        .macro(name: "WhyMacrosB", dependencies: [.product(name: "SwiftCompilerPlugin", package: "swift-syntax")]),
        .target(name: "WhyMacros", dependencies: ["WhyMacrosA", "WhyMacrosB"]),
    ]
)

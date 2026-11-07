// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhyUtils",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WhyUtils", targets: ["WhyUtils"])],
    targets: [.target(name: "WhyUtils")]
)

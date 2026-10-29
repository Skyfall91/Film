// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LightCode", platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)], products: [.library(name: "LightCode", targets: ["LightCode"])], targets: [.target(name: "LightCode"), .testTarget(name: "LightCodeTests", dependencies: ["LightCode"])])

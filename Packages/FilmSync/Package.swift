// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FilmSync", platforms: [.iOS("26.0"), .tvOS("26.0"), .macOS(.v15)], products: [.library(name: "FilmSync", targets: ["FilmSync"])], targets: [.target(name: "FilmSync"), .testTarget(name: "FilmSyncTests", dependencies: ["FilmSync"])])

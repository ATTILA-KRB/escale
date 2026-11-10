// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EscaleCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "EscaleCore", targets: ["EscaleCore"])],
    targets: [
        .target(name: "EscaleCore"),
        .testTarget(name: "EscaleCoreTests", dependencies: ["EscaleCore"]),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EscaleCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "EscaleCore", targets: ["EscaleCore"])],
    targets: [
        .target(name: "EscaleCore"),
        // SSH_ASKPASS minimal : un main de 3 lignes, toute la logique est dans EscaleCore (AskpassClient).
        .executableTarget(name: "escale-askpass", dependencies: ["EscaleCore"]),
        // Les tests d'intégration lancent le vrai exécutable askpass via ssh.
        .testTarget(name: "EscaleCoreTests", dependencies: ["EscaleCore", "escale-askpass"]),
    ]
)

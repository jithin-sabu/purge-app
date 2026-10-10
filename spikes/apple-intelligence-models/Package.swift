// swift-tools-version: 5.10
import PackageDescription

// Spike for jithin-sabu/purge-app#133. A standalone CLI, not part of Purge.app.
let package = Package(
    name: "apple-intelligence-models",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "aimodels", targets: ["aimodels"])],
    targets: [
        // Every private Apple interface the spike touches is looked up at run time in here.
        .target(name: "PrivateBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .executableTarget(name: "aimodels", dependencies: ["PrivateBridge"]),
    ]
)

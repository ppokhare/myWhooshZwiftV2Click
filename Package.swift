// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClickBridge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ClickBridge"),
        .testTarget(name: "ClickBridgeTests", dependencies: ["ClickBridge"]),
    ]
)

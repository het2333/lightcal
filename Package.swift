// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LightCalQwen",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "QwenCore", targets: ["QwenCore"]), .library(name: "LocalCore", targets: ["LocalCore"])],
    targets: [
        .target(name: "QwenCore", path: "ios/CalAI/Services", exclude: ["APIClient.swift", "DepthCaptureManager.swift", "HealthKitSyncService.swift"], sources: ["QwenService.swift"]),
        .testTarget(name: "QwenCoreTests", dependencies: ["QwenCore"], path: "ios/Tests/QwenCoreTests"),
        .target(name: "LocalCore", path: "ios/CalAI/Local"),
        .testTarget(name: "LocalCoreTests", dependencies: ["LocalCore"], path: "ios/Tests/LocalCoreTests"),
    ]
)

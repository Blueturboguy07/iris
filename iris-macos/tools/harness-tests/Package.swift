// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IrisHarness",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IrisHarness"),
        .testTarget(name: "IrisHarnessTests", dependencies: ["IrisHarness"])
    ]
)

// swift-tools-version: 6.0
import PackageDescription

// Production tool dispatch and risk policy with inert external boundaries.
// This package cannot launch Iris, run a shell, or contact a model.
let package = Package(
    name: "IrisChatActions",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IrisChatActions"),
        .testTarget(name: "IrisChatActionsTests", dependencies: ["IrisChatActions"])
    ]
)

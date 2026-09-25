// swift-tools-version: 6.0
import PackageDescription

// This runner compiles only the pure launch-slice policies. It deliberately
// does not build, sign, launch, or link the Iris app target.
let package = Package(
    name: "IrisLaunchSliceTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IrisLaunchSlice"),
        .testTarget(name: "IrisLaunchSliceTests", dependencies: ["IrisLaunchSlice"])
    ]
)

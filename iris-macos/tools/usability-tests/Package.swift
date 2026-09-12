// swift-tools-version: 6.0
import PackageDescription

// Compile isolated production files through relative symlinks, including the
// macOS Security policy. This does not build, sign, or launch the Iris app.
let package = Package(
    name: "IrisUsability",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "IrisUsability",
            dependencies: [.product(name: "IrisEnvironment", package: "iris-macos")]
        ),
        .testTarget(name: "IrisUsabilityTests", dependencies: ["IrisUsability"])
    ]
)

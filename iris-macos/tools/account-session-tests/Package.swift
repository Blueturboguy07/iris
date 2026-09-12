// swift-tools-version: 6.0
import PackageDescription

// This package compiles the production account/session and Keychain boundary
// with inert collaborators. It never launches Iris, reads the real Keychain,
// or forwards a URL request to the network.
let package = Package(
    name: "IrisAccountSession",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "IrisAccountSession",
            dependencies: [.product(name: "IrisEnvironment", package: "iris-macos")]
        ),
        .testTarget(name: "IrisAccountSessionTests", dependencies: ["IrisAccountSession"])
    ]
)

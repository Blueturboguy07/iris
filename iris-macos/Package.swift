// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IrisEnvironmentTests",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IrisEnvironment", targets: ["IrisEnvironment"])
    ],
    targets: [
        .target(
            name: "IrisEnvironment",
            path: "leanring-buddy",
            sources: ["IrisTestEnvironment.swift"]
        ),
        .testTarget(
            name: "IrisEnvironmentTests",
            dependencies: ["IrisEnvironment"],
            path: "tools/environment-tests/Tests/IrisEnvironmentTests"
        )
    ]
)

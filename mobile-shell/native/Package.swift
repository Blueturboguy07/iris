// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "IrisMobileShellNative",
    platforms: [
        .macOS(.v13),
        .iOS("18.4"),
    ],
    products: [
        .library(name: "IrisMobileShellCore", targets: ["IrisMobileShellCore"]),
        .library(name: "IrisMobileShellHost", targets: ["IrisMobileShellHost"]),
    ],
    targets: [
        .target(name: "IrisMobileShellCore"),
        .target(
            name: "IrisMobileShellHost",
            dependencies: ["IrisMobileShellCore"],
            resources: [
                .process("Resources/iris-packaged-api.js"),
                .copy("Resources/Adapters"),
                .copy("Resources/Marketplace"),
            ]
        ),
        .testTarget(name: "IrisMobileShellCoreTests", dependencies: ["IrisMobileShellCore"]),
    ]
)

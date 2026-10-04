// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RevisionStorageBenchmark",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "RevisionStorageBenchmark",
            dependencies: [
                .product(name: "IrisMobileShellCore", package: "native"),
            ]
        ),
    ]
)

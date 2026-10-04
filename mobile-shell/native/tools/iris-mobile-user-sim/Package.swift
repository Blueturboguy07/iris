// swift-tools-version: 5.9
//
// iris-mobile-user-sim: MiroFish-style simulated-user harness for the phone
// shell (stream s6-mobile, unit m5-personasim).
//
// MobileUserSimKit is the framework (personas, seeded runs, a device-boundary
// world, oracles, failure taxonomy, reports). It drives the REAL
// IrisMobileShellCore production types directly; only the device boundary
// (network transport, local disk free space, process lifecycle, OS version)
// is faked. See README.md for the full design and how this compares to the
// desktop tools/iris-user-sim harness it follows.
import PackageDescription

let package = Package(
    name: "IrisMobileUserSim",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "MobileUserSimKit",
            dependencies: [
                .product(name: "IrisMobileShellCore", package: "native"),
            ]
        ),
        .executableTarget(
            name: "iris-mobile-user-sim",
            dependencies: ["MobileUserSimKit"]
        ),
        .testTarget(
            name: "MobileUserSimKitTests",
            dependencies: ["MobileUserSimKit"]
        ),
    ]
)

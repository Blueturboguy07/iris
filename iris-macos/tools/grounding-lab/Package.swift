// swift-tools-version: 5.9
//
//  Package.swift
//  grounding-lab
//
//  A standalone lab tool. It is deliberately NOT part of leanring-buddy.xcodeproj
//  and is never linked into the shipping Iris app target — it exists to measure
//  how accurately a model can point at UI elements on real macOS screens.
//
//  Build and run it from a Terminal that already has Screen Recording and
//  Accessibility permission, because the tool inherits the terminal's grants:
//
//      swift build
//      .build/debug/grounding-lab capture --bundle-id com.apple.finder
//

import PackageDescription

let package = Package(
    name: "grounding-lab",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "grounding-lab", targets: ["GroundingLab"])
    ],
    targets: [
        .executableTarget(
            name: "GroundingLab",
            path: "Sources/GroundingLab"
        )
    ]
)

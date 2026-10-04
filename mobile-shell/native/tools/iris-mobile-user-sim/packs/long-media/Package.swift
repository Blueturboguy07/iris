// swift-tools-version: 5.9
//
// long-media: MiroFish-style simulated-user pack for round 3's unbounded
// video import (unit M-longimport, 2026-09-28). A "pack" per this round's
// own convention (tools/iris-mobile-user-sim/packs/<name>): a
// self-contained addition next to the main iris-mobile-user-sim harness,
// owned by one unit, rather than a change to that harness's own shared
// Scenarios/ directory (which this unit does not own).
//
// LongMediaImportPack drives the REAL production
// NativeMediaImportPolicy (IrisMobileShellCore, unmodified) against a fake
// device boundary (picker items, free storage over time, a slow iCloud
// download that pauses, a provider that deletes its own temp file early,
// disk filling from another app mid-import). It reuses
// MobileUserSimKit's SeededGenerator and FailureClass (the parts of that
// package that are genuinely generic infrastructure, not specific to the
// install/store flow it was built for) rather than re-implementing them.
//
// This pack does NOT depend on IrisMobileShellHost: the real move-vs-copy,
// crash-reaper/launch-sweep and byte-for-byte hash-match behavior needs
// real file I/O and PhotosUI/UIKit types this macOS-hosted pack cannot
// exercise; that is covered instead by real XCTest against the real Host
// types in IrisMobileShellApp/Tests/NativeMediaImportMoveAndCleanupTests.swift
// (see that file, and this task's HANDOFF.md, for the split).
import PackageDescription

let package = Package(
    name: "LongMediaImportPack",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../../.."),
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "LongMediaImportPack",
            dependencies: [
                .product(name: "IrisMobileShellCore", package: "native"),
                .product(name: "MobileUserSimKit", package: "iris-mobile-user-sim"),
            ]
        ),
        .executableTarget(
            name: "long-media-pack",
            dependencies: ["LongMediaImportPack"]
        ),
        .testTarget(
            name: "LongMediaImportPackTests",
            dependencies: ["LongMediaImportPack"]
        ),
    ]
)

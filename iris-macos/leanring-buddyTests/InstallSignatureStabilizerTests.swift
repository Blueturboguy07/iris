//
//  InstallSignatureStabilizerTests.swift
//  leanring-buddyTests
//
//  "this permissions bug seems to happen a lot across my apps ... i dont find
//  this bug with many consumer apps."
//
//  The bug, measured before the fix: guide builds ship ad-hoc signed, so TCC
//  identifies them by the hash of the exact binary (`designated => cdhash`).
//  Any rebuild changes the hash, TCC sees a new app, every grant dies.
//  Consumer apps carry certificate-anchored identities — a rule every future
//  build satisfies — which is why they never lose grants across updates.
//

import Foundation
import Testing
@testable import Iris

@Suite struct InstallSignatureStabilizerDecisionTests {

    /// The measured DR of the real Hickeyfield build output on this machine.
    @Test("an ad-hoc cdhash identity is recognized as the bug")
    func aCdhashIdentityNeedsStabilizing() {
        #expect(InstallSignatureStabilizer.identityNeedsStabilizing(
            designatedRequirement: #"cdhash H"b63d556d479e5517b0ce036a150e04cb89be0d3b""#
        ))
        // The multi-arch form codesign prints for a fat ad-hoc binary.
        #expect(InstallSignatureStabilizer.identityNeedsStabilizing(
            designatedRequirement: #"cdhash H"9967e4" or cdhash H"78d26e""#
        ))
    }

    /// The measured DR of the WhimprFlow bundle Iris's EDIT path already
    /// re-signed — the stable form that must be left byte-for-byte alone.
    @Test("a certificate-anchored identity is left alone")
    func aCertificateIdentityIsStable() {
        #expect(!InstallSignatureStabilizer.identityNeedsStabilizing(
            designatedRequirement: #"identifier "com.whimpr.whimprflow" and anchor apple generic and certificate leaf[subject.OU] = R5R3ZS54LV"#
        ))
        // A self-signed Iris Local cert anchors on the certificate root —
        // stable across rebuilds, so also left alone.
        #expect(!InstallSignatureStabilizer.identityNeedsStabilizing(
            designatedRequirement: #"identifier "com.x" and certificate root = H"abc""#
        ))
    }

    @Test("no signature at all needs stabilizing too")
    func anUnsignedBundleNeedsStabilizing() {
        #expect(InstallSignatureStabilizer.identityNeedsStabilizing(designatedRequirement: nil))
        #expect(InstallSignatureStabilizer.identityNeedsStabilizing(designatedRequirement: ""))
    }
}

/// The proof the founder asked for: "if we fix it in multiple tests consider
/// it fixed." Signs real bundles with the machine's real identity, so it is
/// gated the way the other live suites are.
///
///   IRIS_SIGNING_LIVE=1 … test -only-testing:…/InstallSignatureStabilizerLiveTests
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["IRIS_SIGNING_LIVE"] == "1",
             "set IRIS_SIGNING_LIVE=1 to sign real bundles with the machine's identity"),
    .serialized
)
@MainActor
struct InstallSignatureStabilizerLiveTests {

    /// A minimal but real app bundle, ad-hoc signed the way `tauri build`
    /// leaves its output.
    private static func makeAdHocApp() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-stab-\(UUID().uuidString)/Repro.app")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true
        )
        try #"""
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.publikhq.stabrepro</string><key>CFBundleExecutable</key><string>Repro</string></dict></plist>
        """#.write(to: root.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let exe = root.appendingPathComponent("Contents/MacOS/Repro")
        try "#!/bin/sh\ntrue\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try runCodesign(["-s", "-", "-f", root.path])
        return root.path
    }

    private static func runCodesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
    }

    /// THE WHOLE FIX IN ONE MEASUREMENT. Before: two builds, two identities,
    /// grants lost. After stabilizing both: two builds, ONE identity — which
    /// is exactly the property that makes TCC grants survive a rebuild.
    @Test("a stabilized app keeps one identity across a rebuild")
    func theIdentitySurvivesARebuild() async throws {
        let bundlePath = try Self.makeAdHocApp()
        defer { try? FileManager.default.removeItem(
            atPath: (bundlePath as NSString).deletingLastPathComponent) }

        // Confirm the pre-fix state is the bug.
        let before = await IrisLocalSigningIdentity.designatedRequirement(ofBundleAtPath: bundlePath)
        #expect(InstallSignatureStabilizer.identityNeedsStabilizing(designatedRequirement: before),
                "the fixture should start ad-hoc: \(before ?? "nil")")

        // Build 1: stabilize.
        let first = await InstallSignatureStabilizer.stabilize(bundleAtPath: bundlePath)
        #expect(first == .stabilized, "\(first)")
        let requirementAfterBuild1 = await IrisLocalSigningIdentity.designatedRequirement(ofBundleAtPath: bundlePath)
        #expect(!InstallSignatureStabilizer.identityNeedsStabilizing(designatedRequirement: requirementAfterBuild1))

        // "Rebuild": change the binary, re-sign ad-hoc — what every
        // `tauri build` does — then stabilize again, as the next install would.
        try "#!/bin/sh\ntrue # v2\n".write(
            to: URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/MacOS/Repro"),
            atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: bundlePath + "/Contents/MacOS/Repro")
        try Self.runCodesign(["-s", "-", "-f", bundlePath])
        let second = await InstallSignatureStabilizer.stabilize(bundleAtPath: bundlePath)
        #expect(second == .stabilized, "\(second)")
        let requirementAfterBuild2 = await IrisLocalSigningIdentity.designatedRequirement(ofBundleAtPath: bundlePath)

        // The property TCC actually keys on.
        #expect(requirementAfterBuild1 == requirementAfterBuild2,
                "identity changed across a rebuild — grants would be lost:\n1: \(requirementAfterBuild1 ?? "nil")\n2: \(requirementAfterBuild2 ?? "nil")")
    }

    /// The leave-alone half, against the real installed Iris — Developer ID
    /// signed and notarized. Re-signing it would break the staple, so the
    /// stabilizer must refuse.
    @Test("a certificate-signed app is not touched")
    func aRealSignedAppIsLeftAlone() async throws {
        try #require(FileManager.default.fileExists(atPath: "/Applications/Iris.app"))
        let outcome = await InstallSignatureStabilizer.stabilize(bundleAtPath: "/Applications/Iris.app")
        guard case .alreadyStable = outcome else {
            Issue.record("would have re-signed a notarized app: \(outcome)")
            return
        }
    }
}

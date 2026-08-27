//
//  AppRelaunchPackagingCommandTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Iris

@MainActor
@Suite struct AppRelaunchPackagingCommandTests {

    private static func makeClone() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-pkgcmd-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeExecutable(_ relativePath: String, in clone: String) {
        let path = (clone as NSString).appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])
    }

    /// A local tauri CLI (the common case) is preferred over the global
    /// cargo subcommand — the whimprflow "no such command: tauri" fix.
    @Test func prefersLocalTauriBinInTheFrontendPackage() {
        let clone = Self.makeClone(); defer { try? FileManager.default.removeItem(atPath: clone) }
        Self.writeExecutable("ui/node_modules/.bin/tauri", in: clone)
        #expect(AppRelaunchService.tauriPackagingCommand(clonePath: clone) == "'ui/node_modules/.bin/tauri' build")
    }

    /// Root node_modules wins when present (checked first).
    @Test func prefersRootLocalBinWhenPresent() {
        let clone = Self.makeClone(); defer { try? FileManager.default.removeItem(atPath: clone) }
        Self.writeExecutable("node_modules/.bin/tauri", in: clone)
        Self.writeExecutable("ui/node_modules/.bin/tauri", in: clone)
        #expect(AppRelaunchService.tauriPackagingCommand(clonePath: clone) == "'node_modules/.bin/tauri' build")
    }

    /// No local bin but @tauri-apps/cli is declared → npx --no-install.
    @Test func fallsBackToNpxWhenCliIsDeclaredButNotInstalled() {
        let clone = Self.makeClone(); defer { try? FileManager.default.removeItem(atPath: clone) }
        let pkg = #"{"devDependencies":{"@tauri-apps/cli":"^2.4.0"}}"#
        try? pkg.write(toFile: (clone as NSString).appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8)
        #expect(AppRelaunchService.tauriPackagingCommand(clonePath: clone) == "npx --no-install tauri build")
    }

    /// Nothing local and nothing declared → the global cargo subcommand.
    @Test func fallsBackToCargoTauriWhenNothingLocalExists() {
        let clone = Self.makeClone(); defer { try? FileManager.default.removeItem(atPath: clone) }
        #expect(AppRelaunchService.tauriPackagingCommand(clonePath: clone) == "cargo tauri build")
    }
}

// MARK: - Working out what a clone actually is

/// The bug these pin: the stack was a nine-row table keyed by catalog slug,
/// and every slug missing from it resolved to `.other` — which the relaunch
/// eligibility check refuses. So an on-demand edit to an app nobody had added
/// to the table applied, committed, and then reported that Iris "can't rebuild
/// this kind of app yet". NitroAI was edited twice that way, leaving the
/// installed app byte-identical. It is an ordinary Electron app.
@MainActor
@Suite struct CloneStackDerivationTests {

    /// NitroAI's real shape, and the reason the rules are ORDERED: it carries a
    /// `src-tauri/` directory from an abandoned Tauri shell AND ships Electron.
    /// Reading the directory first would pick the packager that produces
    /// nothing, which is worse than the `.other` it replaced — Iris would run a
    /// build that cannot yield the installed app.
    @Test("an app with both a tauri directory and electron is the one it ships")
    func electronWinsOverAVestigialTauriDirectory() {
        let evidence = AppRelaunchService.CloneStackEvidence(
            packageJSONContents: """
            {"main": "electron/main.mjs",
             "devDependencies": {"electron": "^30.0.0",
                                 "electron-builder": "^24.0.0",
                                 "@tauri-apps/cli": "^2.0.0"}}
            """,
            hasTauriConfig: true,
            hasElectronBuilderConfig: true
        )

        #expect(AppRelaunchService.stackDerived(from: evidence) == .electron)
        // And that is the whole point: this app can be rebuilt and relaunched.
        #expect(AppRelaunchService.stackCanProduceARelaunchableMacArtifact(
            AppRelaunchService.stackDerived(from: evidence)
        ))
    }

    @Test("a tauri app with no electron anywhere is tauri")
    func aRealTauriAppIsTauri() {
        let evidence = AppRelaunchService.CloneStackEvidence(
            packageJSONContents: #"{"devDependencies": {"@tauri-apps/cli": "^2.0.0"}}"#,
            hasTauriConfig: true
        )
        #expect(AppRelaunchService.stackDerived(from: evidence) == .tauri)
    }

    @Test("a next app is next, and stays ineligible for relaunch")
    func aNextAppIsNext() {
        let evidence = AppRelaunchService.CloneStackEvidence(
            packageJSONContents: #"{"dependencies": {"next": "^15.0.0", "react": "^19.0.0"}}"#,
            hasNextConfig: true
        )
        let stack = AppRelaunchService.stackDerived(from: evidence)
        #expect(stack == .nextjs)
        // A web app has no macOS binary to relaunch — deriving the stack must
        // not accidentally promise one.
        #expect(!AppRelaunchService.stackCanProduceARelaunchableMacArtifact(stack))
    }

    @Test("a clone that says nothing is still other, not a guess")
    func nothingLegibleStaysOther() {
        #expect(AppRelaunchService.stackDerived(from: .init()) == .other)
        #expect(AppRelaunchService.stackDerived(
            from: .init(packageJSONContents: #"{"name": "thing"}"#)
        ) == .other)
    }

    /// A manifest that will not parse is not evidence. Guessing a stack from a
    /// broken package.json runs the wrong packager.
    @Test("an unparseable package.json yields no dependencies")
    func aBrokenManifestIsNotEvidence() {
        #expect(AppRelaunchService.dependencyNames(inPackageJSON: "{not json").isEmpty)
        #expect(AppRelaunchService.dependencyNames(inPackageJSON: nil).isEmpty)
        #expect(AppRelaunchService.stackDerived(
            from: .init(packageJSONContents: "{not json")
        ) == .other)
    }

    @Test("both dependency tables are read")
    func bothDependencyTablesAreRead() {
        #expect(AppRelaunchService.dependencyNames(
            inPackageJSON: #"{"dependencies":{"a":"1"},"devDependencies":{"b":"2"}}"#
        ) == ["a", "b"])
    }

    /// Reading the evidence off a real directory, so the on-disk half is not
    /// left untested while the pure half is.
    @Test("evidence is read off a clone on disk")
    func evidenceIsReadFromDisk() throws {
        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-stack-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(
            atPath: "\(clone)/src-tauri", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: clone) }

        FileManager.default.createFile(
            atPath: "\(clone)/src-tauri/tauri.conf.json", contents: Data("{}".utf8))
        FileManager.default.createFile(
            atPath: "\(clone)/package.json",
            contents: Data(#"{"devDependencies":{"@tauri-apps/cli":"^2"}}"#.utf8))

        #expect(AppRelaunchService.stackOfClone(atPath: clone) == .tauri)

        // Add electron-builder the way NitroAI has it, and the ruling flips.
        FileManager.default.createFile(
            atPath: "\(clone)/electron-builder.cjs", contents: Data("module.exports={}".utf8))
        #expect(AppRelaunchService.stackOfClone(atPath: clone) == .electron)
    }

    @Test("a clone path that does not exist is other, not a crash")
    func aMissingCloneIsOther() {
        #expect(AppRelaunchService.stackOfClone(atPath: "/nope/not/here") == .other)
    }
}

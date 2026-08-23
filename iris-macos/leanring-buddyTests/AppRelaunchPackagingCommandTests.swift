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

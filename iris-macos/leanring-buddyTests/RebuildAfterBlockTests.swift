//
//  RebuildAfterBlockTests.swift
//  leanring-buddyTests
//
//  Founder report, on being told by Iris to run
//  `ui/node_modules/.bin/tauri build --bundles app` himself:
//  "lol shouldnt iris run that shit itself."
//
//  He is right, and the gap was faintly absurd. The model's diagnosis was
//  correct — the running `whimpr-tauri` binary was built outside the signed
//  `.app` workflow, so macOS gave it a different TCC identity and no source
//  edit could repair the grants. It then named the exact command that fixes it
//  and handed it over. But `AppRelaunchService` already DERIVES that invocation
//  for this stack, and the success path already runs it. The blocked path never
//  asked, because it only knew how to stop.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct RebuildAfterBlockTests {

    /// THE POINT OF THE WHOLE CHANGE. The command Iris was telling the reader to
    /// type is one it derives itself, for this exact repository layout — the
    /// whimprflow shape, where the tauri CLI is a devDependency under `ui`.
    @Test("Iris derives the very command it told the reader to run")
    func irisAlreadyKnowsTheCommandItAskedFor() throws {
        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-rebuild-\(UUID().uuidString)")
        let localCLI = clone.appendingPathComponent("ui/node_modules/.bin")
        try FileManager.default.createDirectory(at: localCLI, withIntermediateDirectories: true)
        // Executable on purpose: the derivation requires a runnable CLI, not
        // merely a file with the right name — which is correct, and which a
        // first draft of this test got wrong and was told about.
        FileManager.default.createFile(
            atPath: localCLI.appendingPathComponent("tauri").path,
            contents: Data(), attributes: [.posixPermissions: 0o755]
        )
        defer { try? FileManager.default.removeItem(at: clone) }

        let command = AppRelaunchService.tauriPackagingCommand(clonePath: clone.path)
        #expect(command.contains("ui/node_modules/.bin/tauri"),
                "did not find the repo's own CLI: \(command)")
        #expect(command.contains("build"), "not a build invocation: \(command)")
    }

    /// A stack Iris cannot package must keep the honest sentence rather than
    /// grow a button that then fails. The offer is gated on the same derivation
    /// the success path uses, so "can Iris rebuild this?" has exactly one answer
    /// in the codebase rather than two that can drift.
    @Test("a stack Iris cannot package is never offered a rebuild")
    func anUnpackageableStackIsNotOffered() {
        for stack in [BreakAppStack.nextjs, .swiftMacOS, .other] {
            #expect(AppRelaunchService.packageCommandForTesting(forStack: stack, clonePath: "/tmp/x") == nil,
                    "\(stack) would offer a rebuild it cannot perform")
        }
    }

    /// Tauri and Electron are the two Iris can carry out — Tauri from the repo's
    /// own CLI, Electron from the packaging script the project declares (Iris
    /// never invents an electron-builder invocation).
    @Test("Tauri is packageable from the repo's own CLI")
    func tauriIsPackageable() throws {
        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-rebuild-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: clone.appendingPathComponent("node_modules/.bin"), withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: clone.appendingPathComponent("node_modules/.bin/tauri").path,
            contents: Data(), attributes: [.posixPermissions: 0o755]
        )
        defer { try? FileManager.default.removeItem(at: clone) }
        let command = AppRelaunchService.packageCommandForTesting(forStack: .tauri, clonePath: clone.path)
        // Asserted against the repo's OWN CLI rather than merely non-nil: the
        // global `cargo tauri` fallback is also non-nil, so a weaker assertion
        // would pass even when the local-CLI preference had regressed — which
        // is the exact failure a real whimprflow run once hit.
        #expect(command?.contains("node_modules/.bin/tauri") == true, "got: \(command ?? "nil")")
    }
}

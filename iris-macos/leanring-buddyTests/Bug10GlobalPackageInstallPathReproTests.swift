//
//  Bug10GlobalPackageInstallPathReproTests.swift
//  leanring-buddyTests
//
//  Reproduces the Simplicity guide's exact command shape without a real
//  package-manager install: `npm install -g yarn` succeeds, then `yarn
//  install` is not found until the persistent guide shell discovers npm's
//  configured global prefix. The fake npm and yarn live only in a temporary
//  HOME, and the fake installer does not edit either zsh dotfile.
//

import Foundation
import Testing
@testable import Iris

private let bug10PtyTestsAreEnabled =
    ProcessInfo.processInfo.environment["IRIS_SKIP_PTY_TESTS"] != "1"

@MainActor
@Suite(.enabled(if: bug10PtyTestsAreEnabled), .serialized)
struct Bug10GlobalPackageInstallPathReproTests {

    private static func approved(_ command: String) throws -> GuideAutopilotApprovedCommand {
        try #require(GuideAutopilotRiskAssessment.approve(command))
    }

    /// A temporary HOME with fake package managers. The fake npm reports a
    /// configured global prefix through its read-only `prefix -g` command and
    /// creates the yarn shim there, but does not edit either zsh dotfile.
    private static func makeTemporaryReaderHome() throws -> String {
        let home = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-bug10-reader-\(UUID().uuidString)")
        let binDirectory = (home as NSString).appendingPathComponent("bin")
        try FileManager.default.createDirectory(
            atPath: binDirectory, withIntermediateDirectories: true
        )
        try """
        # The fake package manager is first on PATH for this fixture.
        export PATH="$HOME/bin:$PATH"
        """.write(
            toFile: (home as NSString).appendingPathComponent(".zshrc"),
            atomically: true, encoding: .utf8
        )

        let fakeNpm = (binDirectory as NSString).appendingPathComponent("npm")
        try #"""
        #!/bin/sh
        if [ "$1" = "prefix" ] && [ "$2" = "-g" ]; then
          printf '%s\n' "$HOME/.npm-global"
          exit 0
        fi
        if [ "$1" = "install" ] && [ "$2" = "-g" ] && [ "$3" = "yarn" ]; then
          mkdir -p "$HOME/.npm-global/bin"
          printf '%s\n' '#!/bin/sh' 'exit 0' > "$HOME/.npm-global/bin/yarn"
          chmod +x "$HOME/.npm-global/bin/yarn"
          printf '%s\n' 'added 1 package'
          exit 0
        fi
        printf '%s\n' 'unexpected fake npm command' >&2
        exit 2
        """#.write(toFile: fakeNpm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: fakeNpm
        )
        let fakePnpm = (binDirectory as NSString).appendingPathComponent("pnpm")
        try #"""
        #!/bin/sh
        exit 2
        """#.write(toFile: fakePnpm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: fakePnpm
        )
        return home
    }

    @Test func globalInstallNeedsAnEnvironmentReloadBeforeTheNextGuideStep() async throws {
        let readerHome = try Self.makeTemporaryReaderHome()
        defer { try? FileManager.default.removeItem(atPath: readerHome) }

        let shell = PersistentLoginShellInATemporaryReaderHome(
            readerHome: readerHome, startingDirectory: readerHome
        )
        try #require(await shell.start(), "the temporary login shell must come up")

        let installingYarn = await shell.run(
            try Self.approved("npm install -g yarn"), deadline: 30
        )
        #expect(
            installingYarn == .succeeded(workingDirectory: shell.currentWorkingDirectory),
            "the inert global-install fixture must report success: \(installingYarn)"
        )

        let beforeRefresh = await shell.run(
            try Self.approved("yarn install"), deadline: 30
        )
        #expect(
            beforeRefresh == .failed(
                exitStatus: 127, workingDirectory: shell.currentWorkingDirectory
            ),
            "the persistent shell must reproduce the reported command-not-found result"
        )

        let refreshing = await shell.run(
            try Self.approved(GuideAutopilotShellSession.reloadTheReadersEnvironmentCommand),
            deadline: 30
        )
        #expect(
            refreshing == .succeeded(workingDirectory: shell.currentWorkingDirectory),
            "the environment refresh machinery must complete in the same shell"
        )

        let afterRefresh = await shell.run(
            try Self.approved("yarn install"), deadline: 30
        )
        #expect(
            afterRefresh == .succeeded(workingDirectory: shell.currentWorkingDirectory),
            "the later guide step must find the binary after prefix discovery"
        )
        #expect(shell.currentWorkingDirectory == readerHome,
                "prefix discovery must preserve the guide's cwd")
        #expect(shell.numberOfShellProcessesSpawned == 1,
                "refreshing PATH must preserve the guide shell and its cwd")

        await shell.endSession()
    }
}

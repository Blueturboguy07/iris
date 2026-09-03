//
//  Bug7MissingToolSelfInstallEndToEndTests.swift
//  leanring-buddyTests
//
//  Bug 7's END-TO-END GUARD — "Fix ladder can only give advice for a missing
//  tool".
//
//  `Bug7MissingToolSelfInstallReproTests` proves the defect: the ladder's only
//  two exits for a missing tool are a model-proposed command the host guard
//  must refuse and a sentence for the reader to act on, so Test 9's install
//  stopped on step 6 of 17 with `npm install -g bun` sitting unread in the same
//  guide three steps above. This file guards the outcome the reader actually
//  cares about, one level up: an install that hits a missing tool FINISHES —
//  by itself, in the same Iris, in the same shell, with the real tool on the
//  real machine and real files on disk to show for it — with nobody asked to do
//  anything and no model asked anything either.
//
//  What is real here:
//    - the real `GuideSessionController`, its real drive loop, the real
//      `GuideAutopilotRunner`, the real failure ladder, the real risk gate and
//      the real autonomy grant (over a UserDefaults suite of this test's own);
//    - a real `zsh -l -i` on a real pty, spawned through the app's own
//      `GuideAutopilotPseudoTerminal` with the app's own generated ZDOTDIR;
//    - THIS MAC'S OWN npm, node and bun, doing real work. The repro's machine
//      is built out of shell-script stand-ins, which is right for proving that
//      Iris never RAN anything; it cannot show that what Iris runs works. Here
//      the real npm really performs a real global install, the real bun it puts
//      on the PATH really answers `bun --version` for the app's own
//      `ToolVersionService` allowlist, really installs the workspace (a real
//      `bun.lock` that real `git status` reports), and really runs the real
//      node that writes the built page;
//    - a real temporary HOME with a real `.zshrc`, and a real git checkout of
//      kneecap's workspace shape at `~/kneecap`.
//
//  Faked, and only this: the model. `Bug7TheLadderTest9Got` (from the repro
//  file) replays the two answers Test 9's ladder came back with, so no model is
//  called and nothing is spent — and one of the assertions here is that it is
//  never asked at all. The guide JSON is served from a URLProtocol instead of
//  publik.
//
//  The one thing changed from the published kneecap guide: step 3's
//  `npm install -g bun` becomes an `npm install -g` of a local package that
//  bin-links THIS Mac's real bun. Same program, same global install, same real
//  npm — what changes is where the bytes come from, because a guard test must
//  not reach the registry and must not write into this developer's own global
//  prefix. `--prefix ~/.local` and the `npm_config_prefix` in the temporary
//  `.zshrc` are what keep it in the scratch home, and both tests assert that
//  the developer's own global packages come out of the run unchanged.
//
//  This file is compiled together with `Bug7MissingToolSelfInstallReproTests.swift`,
//  whose real-pty login shell (`Bug7LoginShellInATemporaryReaderHome`), unused
//  long-running session and replayed ladder it reuses rather than copying. That
//  shell class exists there because the shipped `GuideAutopilotShellSession`
//  reads the reader's home from `FileManager` in two non-injectable places and
//  so cannot be pointed at a scratch home; see that file's header.
//
//  Deliberately NOT used: `pnpm`, whose usual form on a developer Mac is
//  corepack's shim and DOWNLOADS a pnpm build the first time it runs in a fresh
//  HOME; and the App Store step that follows `build-editor` in the published
//  guide, because a test must not open the App Store on the machine running it.
//

import Foundation
import Testing
@testable import Iris

// MARK: - The real tools this Mac has

/// The tools these tests drive for real. All three are looked up as files
/// rather than asked of a shell: the answer decides whether the suite can run
/// at all, which is settled before any shell exists.
enum Bug7EndToEndRealToolchainOnThisMac {

    /// Where bun's official installer puts it, then the two places a reader who
    /// used a package manager instead would have it. Nil on a Mac with no bun,
    /// which turns this suite off rather than substituting a stand-in.
    static let pathOfTheRealBun: String? = {
        let developersOwnHome = FileManager.default.homeDirectoryForCurrentUser.path
        let placesBunGetsInstalled = [
            (developersOwnHome as NSString).appendingPathComponent(".bun/bin/bun"),
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
        ]
        return placesBunGetsInstalled.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }()

    /// The real npm — the program the guide's own install step runs. node comes
    /// with it, lives in the same directory, and npm cannot run without it.
    static let pathOfTheRealNpm: String? = {
        ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }()

    static let pathOfTheRealNode: String? = {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }()

    /// The folder npm and node live in, which the temporary reader's own
    /// `.zshrc` puts on their PATH — the way any developer's dotfiles do.
    static var directoryHoldingTheRealNpmAndNode: String? {
        pathOfTheRealNpm.map { ($0 as NSString).deletingLastPathComponent }
    }

    /// Where a global `npm install -g` would land on THIS developer's machine —
    /// `<prefix>/lib/node_modules`, derived from npm's own location rather than
    /// hard-coded, so the safety assertion means the same thing on any Mac.
    static var thisDevelopersOwnGlobalPackagesDirectory: String? {
        pathOfTheRealNpm.map { pathOfNpm in
            let binDirectory = (pathOfNpm as NSString).deletingLastPathComponent
            let prefixDirectory = (binDirectory as NSString).deletingLastPathComponent
            return (prefixDirectory as NSString).appendingPathComponent("lib/node_modules")
        }
    }
}

/// The same opt-out `GuideAutopilotShellSessionTests`, the repro and the Bug 3
/// suites use, plus the tools: every test here spawns a real login shell and
/// runs this Mac's own npm, node and bun.
private let bug7EndToEndTestsAreEnabled =
    ProcessInfo.processInfo.environment["IRIS_SKIP_PTY_TESTS"] != "1"
        && Bug7EndToEndRealToolchainOnThisMac.pathOfTheRealBun != nil
        && Bug7EndToEndRealToolchainOnThisMac.pathOfTheRealNpm != nil
        && Bug7EndToEndRealToolchainOnThisMac.pathOfTheRealNode != nil

// MARK: - The reader's Mac at 06:59, with this machine's real tools on it

/// Akrit's machine as the shell saw it, built in a scratch directory out of
/// real parts: a home whose `.zshrc` puts `~/.local/bin` first and this Mac's
/// real npm and node next, a global npm prefix inside that home, a real git
/// checkout of kneecap's workspace shape, and a real npm package whose one
/// binary is this Mac's real bun.
///
/// No bun on the PATH. That is the fixture's whole point — the guide's own
/// install step is the only thing on this machine that can put one there.
enum Bug7EndToEndReaderMac {

    /// The folder holding the package the guide's install step installs. It is
    /// called `bun` in its own `package.json` because that is the binary it
    /// puts on the PATH, which is what `npm install -g bun` does for a reader.
    static let installerPackageFolderName = ".bun-installer-package"

    static func makeTemporaryReaderMacWithRealToolsButNoBun(
        pathOfTheRealBun: String,
        directoryHoldingTheRealNpmAndNode: String
    ) throws -> String {
        let readerHome = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-bug7-e2e-reader-\(UUID().uuidString)")
        let localBinDirectory = (readerHome as NSString).appendingPathComponent(".local/bin")
        let installerPackageDirectory = (readerHome as NSString)
            .appendingPathComponent(installerPackageFolderName)
        let buildScriptDirectory = (readerHome as NSString)
            .appendingPathComponent("kneecap/apps/mobile/scripts")
        for directory in [
            localBinDirectory,
            (installerPackageDirectory as NSString).appendingPathComponent("bin"),
            buildScriptDirectory,
        ] {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true
            )
        }

        // The reader's own zsh setup, before Iris ran anything. `~/.local/bin`
        // comes first because that is where their global npm packages land, and
        // `npm_config_prefix` is what puts them there — the shape npm's own
        // docs recommend for a global prefix that needs no administrator, and
        // here also the thing that keeps this test's global install off this
        // developer's real one.
        try """
        # The reader's own zsh setup, before Iris ran anything.
        export PATH="$HOME/.local/bin:\(directoryHoldingTheRealNpmAndNode):$PATH"
        export npm_config_prefix="$HOME/.local"
        """.write(
            toFile: (readerHome as NSString).appendingPathComponent(".zshrc"),
            atomically: true, encoding: .utf8
        )

        // What the guide's install step installs: a real npm package whose one
        // binary hands every argument to this Mac's real bun. npm links it into
        // the prefix's `bin` exactly as it links the registry's bun, so what
        // ends up on the reader's PATH runs a real bun.
        try #"{"name":"bun","version":"1.3.6","private":true,"bin":{"bun":"bin/bun"}}"#.write(
            toFile: (installerPackageDirectory as NSString)
                .appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8
        )
        let binaryTheInstallerPuts = (installerPackageDirectory as NSString)
            .appendingPathComponent("bin/bun")
        try """
        #!/bin/sh
        exec \(pathOfTheRealBun) "$@"
        """.write(toFile: binaryTheInstallerPuts, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binaryTheInstallerPuts
        )

        // kneecap's own workspace shape, in a REAL git repo, because the field
        // checkout was one and the guide's steps run inside it. The mobile
        // package's `build` is a real node script rather than `vite build`,
        // which nothing here could run offline — the file that script writes is
        // the evidence that bun and node both really ran.
        let checkoutDirectory = (readerHome as NSString).appendingPathComponent("kneecap")
        try #"{"name":"kneecap","private":true,"workspaces":["apps/*"]}"#.write(
            toFile: (checkoutDirectory as NSString).appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8
        )
        try #"{"name":"@kneecap/mobile","version":"0.0.0","scripts":{"build":"node scripts/build-editor.mjs"}}"#
            .write(
                toFile: (checkoutDirectory as NSString)
                    .appendingPathComponent("apps/mobile/package.json"),
                atomically: true, encoding: .utf8
            )
        try """
        import { mkdirSync, writeFileSync } from "node:fs";
        mkdirSync("www", { recursive: true });
        writeFileSync("www/index.html", "<!doctype html><title>kneecap editor</title>");
        console.log("built in 1.20s");
        """.write(
            toFile: (buildScriptDirectory as NSString)
                .appendingPathComponent("build-editor.mjs"),
            atomically: true, encoding: .utf8
        )
        let gitEnvironment = ["HOME": readerHome, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for gitArguments in [
            ["init", "-q"],
            ["config", "user.email", "reader@example.invalid"],
            ["config", "user.name", "Reader"],
            ["add", "-A"],
            ["commit", "-q", "-m", "kneecap"],
        ] {
            _ = runProcessAndCollectOutput(
                "/usr/bin/git", gitArguments,
                inDirectory: checkoutDirectory, environment: gitEnvironment
            )
        }
        return readerHome
    }

    /// The PATH the temporary reader's login shell ends up with, spelled once
    /// so the honest tool check below and the `.zshrc` above cannot drift.
    static func searchPathOfTheTemporaryMac(
        inHome readerHome: String, directoryHoldingTheRealNpmAndNode: String
    ) -> String {
        [
            (readerHome as NSString).appendingPathComponent(".local/bin"),
            directoryHoldingTheRealNpmAndNode,
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
    }

    /// What this temporary machine answers when Iris asks "is this tool
    /// installed, and which version?" — the same question `ToolVersionService`
    /// answers for a real reader, with the same closed allowlist and the same
    /// version arguments, asked of the SCRATCH machine's PATH instead of this
    /// developer's own.
    ///
    /// It is both what the controller's tool checks run on and what the guard
    /// asserts about the outcome: before the run bun is absent here, after it
    /// bun answers with a real version.
    static func whatTheReadersMachineSaysAbout(
        tool toolName: String,
        inHome readerHome: String,
        directoryHoldingTheRealNpmAndNode: String
    ) -> ToolVersion {
        guard let specification = ToolVersionService.toolSpecification(for: toolName) else {
            return ToolVersion(tool: toolName, available: false, version: "")
        }
        let searchPath = searchPathOfTheTemporaryMac(
            inHome: readerHome,
            directoryHoldingTheRealNpmAndNode: directoryHoldingTheRealNpmAndNode
        )
        let executablePath = searchPath.split(separator: ":").lazy.map { searchPathDirectory in
            (String(searchPathDirectory) as NSString)
                .appendingPathComponent(specification.executableName)
        }.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executablePath else {
            return ToolVersion(tool: toolName, available: false, version: "")
        }
        let whatTheToolSaid = runProcessAndCollectOutput(
            executablePath, specification.arguments,
            inDirectory: readerHome,
            environment: ["HOME": readerHome, "PATH": searchPath]
        )
        let firstLineOfWhatTheToolSaid = whatTheToolSaid
            .split(separator: "\n").first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return ToolVersion(
            tool: toolName,
            available: !firstLineOfWhatTheToolSaid.isEmpty,
            version: firstLineOfWhatTheToolSaid
        )
    }

    /// Where the guide's own install step puts bun on this machine.
    static func bunOnTheReadersPath(inHome readerHome: String) -> String {
        (readerHome as NSString).appendingPathComponent(".local/bin/bun")
    }

    /// The lockfile a real `bun install` writes — the one file Test 9 found
    /// dirty in the checkout afterwards.
    static func workspaceLockfile(inHome readerHome: String) -> String {
        (readerHome as NSString).appendingPathComponent("kneecap/bun.lock")
    }

    /// The page a real `bun run build` writes through real node.
    static func builtEditorPage(inHome readerHome: String) -> String {
        (readerHome as NSString)
            .appendingPathComponent("kneecap/apps/mobile/www/index.html")
    }

    /// What real git makes of the checkout now — the reader's own way of seeing
    /// that the install really happened in their folder.
    static func whatGitSaysAboutTheCheckout(inHome readerHome: String) -> String {
        runProcessAndCollectOutput(
            "/usr/bin/git", ["status", "--porcelain"],
            inDirectory: (readerHome as NSString).appendingPathComponent("kneecap"),
            environment: ["HOME": readerHome, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
    }

    /// The names of the packages this developer has installed globally, so the
    /// tests can prove the run left them exactly as it found them.
    static func packagesThisDeveloperHasInstalledGlobally() -> [String] {
        guard let globalPackagesDirectory =
                Bug7EndToEndRealToolchainOnThisMac.thisDevelopersOwnGlobalPackagesDirectory
        else { return [] }
        let packageNames = (try? FileManager.default.contentsOfDirectory(
            atPath: globalPackagesDirectory
        )) ?? []
        return packageNames.sorted()
    }

    /// Runs a program and returns everything it printed. Standard error is
    /// merged in: a failure message is the useful half of a diagnostic.
    private static func runProcessAndCollectOutput(
        _ launchPath: String,
        _ arguments: [String],
        inDirectory directory: String,
        environment: [String: String]
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
        } catch {
            return ""
        }
        let collectedOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: collectedOutput, as: UTF8.self)
    }
}

// MARK: - The kneecap guide, served the way publik serves it

/// The published kneecap Mac + iPhone branch, field for field — the same setup
/// steps, step ids, working directories, commands and `toolVersion` watches the
/// repro serves — with ONE command changed: step 3's `npm install -g bun`
/// installs a local package instead of the registry's, for the reason the file
/// header gives. It is still the guide telling Iris, in its own words and with
/// its own `toolVersion bun` watch, how bun is installed for this app.
final class Bug7EndToEndKneecapGuideURLProtocol: URLProtocol {

    /// The install command this guide publishes for bun. `--offline` means the
    /// registry is not merely unused but unreachable by construction, and
    /// `--prefix ~/.local` puts the result in the scratch home even if the
    /// reader's `npm_config_prefix` were somehow not read.
    static let theInstallCommandThisGuidePublishesForBun =
        "npm install -g --prefix ~/.local "
        + "~/\(Bug7EndToEndReaderMac.installerPackageFolderName) "
        + "--offline --no-audit --no-fund"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/api/iris/guides/") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestURL = request.url,
              let response = HTTPURLResponse(
                  url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.kneecapGuideJSON.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static let kneecapGuideJSON = """
    {
      "appSlug": "kneecap",
      "appName": "kneecap",
      "version": 2,
      "status": "pilot",
      "sourceOwner": "Blueturboguy07",
      "sourceRepo": "kneecap",
      "sourceCommit": "fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
      "outputType": "mobile_app",
      "estimatedMinutes": 40,
      "readmeSectionIds": ["build"],
      "branches": [
        {
          "platform": "macos",
          "target": "ios",
          "label": "Mac + iPhone",
          "shell": "terminal",
          "setupSteps": [
            {"id": "install-git", "kind": "terminal", "tool": "git", "title": "Install Git",
             "body": "Apple opens a small installer.", "command": "xcode-select --install",
             "verifierLabel": "Git responds with a version number"},
            {"id": "install-node", "kind": "open", "tool": "node", "title": "Install Node LTS",
             "body": "Choose the macOS Installer (.pkg).",
             "href": "https://nodejs.org/en/download", "actionLabel": "Open download",
             "verifierLabel": "Node responds with a version number"}
          ],
          "steps": [
            {"id": "open-shell", "kind": "terminal", "title": "Open Terminal",
             "body": "Keep it open beside Iris.", "verifierLabel": "Terminal is open"},
            {"id": "check-tools", "kind": "check", "title": "Check Git and Node",
             "body": "Git and the current Node LTS are required.",
             "command": "git --version\\nnode --version",
             "verifierLabel": "Git and Node respond with version numbers",
             "watch": {"expect": [{"type": "toolVersion", "tool": "git"},
                                  {"type": "toolVersion", "tool": "node"}]}},
            {"id": "install-bun", "kind": "terminal", "title": "Install Bun",
             "body": "kneecap's workspace is built with Bun. This installs it through npm.",
             "command": "\(theInstallCommandThisGuidePublishesForBun)",
             "verifierLabel": "Bun responds with a version number",
             "watch": {"expect": [{"type": "toolVersion", "tool": "bun"}]}},
            {"id": "clone", "workingDirectory": "~", "kind": "terminal",
             "title": "Copy kneecap to this Mac", "body": "",
             "command": "cd ~\\nif [ ! -d kneecap/.git ]; then\\ngit clone https://github.com/Blueturboguy07/kneecap.git\\nfi",
             "verifierLabel": "A kneecap folder appears",
             "watch": {"expect": [{"type": "toolVersion", "tool": "git"}]}},
            {"id": "enter-folder", "workingDirectory": "~", "kind": "terminal",
             "title": "Open the kneecap folder", "body": "", "command": "cd kneecap",
             "verifierLabel": "Your terminal prompt is inside the kneecap folder"},
            {"id": "pin-source", "workingDirectory": "~/kneecap", "kind": "terminal",
             "title": "Use the reviewed version", "body": "",
             "command": "git checkout fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
             "verifierLabel": "Git reports the reviewed commit"},
            {"id": "install-deps", "workingDirectory": "~/kneecap", "kind": "terminal",
             "title": "Install the workspace",
             "body": "A few minutes the first time — it is a Rust and TypeScript monorepo.",
             "command": "bun install",
             "verifierLabel": "The command finishes without an error"},
            {"id": "build-editor", "workingDirectory": "~/kneecap", "kind": "terminal",
             "title": "Build the editor",
             "body": "Bundles the editor into apps/mobile/www.",
             "command": "cd apps/mobile\\nbun run build",
             "verifierLabel": "Vite reports the build finished"}
          ],
          "unsupported": null
        }
      ]
    }
    """
}

// MARK: - The tests

@MainActor
@Suite(.enabled(if: bug7EndToEndTestsAreEnabled), .serialized)
struct Bug7MissingToolSelfInstallEndToEndTests {

    private static func guideServiceServingTheKneecapGuide() throws -> GuideService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Bug7EndToEndKneecapGuideURLProtocol.self]
        let defaults = try #require(
            UserDefaults(suiteName: "iris.bug7.e2e.\(UUID().uuidString)")
        )
        return GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: configuration),
            userDefaults: defaults
        )
    }

    /// The reader's "Let Iris take control of your Mac?" grant, over a suite of
    /// this test's own so the developer's real preference is untouched.
    private static func autonomyGrantOfThisTestsOwn() throws -> AutopilotAutonomyGrant {
        AutopilotAutonomyGrant(
            userDefaults: try #require(
                UserDefaults(suiteName: "iris.bug7.e2e.grant.\(UUID().uuidString)")
            )
        )
    }

    /// Polls a main-actor condition. The drive loop runs in a `Task` it does not
    /// hand back, so a test observes its effects.
    private func pump(
        within seconds: Double = 90,
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func approved(_ command: String) throws -> GuideAutopilotApprovedCommand {
        try #require(GuideAutopilotRiskAssessment.approve(command))
    }

    // MARK: The guard

    /// Test 9's journey with nothing between the drive loop and the disk faked,
    /// carried through to the end this time: a real `zsh -l -i` in a real home
    /// with no bun, a real git checkout, the real risk gate, and the guide's own
    /// install command sitting three steps above the one that fails.
    ///
    /// The reader starts the install and does nothing else. Iris has to notice
    /// the 127, run the guide's own install step, make the running shell see the
    /// new tool, retry the step, and finish the guide — with a real bun on the
    /// real PATH and real files in the real checkout, without asking a model and
    /// without asking the reader.
    ///
    /// Before the fix the ladder spent two model calls producing a host-guard
    /// refusal and a sentence, the step came back `skippedByReader`, and the
    /// install stopped dead on step 6 of 17.
    @Test func theInstallInstallsTheMissingToolItselfAndRunsToTheEnd() async throws {
        let pathOfTheRealBun = try #require(Bug7EndToEndRealToolchainOnThisMac.pathOfTheRealBun)
        let directoryHoldingTheRealNpmAndNode = try #require(
            Bug7EndToEndRealToolchainOnThisMac.directoryHoldingTheRealNpmAndNode
        )
        let readerHome = try Bug7EndToEndReaderMac.makeTemporaryReaderMacWithRealToolsButNoBun(
            pathOfTheRealBun: pathOfTheRealBun,
            directoryHoldingTheRealNpmAndNode: directoryHoldingTheRealNpmAndNode
        )
        defer { try? FileManager.default.removeItem(atPath: readerHome) }
        // The ZDOTDIR trick — and therefore the reader's whole environment —
        // only applies when the login shell is zsh, as it is on every shipped Mac.
        try #require(
            GuideAutopilotShellSession.privateZdotdir() != nil,
            "this guard needs the zsh login shell the autopilot drives"
        )

        // The fixture is only worth driving if the machine really is the one
        // Test 9 ran on: bun missing, git and node present.
        func whatTheReadersMachineSaysAbout(_ toolName: String) -> ToolVersion {
            Bug7EndToEndReaderMac.whatTheReadersMachineSaysAbout(
                tool: toolName, inHome: readerHome,
                directoryHoldingTheRealNpmAndNode: directoryHoldingTheRealNpmAndNode
            )
        }
        try #require(
            whatTheReadersMachineSaysAbout("bun").available == false,
            "the temporary Mac must start with no bun, or this guard proves nothing"
        )
        try #require(
            whatTheReadersMachineSaysAbout("git").available,
            "git was on the reader's Mac and must be on this one"
        )
        try #require(
            whatTheReadersMachineSaysAbout("node").available,
            "node was on the reader's Mac and must be on this one"
        )
        // Nothing on the new path is model-proposed, so it never meets the host
        // allowlist — but it does meet the same risk gate every guide command
        // does, and it has to pass that with no tap even for a reader who never
        // granted blanket control.
        let installCommandThisGuidePublishes =
            Bug7EndToEndKneecapGuideURLProtocol.theInstallCommandThisGuidePublishesForBun
        try #require(
            GuideAutopilotRiskAssessment.approve(
                installCommandThisGuidePublishes,
                inWorkingDirectory: (readerHome as NSString).appendingPathComponent("kneecap"),
                autonomyGranted: false
            ) != nil,
            "the guide's own install command must clear the gate without a tap"
        )
        let packagesThisDeveloperHadGlobally =
            Bug7EndToEndReaderMac.packagesThisDeveloperHasInstalledGlobally()

        let shell = Bug7LoginShellInATemporaryReaderHome(
            readerHome: readerHome, startingDirectory: readerHome
        )
        let ladder = Bug7TheLadderTest9Got()
        let controller = GuideSessionController(
            guideService: try Self.guideServiceServingTheKneecapGuide(),
            // The real question, asked of the scratch machine: the tool checks
            // the guide runs see exactly what its own login shell would.
            checkToolVersion: { toolName in
                Bug7EndToEndReaderMac.whatTheReadersMachineSaysAbout(
                    tool: toolName, inHome: readerHome,
                    directoryHoldingTheRealNpmAndNode: directoryHoldingTheRealNpmAndNode
                )
            },
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: shell,
                    longRunningSession: Bug7UnusedLongRunningShell(),
                    fixProposer: ladder,
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        controller.autonomyGrant = try Self.autonomyGrantOfThisTestsOwn()
        controller.confirmAutonomousControl = { true }

        // Test 9 resumed the guide at step 6 — install-deps — which is why the
        // guide's own "Install Bun" step (index 2) was never run.
        await controller.openGuide(
            slug: "kneecap", requestedVersion: 2,
            branchKeyFromDeepLink: "macos:ios", stepIndexFromDeepLink: 6
        )
        try #require(controller.selectedBranch != nil, "the kneecap guide must open")
        try #require(controller.currentStepIndex == 6, "the run resumes on install-deps")

        controller.startAutopilot()

        let theInstallFinished = await pump { controller.readerHasFinishedTheGuide }
        #expect(
            theInstallFinished,
            """
            THE OUTCOME: the reader started the install and did nothing else. \
            Iris hit a missing tool its own guide installs, and the install has \
            to finish by itself from there. It stopped on step \
            \(controller.currentStepIndex) with `bun install` exiting \
            \(shell.exitStatuses(of: "bun install")). Iris ran \
            \(shell.everythingIrisRan). The ladder was asked \(ladder.timesAsked) \
            time(s) and could offer \(ladder.whatTheLadderCouldOffer). Terminal \
            tail: \(shell.tailForTheModel())
            """
        )

        // The real shell really answered the field's 127, and the step's own
        // command really passed once the tool existed.
        #expect(
            shell.exitStatuses(of: "bun install").first == 127,
            """
            the real shell must answer the field's 127 first — got \
            \(shell.exitStatuses(of: "bun install")); it searches \
            \(shell.resolvedSearchPath ?? "nothing")
            """
        )
        #expect(
            shell.exitStatuses(of: "bun install").last == 0,
            """
            and the retry of the step's own command has to pass: got \
            \(shell.exitStatuses(of: "bun install"))
            """
        )

        // The tool is really on the reader's machine now, and really answers.
        let whatBunSaysNow = whatTheReadersMachineSaysAbout("bun")
        #expect(
            FileManager.default.isExecutableFile(
                atPath: Bug7EndToEndReaderMac.bunOnTheReadersPath(inHome: readerHome)
            ),
            "the guide's own install step put a real bun on the reader's PATH"
        )
        #expect(
            whatBunSaysNow.available && whatBunSaysNow.version.hasPrefix("1."),
            """
            and it answers the same version question `ToolVersionService` asks a \
            real reader: got available=\(whatBunSaysNow.available) \
            version=\(whatBunSaysNow.version)
            """
        )

        // The work those two steps exist to do really happened, in the reader's
        // own folder, where their own git can see it.
        #expect(
            FileManager.default.fileExists(
                atPath: Bug7EndToEndReaderMac.workspaceLockfile(inHome: readerHome)
            ),
            "the real bun really installed the workspace — bun.lock is on disk"
        )
        let whatGitSaysAboutTheCheckout =
            Bug7EndToEndReaderMac.whatGitSaysAboutTheCheckout(inHome: readerHome)
        #expect(
            whatGitSaysAboutTheCheckout.contains("bun.lock"),
            "and real git in the real checkout reports it: \(whatGitSaysAboutTheCheckout)"
        )
        #expect(
            (try? String(
                contentsOfFile: Bug7EndToEndReaderMac.builtEditorPage(inHome: readerHome),
                encoding: .utf8
            ))?.contains("kneecap editor") == true,
            "and the step after it ran real bun and real node — the page they write is on disk"
        )

        // Nobody was asked for anything: not the reader, not a model.
        #expect(
            !controller.autopilotHandedTheCurrentStepToTheReader,
            """
            THE SYMPTOM AS REPORTED was "Your turn" — the reader installing bun \
            in their own Terminal at 07:01:51 after asking Iris "how to do:". \
            Nothing here may hand a step back.
            """
        )
        #expect(
            ladder.timesAsked == 0,
            """
            and no model was asked anything: a tool the guide installs itself is \
            not a question worth spending on, and Test 9 spent two calls to be \
            told the one command it wanted was the one the host guard must \
            refuse. The ladder was asked \(ladder.timesAsked) time(s).
            """
        )
        let transcriptTheReaderWatched = controller.autopilotRunner?.transcript ?? []
        #expect(
            !transcriptTheReaderWatched.contains {
                if case .awaitingConfirmation = $0 { return true }
                return false
            },
            "and no confirm tap was asked for either"
        )

        // What Iris ran, and what the reader watching the terminal saw.
        #expect(
            shell.everythingIrisRan.filter { $0 == installCommandThisGuidePublishes }.count == 1,
            """
            the install command runs once, not once per attempt: Iris ran \
            \(shell.everythingIrisRan)
            """
        )
        #expect(
            transcriptTheReaderWatched.contains(
                .commandFromTheGuide(text: installCommandThisGuidePublishes)
            ),
            """
            and it is shown as what it is — a command out of the guide rather \
            than an off-script fix, because that is where it came from.
            """
        )
        #expect(
            transcriptTheReaderWatched.contains {
                if case .explanation(let text) = $0 { return text.contains("bun") }
                return false
            },
            """
            and the reader watching the terminal is told which tool was missing \
            before a command they did not expect starts running.
            """
        )

        // And none of it touched this developer's own machine.
        #expect(
            Bug7EndToEndReaderMac.packagesThisDeveloperHasInstalledGlobally()
                == packagesThisDeveloperHadGlobally,
            """
            SAFETY: the global install must land in the scratch home. This \
            developer's own global packages were \(packagesThisDeveloperHadGlobally) \
            and are now \(Bug7EndToEndReaderMac.packagesThisDeveloperHasInstalledGlobally()).
            """
        )

        controller.stopAutopilot()
        _ = await pump(within: 5) { controller.autopilotRunner == nil }
        await shell.endSession()
    }

    // MARK: The control

    /// The fixture, driven by hand at the shell level, to prove it is honest:
    /// bun really is missing from this temporary Mac, the guide's own install
    /// command really does install this Mac's real bun with no network and
    /// nothing of the developer's own touched, one environment reload really is
    /// what makes the running shell see it, and `bun install` then really works
    /// — writing a real lockfile into a real git checkout.
    ///
    /// This passes with or without the fix. It exists so a failure in the guard
    /// above can only mean Iris never tried any of it, and never means a broken
    /// scratch machine.
    @Test func theTemporaryMacIsHonestAndItsRealToolsDoRealWork() async throws {
        let pathOfTheRealBun = try #require(Bug7EndToEndRealToolchainOnThisMac.pathOfTheRealBun)
        let directoryHoldingTheRealNpmAndNode = try #require(
            Bug7EndToEndRealToolchainOnThisMac.directoryHoldingTheRealNpmAndNode
        )
        let readerHome = try Bug7EndToEndReaderMac.makeTemporaryReaderMacWithRealToolsButNoBun(
            pathOfTheRealBun: pathOfTheRealBun,
            directoryHoldingTheRealNpmAndNode: directoryHoldingTheRealNpmAndNode
        )
        defer { try? FileManager.default.removeItem(atPath: readerHome) }
        try #require(GuideAutopilotShellSession.privateZdotdir() != nil)
        let packagesThisDeveloperHadGlobally =
            Bug7EndToEndReaderMac.packagesThisDeveloperHasInstalledGlobally()

        let shell = Bug7LoginShellInATemporaryReaderHome(
            readerHome: readerHome, startingDirectory: readerHome
        )
        try #require(await shell.start(), "the login shell must come up")
        _ = await shell.run(try approved("cd ~/kneecap"), deadline: 30)

        let withoutBun = await shell.run(try approved("bun install"), deadline: 60)
        #expect(
            withoutBun == .failed(
                exitStatus: 127, workingDirectory: shell.currentWorkingDirectory
            ),
            "bun is missing, so the real shell answers 127: got \(withoutBun)"
        )

        // The guide's own install step, run in the same shell Iris drives, with
        // the real npm this Mac has.
        let installingBun = await shell.run(
            try approved(
                Bug7EndToEndKneecapGuideURLProtocol.theInstallCommandThisGuidePublishesForBun
            ),
            deadline: 120
        )
        #expect(
            installingBun == .succeeded(workingDirectory: shell.currentWorkingDirectory),
            """
            the guide's own install command works on this machine, offline: got \
            \(installingBun); terminal tail: \(shell.tailForTheModel())
            """
        )
        #expect(
            FileManager.default.isExecutableFile(
                atPath: Bug7EndToEndReaderMac.bunOnTheReadersPath(inHome: readerHome)
            ),
            "and it really put a bun on the reader's PATH"
        )

        // The reload the fix reuses: `hash -r` is what makes a shell that has
        // already looked for bun and failed look again.
        _ = await shell.run(
            try approved(GuideAutopilotShellSession.reloadTheReadersEnvironmentCommand),
            deadline: 60
        )

        let withBun = await shell.run(try approved("bun install"), deadline: 120)
        #expect(
            withBun == .succeeded(workingDirectory: shell.currentWorkingDirectory),
            """
            everything the stopped install needed was three commands away in the \
            shell it was already holding: got \(withBun); terminal tail: \
            \(shell.tailForTheModel())
            """
        )
        #expect(
            FileManager.default.fileExists(
                atPath: Bug7EndToEndReaderMac.workspaceLockfile(inHome: readerHome)
            ),
            "and the real bun wrote a real bun.lock into the real checkout"
        )
        #expect(
            Bug7EndToEndReaderMac.packagesThisDeveloperHasInstalledGlobally()
                == packagesThisDeveloperHadGlobally,
            "SAFETY: and the developer's own global packages are untouched"
        )

        await shell.endSession()
    }
}

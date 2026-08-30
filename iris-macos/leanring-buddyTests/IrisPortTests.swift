//
//  IrisPortTests.swift
//  leanring-buddyTests
//
//  Behavior ported from the Tauri shell. The suite mirrors the intent of the
//  Rust unit tests at the bottom of `iris-desktop/src-tauri/src/main.rs`
//  (`mod tests`, lines 884-1069), which remains the behavioral spec, and adds
//  coverage for the pieces that only exist on this side of the port.
//

import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

// The helpers under test are main-actor isolated, so the suite has to be too.
@MainActor
struct IrisPortTests {

    // MARK: - Deep link parsing (main.rs: accepts_one_exact_versioned_guide_link)

    @Test func acceptsOneExactVersionedGuideLink() async throws {
        let parseResult = IrisDeepLinkParser.parse("iris://guide/cue?version=7")

        guard case .success(.guide(let guideDeepLink)) = parseResult else {
            Issue.record("an exact versioned guide link should parse")
            return
        }
        #expect(guideDeepLink.slug == "cue")
        #expect(guideDeepLink.version == 7)
        #expect(guideDeepLink.branchKey == nil)
        #expect(guideDeepLink.stepIndex == nil)
    }

    // MARK: - main.rs: carries_the_reader_s_place_across_the_handoff

    @Test func carriesTheReadersPlaceAcrossTheHandoff() async throws {
        let parseResult = IrisDeepLinkParser.parse(
            "iris://guide/lunara?version=1&branch=macos:android&step=6"
        )

        guard case .success(.guide(let guideDeepLink)) = parseResult else {
            Issue.record("a handoff carrying branch and step should parse")
            return
        }
        #expect(guideDeepLink.slug == "lunara")
        #expect(guideDeepLink.branchKey == "macos:android")
        #expect(guideDeepLink.stepIndex == 6)
    }

    @Test func stepZeroIsTheFirstStepNotAMissingOne() async throws {
        let parseResult = IrisDeepLinkParser.parse("iris://guide/cue?version=3&step=0")

        guard case .success(.guide(let guideDeepLink)) = parseResult else {
            Issue.record("step zero should parse")
            return
        }
        #expect(guideDeepLink.stepIndex == 0)
    }

    /// main.rs accepts a step with no branch on purpose: the step is checked
    /// against the guide's real branch on arrival, so on its own it is a hint
    /// rather than something to refuse at parse time.
    @Test func aStepWithoutABranchIsAcceptedAndResolvedLater() async throws {
        let parseResult = IrisDeepLinkParser.parse("iris://guide/cue?version=3&step=4")

        guard case .success(.guide(let guideDeepLink)) = parseResult else {
            Issue.record("a step without a branch should still parse")
            return
        }
        #expect(guideDeepLink.branchKey == nil)
        #expect(guideDeepLink.stepIndex == 4)
    }

    // MARK: - main.rs: rejects_broadened_or_ambiguous_guide_links

    @Test func rejectsBroadenedOrAmbiguousGuideLinks() async throws {
        let deepLinksThatMustBeRejected = [
            "iris://guide/cue",
            "iris://guide/cue/extra?version=1",
            "iris://guide/Cue?version=1",
            "iris://guide/cue?version=0",
            "iris://guide/cue?version=1&version=2",
            "iris://guide/cue?version=1&platform=macos",
            "https://publikhq.com/cue?version=1",
            // A resume point still has to be one of the shapes the guide
            // library can actually produce.
            "iris://guide/cue?version=1&branch=linux:desktop",
            "iris://guide/cue?version=1&branch=macos",
            "iris://guide/cue?version=1&branch=macos:watch",
            "iris://guide/cue?version=1&branch=macos:desktop&branch=windows:desktop",
            "iris://guide/cue?version=1&step=-1",
            "iris://guide/cue?version=1&step=9000",
            "iris://guide/cue?version=1&step=2&step=3",
        ]

        for deepLinkThatMustBeRejected in deepLinksThatMustBeRejected {
            let parseResult = IrisDeepLinkParser.parse(deepLinkThatMustBeRejected)
            guard case .failure = parseResult else {
                Issue.record("should have rejected \(deepLinkThatMustBeRejected)")
                continue
            }
        }
    }

    @Test func rejectsUnknownQueryParametersOutrightRatherThanIgnoringThem() async throws {
        let parseResult = IrisDeepLinkParser.parse("iris://guide/cue?version=1&utm_source=email")

        #expect(parseResult == .failure(.unsupportedGuideParameter))
    }

    @Test func rejectsAStepPastTheParsingCeiling() async throws {
        #expect(IrisDeepLinkParser.parse("iris://guide/cue?version=1&step=500")
            == .success(.guide(GuideDeepLink(
                slug: "cue",
                version: 1,
                branchKey: nil,
                stepIndex: 500
            ))))
        #expect(IrisDeepLinkParser.parse("iris://guide/cue?version=1&step=501")
            == .failure(.invalidGuideStep))
    }

    @Test func rejectsCredentialsPortsAndFragmentsOnGuideLinks() async throws {
        let deepLinksThatMustBeRejected = [
            "iris://guide:8080/cue?version=1",
            "iris://someone@guide/cue?version=1",
            "iris://someone:secret@guide/cue?version=1",
            "iris://guide/cue?version=1#payload",
            "iris://guide/-cue?version=1",
            "iris://guide/cue-?version=1",
            "iris://guide/?version=1",
        ]

        for deepLinkThatMustBeRejected in deepLinksThatMustBeRejected {
            let parseResult = IrisDeepLinkParser.parse(deepLinkThatMustBeRejected)
            guard case .failure = parseResult else {
                Issue.record("should have rejected \(deepLinkThatMustBeRejected)")
                continue
            }
        }
    }

    // MARK: - The sign-in callback, which only this app has

    @Test func theAuthCallbackFormParsesAndIsDistinctFromAGuideLink() async throws {
        let parseResult = IrisDeepLinkParser.parse(
            "iris://auth/callback?code=abc123&state=xyz789"
        )

        guard case .success(let deepLink) = parseResult else {
            Issue.record("a well-formed sign-in callback should parse")
            return
        }
        guard case .authCallback(let authCallback) = deepLink else {
            Issue.record("the sign-in callback must not be read as a guide link")
            return
        }
        #expect(authCallback.authorizationCode == "abc123")
        #expect(authCallback.opaqueStateToken == "xyz789")

        // The two forms must never be confusable in either direction.
        let guideParseResult = IrisDeepLinkParser.parse("iris://guide/cue?version=7")
        guard case .success(.guide) = guideParseResult else {
            Issue.record("a guide link must not be read as a sign-in callback")
            return
        }
    }

    @Test func theAuthCallbackKeepsTheSameStrictPosture() async throws {
        let deepLinksThatMustBeRejected = [
            // An unknown parameter is refused here exactly as it is on a guide link.
            "iris://auth/callback?code=abc123&state=xyz789&redirect=https://evil.example",
            // A code with no state is the shape a CSRF attempt takes.
            "iris://auth/callback?code=abc123",
            "iris://auth/callback?state=xyz789",
            "iris://auth/callback?code=abc123&code=def456&state=xyz789",
            "iris://auth/callback?code=&state=xyz789",
            "iris://auth/callback",
            "iris://auth/callback/extra?code=abc123&state=xyz789",
            "iris://auth/token?code=abc123&state=xyz789",
        ]

        for deepLinkThatMustBeRejected in deepLinksThatMustBeRejected {
            let parseResult = IrisDeepLinkParser.parse(deepLinkThatMustBeRejected)
            guard case .failure = parseResult else {
                Issue.record("should have rejected \(deepLinkThatMustBeRejected)")
                continue
            }
        }
    }

    // MARK: - main.rs: external_hosts_are_explicitly_allowlisted

    @Test func externalHostsAreExplicitlyAllowlisted() async throws {
        #expect(ExternalLinkPolicy.isAllowedExternalHost("publikhq.com"))
        #expect(ExternalLinkPolicy.isAllowedExternalHost("github.com"))
        #expect(ExternalLinkPolicy.isAllowedExternalHost("git-scm.com"))
        // Hosts the published guides link to.
        #expect(ExternalLinkPolicy.isAllowedExternalHost("apps.apple.com"))
        #expect(ExternalLinkPolicy.isAllowedExternalHost("developer.android.com"))
        #expect(ExternalLinkPolicy.isAllowedExternalHost("huggingface.co"))
        #expect(ExternalLinkPolicy.isAllowedExternalHost("visualstudio.microsoft.com"))
        #expect(ExternalLinkPolicy.isAllowedExternalHost("cmake.org"))
        #expect(ExternalLinkPolicy.isAllowedExternalHost("files.browseros.com"))

        #expect(!ExternalLinkPolicy.isAllowedExternalHost("www.git-scm.com"))
        #expect(!ExternalLinkPolicy.isAllowedExternalHost("git-scm.com.attacker.example"))
        #expect(!ExternalLinkPolicy.isAllowedExternalHost("publikhq.com.attacker.example"))
        #expect(!ExternalLinkPolicy.isAllowedExternalHost("example.com"))
    }

    @Test func aLookalikeHostIsNotTheHostItImitates() async throws {
        #expect(ExternalLinkPolicy.isAllowedExternalURL("https://github.com/publik/iris"))
        #expect(!ExternalLinkPolicy.isAllowedExternalURL("https://github.com.evil.tld/publik/iris"))
        #expect(!ExternalLinkPolicy.isAllowedExternalURL("https://evil.tld/?next=github.com"))
    }

    @Test func onlyHttpsReachesAPublishedHostButLocalhostMayBePlainHttp() async throws {
        #expect(ExternalLinkPolicy.isAllowedExternalURL("https://nodejs.org/en/download"))
        // A published guide is never allowed to send the reader over plain http.
        #expect(!ExternalLinkPolicy.isAllowedExternalURL("http://nodejs.org/en/download"))
        // Localhost has no network to intercept, so the site can be developed
        // against this app without a certificate.
        #expect(ExternalLinkPolicy.isAllowedExternalURL("http://localhost:3000/cue"))
        #expect(ExternalLinkPolicy.isAllowedExternalURL("http://127.0.0.1:3000/cue"))

        // Credentials and oversized fragments are refused before the host is
        // even consulted, matching `open_external`.
        #expect(!ExternalLinkPolicy.isAllowedExternalURL("https://someone@github.com/publik"))
        #expect(!ExternalLinkPolicy.isAllowedExternalURL("https://someone:secret@github.com/publik"))
        let oversizedFragment = String(repeating: "a", count: 513)
        #expect(!ExternalLinkPolicy.isAllowedExternalURL("https://github.com/publik#\(oversizedFragment)"))
        // A file:// link never reaches the browser no matter what it points at.
        #expect(!ExternalLinkPolicy.isAllowedExternalURL("file:///etc/passwd"))
    }

    // MARK: - main.rs: tool_checks_are_closed_to_known_version_commands

    @Test func toolChecksAreClosedToKnownVersionCommands() async throws {
        let gitSpecification = ToolVersionService.toolSpecification(for: "git")
        #expect(gitSpecification?.executableName == "git")
        #expect(gitSpecification?.arguments == ["--version"])

        let xcodebuildSpecification = ToolVersionService.toolSpecification(for: "xcodebuild")
        #expect(xcodebuildSpecification?.executableName == "xcodebuild")
        #expect(xcodebuildSpecification?.arguments == ["-version"])

        // `adb` is the one tool whose version subcommand is not a flag.
        #expect(ToolVersionService.toolSpecification(for: "adb")?.arguments == ["version"])

        #expect(ToolVersionService.toolSpecification(for: "sh") == nil)
        #expect(ToolVersionService.toolSpecification(for: "curl") == nil)
        // A name is never split into a command line, so this is one unknown tool.
        #expect(ToolVersionService.toolSpecification(for: "git --version") == nil)
        #expect(ToolVersionService.toolSpecification(for: "git; rm -rf /") == nil)
        #expect(ToolVersionService.toolSpecification(for: "") == nil)
    }

    @Test func anUnlistedToolIsRefusedRatherThanRun() async throws {
        await #expect(throws: ToolVersionError.toolIsNotAllowlisted(tool: "sh")) {
            try await ToolVersionService.checkToolVersion(tool: "sh")
        }
    }

    // MARK: - main.rs: missing_tool_is_data_but_lookup_failures_remain_errors

    @Test func missingToolIsDataButLookupFailuresRemainErrors() async throws {
        let missingTool = try ToolVersionService.selectToolExecutablePath(
            tool: "node",
            searchPathLookupOutcome: .notFoundOnSearchPath,
            trustedFallbackPaths: []
        )
        #expect(missingTool == nil)

        #expect(throws: ToolVersionError.self) {
            try ToolVersionService.selectToolExecutablePath(
                tool: "node",
                searchPathLookupOutcome: .searchPathUnreadable(reason: "PATH is not set"),
                trustedFallbackPaths: []
            )
        }

        let unavailableToolVersion = ToolVersionService.unavailableToolVersion(tool: "node")
        #expect(unavailableToolVersion.available == false)
        #expect(unavailableToolVersion.version == "")
    }

    // MARK: - main.rs: only_known_macos_git_developer_tools_errors_mean_missing

    @Test func onlyKnownMacOSGitDeveloperToolsErrorsMeanMissing() async throws {
        let missingXcrunOutput = "xcrun: error: invalid active developer path "
            + "(/Library/Developer/CommandLineTools), missing xcrun at: "
            + "/Library/Developer/CommandLineTools/usr/bin/xcrun"
        let noDeveloperToolsOutput =
            "xcode-select: note: No developer tools were found, requesting install."

        #expect(ToolVersionService.isMissingMacOSGitDeveloperTools(
            tool: "git",
            output: missingXcrunOutput
        ))
        #expect(ToolVersionService.isMissingMacOSGitDeveloperTools(
            tool: "git",
            output: noDeveloperToolsOutput
        ))
        #expect(!ToolVersionService.isMissingMacOSGitDeveloperTools(
            tool: "node",
            output: missingXcrunOutput
        ))
        #expect(!ToolVersionService.isMissingMacOSGitDeveloperTools(
            tool: "git",
            output: "xcrun: error: SDK \"macosx\" cannot be located"
        ))
        #expect(!ToolVersionService.isMissingMacOSGitDeveloperTools(
            tool: "git",
            output: "xcode-select: error: invalid developer directory"
        ))
    }

    // MARK: - main.rs: macos_fallbacks_are_fixed_and_limited_to_git_and_node
    //
    // DELIBERATELY DIVERGED FROM THE RUST ORIGINAL. Upstream limited the
    // fallbacks to `git` and `node` and gave every other tool an empty list.
    // That is a bug once the answer is shown to a reader: a Finder-launched
    // app's PATH has no `~/.cargo/bin`, so "do you have Rust?" was answered
    // "no" on every Mac that did, and the hickeyfield guide walked people who
    // already had Rust through installing it. `install-rust`'s own comment in
    // that guide describes the symptom — the local signal "would never fire
    // for anybody".
    //
    // What the original test was really protecting is still protected below:
    // the paths are FIXED (derived by string, never by running a shell, so
    // nothing in a tool name can be executed) and they remain per-executable.

    @Test func macOSFallbacksAreFixedAndCoverEveryToolNotJustGitAndNode() async throws {
        // The original two keep every path they had — this widened the net, it
        // did not move it.
        let gitPaths = ToolVersionService.trustedToolFallbackPaths(for: "git")
        for expected in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] {
            #expect(gitPaths.contains(expected), "git lost \(expected)")
        }
        let nodePaths = ToolVersionService.trustedToolFallbackPaths(for: "node")
        for expected in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] {
            #expect(nodePaths.contains(expected), "node lost \(expected)")
        }

        // The tools that used to get nothing at all. `cargo` is the one this
        // was written for.
        #expect(ToolVersionService.trustedToolFallbackPaths(for: "cargo")
            .contains("\(NSHomeDirectory())/.cargo/bin/cargo"))
        #expect(!ToolVersionService.trustedToolFallbackPaths(for: "docker").isEmpty)
        #expect(!ToolVersionService.trustedToolFallbackPaths(for: "python3").isEmpty)

        // Still per-executable: a lookup for one tool never offers another's
        // path, which is what makes a hit meaningful.
        for tool in ["cargo", "docker", "python3", "node", "git"] {
            let executable = "/" + tool
            #expect(
                ToolVersionService.trustedToolFallbackPaths(for: tool)
                    .allSatisfy { $0.hasSuffix(executable) },
                "\(tool) offered a path belonging to another tool"
            )
        }

        // An unknown tool has no version command, so there is nothing to run
        // and nothing to look for.
        #expect(ToolVersionService.toolSpecification(for: "sh") == nil)
    }

    // MARK: - Command output bounding (main.rs: bounded_command_output)

    @Test func commandOutputIsBoundedAndStrippedOfControlCharacters() async throws {
        let escapeSequenceOutput = Data("git version\u{1B}[31m 2.51.0\u{07}".utf8)
        #expect(ToolVersionService.boundedCommandOutput(
            standardOutput: escapeSequenceOutput,
            standardError: Data()
        ) == "git version[31m 2.51.0")

        // Newlines and tabs survive because multi-line version banners are
        // still worth reading.
        let multiLineOutput = Data("Xcode 26.2\nBuild version 17C52\n".utf8)
        #expect(ToolVersionService.boundedCommandOutput(
            standardOutput: multiLineOutput,
            standardError: Data()
        ) == "Xcode 26.2\nBuild version 17C52")

        // Standard error is used only when standard output is empty, because
        // several of these tools print their version to stderr.
        #expect(ToolVersionService.boundedCommandOutput(
            standardOutput: Data(),
            standardError: Data("openjdk 21.0.1".utf8)
        ) == "openjdk 21.0.1")

        let overlongOutput = Data(String(repeating: "v", count: 900).utf8)
        #expect(ToolVersionService.boundedCommandOutput(
            standardOutput: overlongOutput,
            standardError: Data()
        ).count == 512)
    }

    // MARK: - Git repository containment

    @Test func gitHeadRejectsAPathOutsideHomeAndHomeItself() async throws {
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        // The home directory itself is refused even though it exists and is a
        // directory: Git run at the top of a home directory is either a mistake
        // or an attempt to read a repository nobody pointed Iris at.
        #expect(throws: GitInspectionError.self) {
            try GitInspectionService.allowedRepositoryPath(homeDirectoryPath)
        }

        // Somewhere real, but outside the user's home.
        #expect(throws: GitInspectionError.self) {
            try GitInspectionService.allowedRepositoryPath("/usr")
        }
        #expect(throws: GitInspectionError.self) {
            try GitInspectionService.allowedRepositoryPath("/")
        }
        #expect(throws: GitInspectionError.self) {
            try GitInspectionService.allowedRepositoryPath("")
        }
        #expect(throws: GitInspectionError.self) {
            try GitInspectionService.allowedRepositoryPath(
                "\(homeDirectoryPath)/../../etc"
            )
        }
    }

    @Test func containmentIsComponentWiseSoASiblingNameCannotPassAsAChild() async throws {
        let homeDirectoryURL = URL(fileURLWithPath: "/Users/someone")

        #expect(GitInspectionService.isPath(
            URL(fileURLWithPath: "/Users/someone/publik"),
            containedInDirectory: homeDirectoryURL
        ))
        // A plain string prefix test would wrongly accept this one.
        #expect(!GitInspectionService.isPath(
            URL(fileURLWithPath: "/Users/someone-else/publik"),
            containedInDirectory: homeDirectoryURL
        ))
        #expect(!GitInspectionService.isPath(
            URL(fileURLWithPath: "/etc"),
            containedInDirectory: homeDirectoryURL
        ))
    }

    @Test func onlyRealCommitIdentifiersAreAccepted() async throws {
        #expect(GitInspectionService.isValidCommitIdentifier(
            "3a9c737d09280e400338a8b8f4056fef99258a42"
        ))
        #expect(!GitInspectionService.isValidCommitIdentifier("HEAD"))
        #expect(!GitInspectionService.isValidCommitIdentifier(""))
        #expect(!GitInspectionService.isValidCommitIdentifier("3a9c737"))
        // Forty characters, but not forty hexadecimal ones.
        #expect(!GitInspectionService.isValidCommitIdentifier(String(repeating: "z", count: 40)))
    }

    // MARK: - Guide models and branch identity

    @Test func branchKeyNamesTheComputerAndPhonePair() async throws {
        let macOSAndAndroidBranch = IrisGuideBranch(
            platform: .macos,
            target: .android,
            label: "Mac + Android",
            shell: .terminal,
            setupSteps: [],
            steps: [],
            unsupported: nil
        )
        let windowsDesktopBranch = IrisGuideBranch(
            platform: .windows,
            target: nil,
            label: "Windows",
            shell: .powershell,
            setupSteps: [],
            steps: [],
            unsupported: nil
        )

        #expect(IrisGuide.branchKey(for: macOSAndAndroidBranch) == "macos:android")
        #expect(IrisGuide.branchKey(for: windowsDesktopBranch) == "windows:desktop")
        // Every key the parser accepts is one branchKey can produce.
        #expect(IrisDeepLinkParser.isValidBranchKey(macOSAndAndroidBranch.branchKey))
        #expect(IrisDeepLinkParser.isValidBranchKey(windowsDesktopBranch.branchKey))
    }

    @Test func aGuideDecodesFromTheShapeTheRouteServes() async throws {
        let guideJSON = """
        {
          "appSlug": "lunara",
          "appName": "Lunara",
          "version": 2,
          "status": "pilot",
          "sourceOwner": "Blueturboguy07",
          "sourceRepo": "lunara",
          "sourceCommit": null,
          "outputType": "mobile_app",
          "estimatedMinutes": 45,
          "readmeSectionIds": ["getting-started"],
          "branches": [
            {
              "platform": "macos",
              "target": "android",
              "label": "Mac + Android",
              "shell": "terminal",
              "setupSteps": [],
              "steps": [
                {"id": "clone", "kind": "terminal", "title": "Clone", "body": "Run it.",
                 "command": "git clone https://github.com/Blueturboguy07/lunara"},
                {"id": "install", "kind": "terminal", "title": "Install", "body": "Wait."},
                {"id": "open", "kind": "open", "title": "Open", "body": "Go.",
                 "href": "https://developer.android.com/studio", "actionLabel": "Open"}
              ],
              "unsupported": null
            },
            {
              "platform": "windows",
              "target": "ios",
              "label": "Windows + iPhone",
              "shell": "powershell",
              "setupSteps": [],
              "steps": [],
              "unsupported": {
                "headline": "Windows cannot build for iPhone",
                "reason": "Apple requires Xcode, which only runs on macOS.",
                "alternatives": ["Use a Mac", "Build the Android version"]
              }
            }
          ]
        }
        """

        let decodedGuide = try JSONDecoder().decode(IrisGuide.self, from: Data(guideJSON.utf8))

        #expect(decodedGuide.appSlug == "lunara")
        #expect(decodedGuide.version == 2)
        #expect(decodedGuide.status.isPublished)
        #expect(decodedGuide.outputType == .mobileApp)
        #expect(decodedGuide.sourceCommit == nil)
        #expect(decodedGuide.reviewNote == nil)
        #expect(decodedGuide.branches.count == 2)
        #expect(decodedGuide.branch(matchingBranchKey: "macos:android")?.steps.count == 3)
        #expect(decodedGuide.branch(matchingBranchKey: "windows:ios")?.unsupported?.alternatives.count == 2)
        #expect(decodedGuide.branch(matchingBranchKey: "macos:ios") == nil)
    }

    // MARK: - Validating a handoff against the fetched guide

    @Test func aHandoffLandsOnTheBranchAndStepItNames() async throws {
        let guide = Self.twoBranchTestGuide()
        let guideDeepLink = GuideDeepLink(
            slug: "lunara",
            version: 2,
            branchKey: "macos:android",
            stepIndex: 2
        )

        let resolvedHandoff = GuideService.resolveHandoff(
            guideDeepLink,
            against: guide,
            preferredPlatform: .macos
        )

        #expect(resolvedHandoff?.branch.branchKey == "macos:android")
        #expect(resolvedHandoff?.stepIndex == 2)
    }

    @Test func aStepPastTheEndOfTheBranchIsClampedNotHonored() async throws {
        let guide = Self.twoBranchTestGuide()
        let guideDeepLink = GuideDeepLink(
            slug: "lunara",
            version: 2,
            branchKey: "macos:android",
            stepIndex: 400
        )

        let resolvedHandoff = GuideService.resolveHandoff(
            guideDeepLink,
            against: guide,
            preferredPlatform: .macos
        )

        // The branch has three steps, so the last real index is two.
        #expect(resolvedHandoff?.stepIndex == 2)
    }

    @Test func aBranchThisGuideDoesNotHaveResetsToTheStartOfARealBranch() async throws {
        let guide = Self.twoBranchTestGuide()
        // Shape-valid, but this guide has no Windows-and-Android pair.
        let guideDeepLink = GuideDeepLink(
            slug: "lunara",
            version: 2,
            branchKey: "windows:android",
            stepIndex: 2
        )

        let resolvedHandoff = GuideService.resolveHandoff(
            guideDeepLink,
            against: guide,
            preferredPlatform: .macos
        )

        // A step only travels with the branch it was counted in, so an unmatched
        // branch starts over rather than applying somebody else's step two.
        #expect(resolvedHandoff?.branch.branchKey == "macos:android")
        #expect(resolvedHandoff?.stepIndex == 0)
    }

    // MARK: - Progress storage

    @Test func progressIsKeyedBySlugAndBranchAndNotByVersion() async throws {
        // The version used to be in this key, and that is exactly what made a
        // republish wipe a reader's place. It lives in the record now.
        #expect(GuideService.progressStorageKey(
            slug: "cue",
            branchKey: "macos:ios"
        ) == "iris:progress:cue:macos:ios")
        #expect(GuideService.progressStorageKey(
            slug: "lunara",
            branchKey: "windows:desktop"
        ) == "iris:progress:lunara:windows:desktop")

        // The old shape is still spelled out somewhere, because records written
        // under it are on readers' disks and have to be findable to be rescued.
        #expect(GuideService.versionPinnedProgressStorageKey(
            slug: "cue",
            version: 7,
            branchKey: "macos:ios"
        ) == "iris:progress:cue:v7:macos:ios")
    }

    @Test func progressSurvivesARoundTripAndIsClampedToTheBranch() async throws {
        let isolatedUserDefaults = UserDefaults(
            suiteName: "com.publik.iris.tests.\(UUID().uuidString)"
        )
        let userDefaultsForThisTest = try #require(isolatedUserDefaults)
        let guideService = GuideService(
            apiBase: GuideService.defaultAPIBase,
            userDefaults: userDefaultsForThisTest
        )
        let branch = Self.twoBranchTestGuide().branches[0]

        await guideService.saveProgress(
            slug: "lunara",
            version: 2,
            branch: branch,
            progress: GuideProgress(stepIndex: 1, isCompleted: false)
        )
        let reloadedProgress = await guideService.loadProgress(
            slug: "lunara",
            version: 2,
            branchKey: branch.branchKey
        )
        #expect(reloadedProgress.stepIndex == 1)
        #expect(reloadedProgress.isCompleted == false)

        // A guide that shrank in a later version must not leave a reader
        // pointed past its end.
        await guideService.saveProgress(
            slug: "lunara",
            version: 2,
            branch: branch,
            progress: GuideProgress(stepIndex: 99, isCompleted: true)
        )
        let clampedProgress = await guideService.loadProgress(
            slug: "lunara",
            version: 2,
            branchKey: branch.branchKey
        )
        #expect(clampedProgress.stepIndex == 2)
        #expect(clampedProgress.isCompleted)

        // An untouched branch is at the start, not wherever its sibling is.
        let untouchedProgress = await guideService.loadProgress(
            slug: "lunara",
            version: 2,
            branchKey: "windows:ios"
        )
        #expect(untouchedProgress.stepIndex == 0)
        #expect(untouchedProgress.isCompleted == false)
    }

    // MARK: - API base

    @Test func onlyPublikAndLocalhostServeGuides() async throws {
        #expect(GuideService.normalizedAPIBase("https://publikhq.com") == "https://publikhq.com")
        #expect(GuideService.normalizedAPIBase("https://www.publikhq.com/") == "https://www.publikhq.com")
        #expect(GuideService.normalizedAPIBase("http://localhost:3000") == "http://localhost:3000")
        // A path on the API base would be spliced in front of the route path.
        #expect(GuideService.normalizedAPIBase("https://publikhq.com/anything?x=1") == "https://publikhq.com")

        #expect(GuideService.normalizedAPIBase("https://publikhq.com.evil.tld") == nil)
        #expect(GuideService.normalizedAPIBase("http://publikhq.com") == nil)
        #expect(GuideService.normalizedAPIBase("https://example.com") == nil)
        #expect(GuideService.normalizedAPIBase("not a url") == nil)
    }

    @Test func anInvalidSlugNeverReachesTheNetwork() async throws {
        let guideService = GuideService()

        await #expect(throws: GuideServiceError.invalidGuideSlug) {
            try await guideService.fetchGuide(slug: "Cue", version: 1)
        }
        await #expect(throws: GuideServiceError.invalidGuideSlug) {
            try await guideService.fetchGuide(slug: "", version: 1)
        }
        await #expect(throws: GuideServiceError.invalidGuideVersionRequest) {
            try await guideService.fetchGuide(slug: "cue", version: 0)
        }
    }

    // MARK: - Foreground app

    @Test func theForegroundAppPollingCadenceMatchesTheTauriPanel() async throws {
        #expect(AppAwarenessService.foregroundPollingIntervalSeconds == 1.6)

        let appAwarenessService = AppAwarenessService()
        #expect(appAwarenessService.isPollingForegroundApp == false)
        #expect(appAwarenessService.currentForegroundApp == nil)

        appAwarenessService.startPollingForegroundApp()
        #expect(appAwarenessService.isPollingForegroundApp)

        appAwarenessService.stopPollingForegroundApp()
        #expect(appAwarenessService.isPollingForegroundApp == false)
        // Nothing about the user's screen outlives the moment Iris stops watching.
        #expect(appAwarenessService.currentForegroundApp == nil)
    }

    // MARK: - Fixtures

    private static func twoBranchTestGuide() -> IrisGuide {
        let macOSAndAndroidSteps = [
            IrisGuideStep(id: "clone", kind: .terminal, title: "Clone", body: "Run it."),
            IrisGuideStep(id: "install", kind: .terminal, title: "Install", body: "Wait."),
            IrisGuideStep(id: "run", kind: .verify, title: "Run", body: "Check it."),
        ]

        return IrisGuide(
            appSlug: "lunara",
            appName: "Lunara",
            version: 2,
            status: .pilot,
            sourceOwner: "Blueturboguy07",
            sourceRepo: "lunara",
            sourceCommit: nil,
            outputType: .mobileApp,
            estimatedMinutes: 45,
            readmeSectionIds: ["getting-started"],
            reviewNote: nil,
            branches: [
                IrisGuideBranch(
                    platform: .macos,
                    target: .android,
                    label: "Mac + Android",
                    shell: .terminal,
                    setupSteps: [],
                    steps: macOSAndAndroidSteps,
                    unsupported: nil
                ),
                IrisGuideBranch(
                    platform: .windows,
                    target: .ios,
                    label: "Windows + iPhone",
                    shell: .powershell,
                    setupSteps: [],
                    steps: [],
                    unsupported: IrisUnsupportedPair(
                        headline: "Windows cannot build for iPhone",
                        reason: "Apple requires Xcode, which only runs on macOS.",
                        alternatives: ["Use a Mac"]
                    )
                ),
            ]
        )
    }
}

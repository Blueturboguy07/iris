import Foundation
import AppKit
@testable import IrisHarnessNative

/// Campaign-only driver. It never constructs Iris account/coordinator services
/// or discovers installed apps. Its source and destination are explicitly pinned.
@main struct PowerUserHost {
    private static let requiredRootPrefix = "iris-power-user-"
    private static var root: URL!
    private static var work: URL!
    static let bundleID = "dev.iris.qa.nitroai.jtxjxv"
    static let baseline = "dfbe6bc379560704724306d3df07f2347dfc4e89"
    static let frozen: [String: String] = [
        "electron/main.mjs": "8e6b53b71ad440f97f5b3eaf66941a7f135ad78c4a800017bf1cec81d1d6cda3",
        "electron-builder.cjs": "e5e57e9963f890d4ca96ad90f3a3494cdaf4e42ae78169ed3036d6d2d23bcb3d",
        "package.json": "3501b12334b13a9a0aa21348f3187a157dee38324a99a05186022334e26a3792"
    ]
    // Synthetic fixture specification only. This is not copied from a user conversation.
    static let request = """
    Add a proper backup and restore feature to NitroAI's Settings so I can move
    my library between computers without losing my work. Back up my folders,
    notes, flashcards, quizzes and study progress as a downloadable JSON file,
    but never include API keys, account credentials or machine settings.
    When I import a backup, show a preview with counts and warnings first.
    Let me cancel without changing anything. Keep my existing library by default:
    offer Skip duplicates or Import as copies, with Skip selected initially.
    Import as copies must give records new IDs and keep their folder/note/study
    relationships intact. Never silently overwrite existing work. Reject corrupt
    or unsupported files before changing anything. Show a clear success or error
    message and refresh the visible library after a successful import. Keep the
    layout compact and usable for a large library. Use the existing database and
    UI patterns, no new dependencies. Add meaningful automated tests. Don't
    change the desktop shell, app identity, packaging configuration or credentials.
    """

    enum Failure: Error { case boundary(String) }

    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do { try await run() }
        catch { print("FAILED: " + GuideAutopilotOutputBuffer.scrubbed(String(describing: error))); exit(1) }
    }

    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 4,
              CommandLine.arguments[1] == "--root" else {
            throw Failure.boundary("usage: --root <approved-scratch-root> <mode>")
        }
        let requestedRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        let mode = CommandLine.arguments[3]
        guard ["--preflight", "--feature", "--package", "--swap", "--regression-checks"].contains(mode) else { throw Failure.boundary("unknown mode") }
        let approvedParents = [URL(fileURLWithPath: "/tmp", isDirectory: true),
                               URL(fileURLWithPath: "/private/tmp", isDirectory: true)]
        guard root.lastPathComponent.hasPrefix(requiredRootPrefix),
              approvedParents.contains(where: { parent in
                  let parentPath = parent.standardizedFileURL.path
                  return root.path.hasPrefix(parentPath + "/")
              }),
              root.path == requestedRoot.standardizedFileURL.path else {
            throw Failure.boundary("root must be an explicit, resolved temporary directory named with the approved fixture prefix")
        }
        self.root = root
        self.work = root.appendingPathComponent("nitroai", isDirectory: true)
        let work = self.work!
        let fm = FileManager.default
        guard fm.fileExists(atPath: work.path),
              work.resolvingSymlinksInPath().path == work.path,
              HarnessFixtureEnvironment.scratchDirectory.path == root.appendingPathComponent("scratch").path else {
            throw Failure.boundary("wrong fixture or scratch: root=\(root.resolvingSymlinksInPath().path), work=\(work.resolvingSymlinksInPath().path), scratch=\(HarnessFixtureEnvironment.scratchDirectory.path)")
        }
        for (path, expected) in frozen {
            let file = work.appendingPathComponent(path)
            guard file.resolvingSymlinksInPath().path == file.path,
                  HarnessFrozenComparison.digest(try Data(contentsOf: file)) == expected else {
                throw Failure.boundary("isolation file changed: " + path)
            }
        }
        let runner = try MaintainShellRunner(repoRootPath: work.path)
        let remotes = try await runner.run("git remote", deadline: 15)
        guard remotes.succeeded, remotes.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.boundary("remote must be absent")
        }
        let tracked = try await runner.run("git ls-files --stage", deadline: 15)
        guard tracked.succeeded, !tracked.outputTail.split(separator: "\n").contains(where: { $0.hasPrefix("120000 ") }) else {
            throw Failure.boundary("tracked symlinks refused")
        }
        if mode == "--preflight" || mode == "--feature" {
            let head = try await runner.run("git rev-parse HEAD", deadline: 15)
            let status = try await runner.run("git status --porcelain", deadline: 15)
            guard head.succeeded, head.outputTail.trimmingCharacters(in: .whitespacesAndNewlines) == baseline,
                  status.succeeded, status.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  CodexCLILogin.currentState().isUsable else { throw Failure.boundary("baseline, clean tree or CLI unavailable") }
            print("PREFLIGHT PASS: isolated NitroAI source and profile, no remote, frozen packaging, real sandbox")
        }
        if mode == "--preflight" { return }
        if mode == "--regression-checks" {
            let sentinel = "sk-ant-" + String(repeating: "fixture", count: 20)
            let output = "Error: missing Electron runtime; api_key=\(sentinel)\n"
                + (1...120).map { "at frame\($0) (/fixture/node_modules/build/packager.ts:530:11)" }.joined(separator: "\n")
            let summary = AppRelaunchService.packagingDiagnosticSummary(output)
            print("DIAGNOSTIC CHECK: root=\(summary.contains("missing Electron runtime")) tail=\(summary.contains("frame120")) secretHidden=\(!summary.contains(sentinel)) characters=\(summary.count)")
            guard summary.contains("missing Electron runtime"), summary.contains("frame120"),
                  !summary.contains(sentinel), summary.count <= 2_000 else {
                throw Failure.boundary("packaging diagnostic regression")
            }
            let fresh = AppRelaunchService.newestLaunchableAppBundle(forStack: .electron,
                clonePath: work.path, producedAtOrAfter: .distantPast)
            guard fresh == work.appendingPathComponent("release/mac-arm64/NitroAI Iris QA.app").path,
                  AppRelaunchService.newestLaunchableAppBundle(forStack: .electron,
                    clonePath: work.path, producedAtOrAfter: .distantFuture) == nil else {
                throw Failure.boundary("release discovery or freshness regression")
            }
            print("PASS: compiled native diagnostic retains root and tail, redacts secret, respects 2000-character bound; real release artifact found; stale artifact refused")
            return
        }
        if mode == "--package" {
            let service = AppRelaunchService(packagingDeadline: 600)
            let result = await service.packageFreshBuildFromClone(clonePath: work.path, appStack: .electron)
            print("PACKAGE: " + String(describing: result))
            guard case .artifactReady(let path, _) = result,
                  path.hasPrefix(work.path + "/"), Bundle(path: path)?.bundleIdentifier == bundleID else {
                throw Failure.boundary("no safe QA artifact")
            }
            try Data(path.utf8).write(to: root.appendingPathComponent("artifacts/package-path.txt"))
            return
        }
        if mode == "--swap" {
            let fresh = work.appendingPathComponent("release/mac-arm64/NitroAI Iris QA.app")
            let installed = root.appendingPathComponent("installed/NitroAI Iris QA.app")
            guard fresh.resolvingSymlinksInPath().path == fresh.path,
                  installed.resolvingSymlinksInPath().path == installed.path,
                  Bundle(url: fresh)?.bundleIdentifier == bundleID,
                  Bundle(url: installed)?.bundleIdentifier == bundleID,
                  NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
                throw Failure.boundary("only stopped QA app may be replaced")
            }
            let result = AppRelaunchService.atomicallyReplaceBundle(installedPath: installed.path,
                withBundleAt: fresh.path, snapshotTo: root.appendingPathComponent("artifacts/pre-edit.app").path,
                undoRecoveryStore: .init(recordURL: root.appendingPathComponent("state/undo-recovery.json")))
            print("SWAP: " + String(describing: result))
            guard result.isSuccess else { throw Failure.boundary("swap failed") }
            return
        }
        let workflow = try HarnessCodexAdapter.makeWorkflow(settings: .init(maxCalls: 12, maxInputBytes: 750_000),
            maximumDurationNanoseconds: 1_200_000_000_000, webSearchEnabled: false)
        workflow.modelSession.ledgerDidChange = { writeUsage($0) }
        defer { writeUsage(workflow.modelSession.ledger.snapshot) }
        print("PLANNING: Astra Medium; implementation Astra Low; 12 calls maximum")
        let summary = FeatureEditRepoMap.summarize(repoRootPath: work.path, tokenBudget: 2200)
        let brief = try await workflow.plan(request: request, repositorySummary: summary)
        try JSONEncoder().encode(brief).write(to: root.appendingPathComponent("artifacts/plan.json"))
        guard brief.targetedQuestions.isEmpty else {
            print("NEEDS PERSONA ANSWERS: saved plan; no source edit started")
            return
        }
        let provider = HarnessWorkflowMaintainProvider(workflow: workflow)
        let editor = MaintainTierCFixer(provider: provider)
        let result = await editor.attemptOnDemandEdit(clonePath: work.path, appSlug: "nitroai-iris-qa", appStack: .electron,
            changeId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            request: request, kind: .feature,
            progressHandler: { print("EVENT: " + GuideAutopilotOutputBuffer.scrubbed(String(describing: $0))) },
            cancellationCheck: { Task.isCancelled || fm.fileExists(atPath: root.appendingPathComponent("STOP").path) },
            manifestChangeApproval: { _ in false },
            verificationCommandsOverride: .init(buildCommand: "npm run build", testCommand: "npm test -- --maxWorkers=2", commandSubdirectory: nil),
            runsAnIndependentReview: true)
        print("FEATURE RESULT: " + String(describing: result))
        try Data(String(describing: result).utf8).write(to: root.appendingPathComponent("artifacts/feature-result.txt"))
        if let assessment = provider.behaviorAssessment {
            try JSONEncoder().encode(assessment).write(to: root.appendingPathComponent("artifacts/behavior-review.json"))
            print("REVIEW: " + assessment.readerSummary)
        } else { print("REVIEW: unavailable; not cleared for automatic delivery") }
    }

    @MainActor static func writeUsage(_ snapshot: HarnessRunLedgerSnapshot) {
        let settled = snapshot.inFlightCallCount == 0
        let value: [String: Any] = [
            "admitted": snapshot.admittedCallCount, "settled": snapshot.settledCallCount,
            "inFlight": snapshot.inFlightCallCount, "inputBytes": snapshot.accountedInputBytes,
            "inputTokens": settled ? (snapshot.measuredInputTokens.map { $0 as Any } ?? NSNull()) : NSNull(),
            "cachedInputTokens": settled ? (snapshot.measuredCachedInputTokens.map { $0 as Any } ?? NSNull()) : NSNull(),
            "outputTokens": settled ? (snapshot.measuredOutputTokens.map { $0 as Any } ?? NSNull()) : NSNull(),
            "calls": snapshot.settledCalls.map { ["phase": $0.reservation.task.rawValue, "inputBytes": $0.accountedInputBytes] as [String: Any] }
        ]
        do { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("artifacts/usage.json"), options: .atomic) }
        catch { print("USAGE CHECKPOINT FAILED") }
    }
}

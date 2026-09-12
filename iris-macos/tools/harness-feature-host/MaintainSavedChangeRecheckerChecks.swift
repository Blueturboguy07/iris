import Foundation

@testable import IrisHarnessNative

/// Exercises the saved-candidate path with a disposable Git repository and
/// an inert model transport. This is a Test-bundle check, not a live app run.
@main
struct MaintainSavedChangeRecheckerChecks {
    @MainActor
    private final class Recorder {
        var phases: [HarnessRunTaskKind] = []
    }

    private struct Fixture {
        let container: URL
        let repository: URL
        let scratch: URL
        let source: URL
        let manifest: URL
        let runner: MaintainShellRunner
        let baselineHead: String
    }

    private struct Snapshot: Equatable {
        let head: String
        let cachedDiff: String
        let status: String
        let source: String
        let manifest: String
    }

    private struct CheckFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func main() async {
        do {
            guard IrisTestEnvironment.isEnabled else {
                print("SKIP saved change rechecker checks: requires the Iris Test bundle")
                return
            }
            guard MaintainSandbox.isAvailable else {
                print("SKIP saved change rechecker checks: sandbox-exec is unavailable")
                return
            }
            try await runChecks()
            print("MAINTAIN SAVED CHANGE RECHECKER CHECKS PASS: 5 groups; disposable Test-policy Git fixtures only")
        } catch {
            print("MAINTAIN SAVED CHANGE RECHECKER CHECKS FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    private static func runChecks() async throws {
        let fileManager = FileManager.default
        let brief = try HarnessTaskBrief(
            userRequest: "Change the fixture value",
            desiredOutcome: "The fixture exports the changed value",
            acceptanceCriteria: [
                .init(id: "value", statement: "The source exports featureValue equal to 2")
            ]
        )
        let encodedBrief = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
        let recipe = RepoRecipe(
            build: RepoRecipeCommand(commandLine: "test -f src/feature.js"),
            ecosystemIdentifier: "fixture",
            runtimeShape: .pureLocalApp,
            confidenceByField: [.build: 1.0],
            provenanceByField: [.build: .explicitProjectConfig]
        )

        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw CheckFailure(message: message) }
        }

        func makePolicy(repositoryRoot: String, scratchPath: String) -> MaintainSandbox.ProcessPolicy {
            MaintainSandbox.testProcessPolicy(
                scratchDirectoryPath: scratchPath,
                additionalReadOnlyPaths: [
                    "/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc",
                    "/private/var/db", "/private/var/select", "/opt/homebrew", "/usr/local",
                    "/Library/Developer", "/Applications/Xcode.app", "/dev"
                ],
                repositoryIsRegistered: { $0 == repositoryRoot }
            )
        }

        func makeFixture() async throws -> Fixture {
            let container = IrisTestEnvironment.commandScratchDirectory
                .appendingPathComponent("iris-saved-rechecker-check-\(UUID().uuidString)", isDirectory: true)
            let repository = container.appendingPathComponent("repo", isDirectory: true)
            let scratch = container.appendingPathComponent("scratch", isDirectory: true)
            let source = repository.appendingPathComponent("src/feature.js")
            let manifest = repository.appendingPathComponent("package.json")
            try fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            try Data("export const featureValue = 1;\n".utf8).write(to: source)
            try Data("{\"name\":\"fixture\",\"scripts\":{\"build\":\"true\"}}\n".utf8).write(to: manifest)

            let canonicalRepository = MaintainSandbox.canonicalPath(repository.path)
            let canonicalScratch = MaintainSandbox.canonicalPath(scratch.path)
            let runner = try MaintainShellRunner(
                repoRootPath: canonicalRepository,
                processPolicy: makePolicy(repositoryRoot: canonicalRepository, scratchPath: canonicalScratch)
            )
            let initialized = try await runner.run(
                "git init -q -b iris/edit-fixture && git add -- src/feature.js package.json && "
                    + "git -c user.name=Fixture -c user.email=fixture@example.invalid "
                    + "commit --no-gpg-sign -qm baseline",
                deadline: 30
            )
            guard initialized.succeeded else {
                throw CheckFailure(message: "fixture baseline commit failed: \(initialized.outputTail)")
            }
            let head = try await runner.run("git rev-parse --verify HEAD^{commit}", deadline: 30)
            guard head.succeeded, head.bytesDroppedBeforeTail == 0 else {
                throw CheckFailure(message: "fixture baseline HEAD could not be read")
            }
            return Fixture(
                container: container,
                repository: repository,
                scratch: scratch,
                source: source,
                manifest: manifest,
                runner: runner,
                baselineHead: head.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        func command(_ fixture: Fixture, _ text: String) async throws -> MaintainCommandResult {
            let result = try await fixture.runner.run(text, deadline: 30)
            guard result.succeeded, result.bytesDroppedBeforeTail == 0 else {
                throw CheckFailure(message: "fixture command failed (\(result.exitCode)): \(result.outputTail)")
            }
            return result
        }

        func output(_ fixture: Fixture, _ text: String) async throws -> String {
            let result = try await command(fixture, text)
            return result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func snapshot(_ fixture: Fixture) async throws -> Snapshot {
            Snapshot(
                head: try await output(fixture, "git rev-parse --verify HEAD^{commit}"),
                cachedDiff: try await output(fixture, "git diff --cached --binary"),
                status: try await output(fixture, "git status --porcelain"),
                source: String(decoding: try Data(contentsOf: fixture.source), as: UTF8.self),
                manifest: String(decoding: try Data(contentsOf: fixture.manifest), as: UTF8.self)
            )
        }

        func stageSource(_ fixture: Fixture, value: Int = 2) async throws {
            try Data("export const featureValue = \(value);\n".utf8).write(to: fixture.source)
            _ = try await command(fixture, "git add -- src/feature.js")
        }

        func stageBuildInput(_ fixture: Fixture) async throws {
            try Data("{\"name\":\"fixture\",\"scripts\":{\"build\":\"false\"}}\n".utf8)
                .write(to: fixture.manifest)
            _ = try await command(fixture, "git add -- package.json")
        }

        func makeProvider(reply: String) async throws -> (HarnessWorkflowMaintainProvider, Recorder, Int) {
            let recorder = Recorder()
            let session = try HarnessModelSession(
                implementationArm: .astraLow,
                settings: .init(maxCalls: 4, maxInputBytes: 1_000_000),
                maximumDurationNanoseconds: 60_000_000_000
            ) { request in
                recorder.phases.append(request.phase)
                if request.phase == .intake {
                    return HarnessModelReply(text: encodedBrief)
                }
                // Any edit or repair response is deliberately unusable. The
                // rechecker must never enter either maker phase.
                return HarnessModelReply(text: reply)
            }
            let workflow = HarnessFeatureWorkflow(modelSession: session)
            _ = try await workflow.plan(
                request: brief.userRequest,
                repositorySummary: "src/feature.js and package.json in a disposable fixture"
            )
            let planningPhaseCount = recorder.phases.count
            return (HarnessWorkflowMaintainProvider(workflow: workflow), recorder, planningPhaseCount)
        }

        func postPlanningPhases(_ recorder: Recorder, after planningPhaseCount: Int) -> [HarnessRunTaskKind] {
            Array(recorder.phases.dropFirst(planningPhaseCount))
        }

        func assertRefusal(_ result: MaintainOnDemandEditResult, containing text: String) throws {
            guard case .couldNotComplete(let reason) = result else {
                throw CheckFailure(message: "expected refusal containing \(text), got \(result)")
            }
            try require(reason.contains(text), "refusal did not contain \(text): \(reason)")
        }

        // A review refusal must leave the exact staged candidate intact. The
        // provider saw only the independent review phase, never maker work.
        do {
            let fixture = try await makeFixture()
            defer { try? fileManager.removeItem(at: fixture.container) }
            try await stageSource(fixture)
            let before = try await snapshot(fixture)
            let (provider, recorder, planningPhaseCount) = try await makeProvider(
                reply: "ISSUE: deliberate inert refusal\nVERDICT: DISQUALIFYING"
            )
            let result = await MaintainSavedChangeRechecker.run(
                runner: fixture.runner,
                clonePath: fixture.runner.repoRootPath,
                appSlug: "fixture",
                appStack: .electron,
                changeId: "failed-review",
                request: brief.userRequest,
                provider: provider,
                derivedRecipe: recipe,
                isCurrent: { true },
                progress: nil,
                cancellation: { false }
            )
            try assertRefusal(result, containing: "not cleared")
            let phases = postPlanningPhases(recorder, after: planningPhaseCount)
            try require(phases == [.review], "failed review entered unexpected phases: \(phases)")
            try require(!phases.contains(.edit) && !phases.contains(.repair), "failed review entered maker work")
            try require(try await snapshot(fixture) == before,
                        "failed review changed HEAD, index, status or candidate files")
            print("PASS failed review preserves HEAD, index and files without maker calls")
        }

        // A caller-owned stale identity is refused before any diff review.
        do {
            let fixture = try await makeFixture()
            defer { try? fileManager.removeItem(at: fixture.container) }
            try await stageSource(fixture)
            let before = try await snapshot(fixture)
            let (provider, recorder, planningPhaseCount) = try await makeProvider(reply: "VERDICT: CLEAN")
            let result = await MaintainSavedChangeRechecker.run(
                runner: fixture.runner,
                clonePath: fixture.runner.repoRootPath,
                appSlug: "fixture",
                appStack: .electron,
                changeId: "stale",
                request: brief.userRequest,
                provider: provider,
                derivedRecipe: recipe,
                isCurrent: { false },
                progress: nil,
                cancellation: { false }
            )
            try assertRefusal(result, containing: "no longer matches")
            try require(postPlanningPhases(recorder, after: planningPhaseCount).isEmpty,
                        "stale candidate reached a model review")
            try require(try await snapshot(fixture) == before, "stale refusal changed the candidate")
            print("PASS stale candidate refuses before review and preserves source")
        }

        // Cancellation has the same source-preserving boundary, but reports
        // the reader stop rather than conflating it with stale identity.
        do {
            let fixture = try await makeFixture()
            defer { try? fileManager.removeItem(at: fixture.container) }
            try await stageSource(fixture)
            let before = try await snapshot(fixture)
            let (provider, recorder, planningPhaseCount) = try await makeProvider(reply: "VERDICT: CLEAN")
            let result = await MaintainSavedChangeRechecker.run(
                runner: fixture.runner,
                clonePath: fixture.runner.repoRootPath,
                appSlug: "fixture",
                appStack: .electron,
                changeId: "cancelled",
                request: brief.userRequest,
                provider: provider,
                derivedRecipe: recipe,
                isCurrent: { true },
                progress: nil,
                cancellation: { true }
            )
            try assertRefusal(result, containing: "stopped at your request")
            try require(postPlanningPhases(recorder, after: planningPhaseCount).isEmpty,
                        "cancelled candidate reached a model review")
            try require(try await snapshot(fixture) == before, "cancellation changed the candidate")
            print("PASS cancellation refuses before review and preserves source")
        }

        // Build-input edits are refused before the independent review. This
        // protects the confined build stage even when the command itself is
        // an otherwise harmless fixture command.
        do {
            let fixture = try await makeFixture()
            defer { try? fileManager.removeItem(at: fixture.container) }
            try await stageBuildInput(fixture)
            let before = try await snapshot(fixture)
            let (provider, recorder, planningPhaseCount) = try await makeProvider(reply: "VERDICT: CLEAN")
            let result = await MaintainSavedChangeRechecker.run(
                runner: fixture.runner,
                clonePath: fixture.runner.repoRootPath,
                appSlug: "fixture",
                appStack: .electron,
                changeId: "build-input",
                request: brief.userRequest,
                provider: provider,
                derivedRecipe: recipe,
                isCurrent: { true },
                progress: nil,
                cancellation: { false }
            )
            try assertRefusal(result, containing: "build-input files")
            try require(postPlanningPhases(recorder, after: planningPhaseCount).isEmpty,
                        "build-input candidate reached a model review")
            try require(try await snapshot(fixture) == before, "build-input refusal changed the candidate")
            print("PASS changed build inputs refuse before review")
        }

        // The no-suite/manual route may commit only after explicit code
        // admission. It still must not re-enter editing, and a second call on
        // its clean tree must not manufacture another commit or review call.
        do {
            let fixture = try await makeFixture()
            defer { try? fileManager.removeItem(at: fixture.container) }
            try await stageSource(fixture)
            let (provider, recorder, planningPhaseCount) = try await makeProvider(reply: "VERDICT: CLEAN")
            let result = await MaintainSavedChangeRechecker.run(
                runner: fixture.runner,
                clonePath: fixture.runner.repoRootPath,
                appSlug: "fixture",
                appStack: .electron,
                changeId: "manual-clean",
                request: brief.userRequest,
                provider: provider,
                derivedRecipe: recipe,
                isCurrent: { true },
                progress: nil,
                cancellation: { false }
            )
            guard case .appliedAndRebuilt(let branch, _, let kind, let suitePassed, _) = result else {
                throw CheckFailure(message: "manual clean candidate was not committed: \(result)")
            }
            try require(kind == .feature && suitePassed == nil, "manual clean route reported the wrong delivery lane")
            try require(branch == "iris/edit-fixture", "manual clean commit did not preserve the saved branch")
            try require(postPlanningPhases(recorder, after: planningPhaseCount) == [.review],
                        "manual clean route entered maker work or skipped review")
            let committedHead = try await output(fixture, "git rev-parse --verify HEAD^{commit}")
            try require(committedHead != fixture.baselineHead, "manual clean route did not create a commit")
            try require((try await output(fixture, "git status --porcelain")).isEmpty,
                        "manual clean route left the fixture dirty")

            let phasesBeforeRepeat = recorder.phases
            let repeated = await MaintainSavedChangeRechecker.run(
                runner: fixture.runner,
                clonePath: fixture.runner.repoRootPath,
                appSlug: "fixture",
                appStack: .electron,
                changeId: "manual-clean-repeat",
                request: brief.userRequest,
                provider: provider,
                derivedRecipe: recipe,
                isCurrent: { true },
                progress: nil,
                cancellation: { false }
            )
            try assertRefusal(repeated, containing: "no changed source")
            try require(recorder.phases == phasesBeforeRepeat,
                        "repeated clean candidate called the model again")
            try require(try await output(fixture, "git rev-parse --verify HEAD^{commit}") == committedHead,
                        "repeated clean candidate created a second commit")
            print("PASS manual clean route uses one review, no maker calls and no repeated commit")
        }
    }
}

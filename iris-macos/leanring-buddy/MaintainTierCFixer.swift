//
//  MaintainTierCFixer.swift
//  leanring-buddy
//
//  The last rung: no pooled recipe fit, the user confirmed the bug, and they
//  brought their own model access. A bounded, mini-swe-agent-shaped loop
//  derives a fix from scratch, then it faces the SAME verification gate every
//  other fix does — a novel fix earns no special trust for being clever.
//
//  The SAME loop also drives the user-initiated on-demand editor: a person
//  picks an app, says what they want changed (a bug fix or a feature), and the
//  request slots into the exact place the crash evidence would. That is the
//  whole point of the `MaintainEditTask` abstraction below — one jailed loop,
//  one `.git` strip/restore, one verify/commit tail, two ways in. The crash
//  path is unchanged; it just now expresses itself as a `.crashFix` task.
//
//  Deliberately small and deliberately caged:
//    - BYO/OpenAI only (the funded proxy structurally can't run this, and its
//      budget couldn't sustain it — Agentless-shaped novel fixes still cost
//      ~15x a replay).
//    - A hard step cap. An agent that hasn't found it in a dozen jailed
//      commands is not about to.
//    - Every command runs in the Seatbelt jail: writes confined to the repo,
//      no network. Fetch-and-run and exfiltration are off the table during
//      exploration; the network-needing build happens after, outside the
//      jail, through the ordinary runner.
//    - `.git` is stripped before the loop and restored after, so a clone
//      that already contains the upstream fix cannot be mined for the answer.
//    - Text ReAct, no tool-calling API: the model replies with ONE fenced
//      bash block or DONE. Simple to cap, simple to parse, provider-portable.
//

import CryptoKit
import Foundation

/// What the Tier C loop is being asked to do. The crash path constructs
/// `.crashFix`; the user-initiated editor constructs `.onDemand`. The prompt
/// pair (system + opening) is built entirely from this — it is the single
/// de-coupling that lets one loop serve both a crash artifact and a free-text
/// request without the loop knowing which it is.
enum MaintainEditTask: Sendable {
    /// The frozen, scrubbed crash-artifact tail — the loop's only description
    /// of the bug, on the incident path.
    case crashFix(evidence: String)
    /// A free-text, already-scrubbed user request, tagged as a bug fix or a
    /// feature so the prompt, the commit trailer, and the honesty tier all
    /// stay correct.
    case onDemand(request: String, kind: OnDemandEditKind)
}

/// Whether an on-demand request is a bug fix or a new feature. Drives the
/// prompt wording, the `Change-Kind` trailer, and — critically — the status
/// language downstream: a feature is NEVER labeled "verified" (see
/// `attemptOnDemandEdit`).
enum OnDemandEditKind: Sendable {
    case bugFix
    case feature
}

enum MaintainTierCResult: Sendable {
    case fixedAndVerified(branchName: String, wasNovel: Bool)
    case couldNotFix(reason: String)
    case notEligible(reason: String)
}

/// The outcome of a user-initiated on-demand edit. It deliberately has NO
/// "verified" case: the on-demand loop always runs with `reproCommand` nil, so
/// it can only ever earn `earnsCleanApply` — it is "applied and rebuilt",
/// never "verified", and a feature is never elevated past that. The
/// coordinator maps these to honest status copy.
enum MaintainOnDemandEditResult: Sendable {
    /// Applied, built, and (when the stack has a suite) suite-green, then
    /// committed on `branchName`. `suitePassed` is nil when the stack has no
    /// test command — surfaced honestly, never counted as a silent green.
    case appliedAndRebuilt(branchName: String, changeId: String, kind: OnDemandEditKind, suitePassed: Bool?)
    /// The loop ran but produced no committable, verified change — out of
    /// steps, changed nothing, edited a build-script file, or failed
    /// verification. `reason` is user-safe.
    case couldNotComplete(reason: String)
    /// A precondition failed before the loop even started (no sandbox, an
    /// unusable clone path).
    case notEligible(reason: String)
}

@MainActor
final class MaintainTierCFixer {

    static let maximumLoopSteps = 12
    static let maximumOutputTokensPerStep = 1200

    private let provider: MaintainModelProviding

    init(provider: MaintainModelProviding) {
        self.provider = provider
    }

    // MARK: - Change identity

    /// The on-demand analog of a crash `signatureId`: a per-attempt key from
    /// the app, the normalized request, and the moment. Load-bearing in the
    /// branch name and any PatchQueue record. Mirrors the composite shape of
    /// `MaintainFeatureRequests.signature`, but WITH a timestamp — re-running
    /// the same request is a distinct edit and must not collide on a branch.
    /// The caller passes an already-normalized request, same convention as the
    /// feature-request pooling path.
    static func synthesizedChangeId(
        appSlug: String, normalizedRequest: String, at date: Date = Date()
    ) -> String {
        let composite = "\(appSlug)|on-demand|\(normalizedRequest)|\(date.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(composite.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).lowercased()
    }

    // MARK: - Entry points

    /// Attempt a novel fix in a source-clone repo. `crashEvidence` is the
    /// frozen, scrubbed artifact tail — the model's only description of the
    /// bug, hashed and timestamped by the caller before this runs.
    ///
    /// Behavior is unchanged from before the on-demand generalization: it just
    /// expresses the work as a `.crashFix` task and keeps the crash-path
    /// branch prefix (`iris/fix-`), changeId (the signature), and trailer
    /// vocabulary exactly as they were.
    func attemptFix(
        clonePath: String,
        appSlug: String,
        appStack: BreakAppStack,
        signatureId: String,
        crashEvidence: String,
        // A testability seam: the adversarial harness supplies its own
        // build/test vocabulary so it can prove the loop end-to-end without a
        // real cargo/npm project. Production always uses the per-stack default.
        verificationCommandsOverride: VerificationCommands? = nil
    ) async -> MaintainTierCResult {
        let outcome = await runEditLoopVerifyAndCommit(
            task: .crashFix(evidence: crashEvidence),
            changeId: signatureId,
            clonePath: clonePath,
            appSlug: appSlug,
            appStack: appStack,
            branchPrefix: "iris/fix-",
            // The crash path is unchanged: it does not add the on-demand
            // build-script block, so its behavior is byte-for-byte what it was.
            blockBuildScriptEdits: false,
            commitVocabulary: { suitePassed in
                (
                    subject: "Novel fix for \(appSlug)",
                    trailerLines: [
                        "Break-Signature: \(signatureId)",
                        "Fix-Recipe-Match: novel",
                        "Verified: build-green\(suitePassed == true ? ", suite-green" : "")",
                        "Assisted-by: iris-maintain-mode/1 (tier-c, \(self.provider.displayName))",
                        "Modified-by: Iris (publik) — derived a novel fix under your own model key",
                    ]
                )
            },
            verificationCommandsOverride: verificationCommandsOverride
        )
        switch outcome {
        case .committed(let branchName, _):
            return .fixedAndVerified(branchName: branchName, wasNovel: true)
        case .couldNotFix(let reason):
            return .couldNotFix(reason: reason)
        case .notEligible(let reason):
            return .notEligible(reason: reason)
        }
    }

    /// A user-initiated on-demand edit — the SAME jailed loop, `.git`
    /// strip/restore, verification, and commit tail the crash path runs,
    /// driven by a free-text request instead of a crash artifact. `request` is
    /// already secret/PII-scrubbed by the caller. `changeId` is the
    /// caller-synthesized key (see `synthesizedChangeId`), load-bearing in the
    /// branch name and any PatchQueue record.
    ///
    /// This path runs with `reproCommand` nil, so it can only ever earn a
    /// clean-apply — it is "applied and rebuilt", never "verified", and a
    /// feature is never elevated past that. There is deliberately no parameter
    /// that would let a caller supply a model-authored acceptance test to
    /// promote a feature to the verified tier.
    func attemptOnDemandEdit(
        clonePath: String,
        appSlug: String,
        appStack: BreakAppStack,
        changeId: String,
        request: String,
        kind: OnDemandEditKind,
        // When false (the default), a model edit to a build-script file is a
        // HARD block, applied BEFORE the un-jailed verification build could run
        // it. The coordinator may pass true only after an explicit user
        // approval of that specific risk.
        allowBuildScriptEdits: Bool = false,
        verificationCommandsOverride: VerificationCommands? = nil
    ) async -> MaintainOnDemandEditResult {
        let changeKindTrailer = kind == .feature ? "on-demand-feature" : "on-demand-bug-fix"
        let outcome = await runEditLoopVerifyAndCommit(
            task: .onDemand(request: request, kind: kind),
            changeId: changeId,
            clonePath: clonePath,
            appSlug: appSlug,
            appStack: appStack,
            branchPrefix: "iris/edit-",
            blockBuildScriptEdits: !allowBuildScriptEdits,
            commitVocabulary: { suitePassed in
                (
                    subject: kind == .feature
                        ? "On-demand feature for \(appSlug)"
                        : "On-demand fix for \(appSlug)",
                    trailerLines: [
                        "Change-Id: \(changeId)",
                        "Change-Kind: \(changeKindTrailer)",
                        // NEVER "Verified:" here — an on-demand edit has no
                        // repro oracle, so the honest claim is "applied", not
                        // "verified". The word choice is load-bearing.
                        "Applied: build-green\(suitePassed == true ? ", suite-green" : "")",
                        "Assisted-by: iris-maintain-mode/1 (tier-c, on-demand, \(self.provider.displayName))",
                        "Modified-by: Iris (publik) — implemented a user-requested change under your own model key",
                    ]
                )
            },
            verificationCommandsOverride: verificationCommandsOverride
        )
        switch outcome {
        case .committed(let branchName, let suitePassed):
            return .appliedAndRebuilt(
                branchName: branchName, changeId: changeId, kind: kind, suitePassed: suitePassed
            )
        case .couldNotFix(let reason):
            return .couldNotComplete(reason: reason)
        case .notEligible(let reason):
            return .notEligible(reason: reason)
        }
    }

    // MARK: - The shared loop / verify / commit spine

    /// The internal outcome both public entries translate into their own
    /// result vocabulary. Keeps the loop, the revert-on-failure rules, and the
    /// commit in exactly one place.
    private enum EditLoopOutcome {
        case committed(branchName: String, suitePassed: Bool?)
        case couldNotFix(reason: String)
        case notEligible(reason: String)
    }

    /// The one jailed loop → `.git` restore → optional build-script block →
    /// verification → commit spine. Parameterized only by the task (which
    /// builds the prompts), the change identity, the branch prefix, whether to
    /// block build-script edits, and the commit vocabulary. `commitVocabulary`
    /// is handed the suite result because only its `Verified:`/`Applied:` line
    /// depends on it.
    private func runEditLoopVerifyAndCommit(
        task: MaintainEditTask,
        changeId: String,
        clonePath: String,
        appSlug: String,
        appStack: BreakAppStack,
        branchPrefix: String,
        blockBuildScriptEdits: Bool,
        commitVocabulary: (_ suitePassed: Bool?) -> (subject: String, trailerLines: [String]),
        verificationCommandsOverride: VerificationCommands?
    ) async -> EditLoopOutcome {
        guard MaintainSandbox.isAvailable else {
            return .notEligible(reason: "the sandbox is unavailable on this machine")
        }
        guard let runner = try? MaintainShellRunner(repoRootPath: clonePath) else {
            return .notEligible(reason: "the clone path is not usable")
        }

        // Strip .git so the agent cannot read history to retrieve the fix,
        // and so its edits don't accidentally commit mid-loop. Restored in
        // every exit path below. Keyed by the generic changeId (the crash
        // signature or the synthesized request hash) so two concurrent loops
        // never collide on the backup path.
        let gitBackup = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-git-backup-\(changeId.prefix(8))")
        _ = try? await runner.run(
            "rm -rf '\(gitBackup)'; mv .git '\(gitBackup)' 2>/dev/null || true", deadline: 60
        )
        func restoreGit() async {
            _ = try? await runner.run(
                "rm -rf .git 2>/dev/null; mv '\(gitBackup)' .git 2>/dev/null || true", deadline: 60
            )
        }

        var conversation: [MaintainChatTurn] = [
            MaintainChatTurn(role: "user", text: Self.openingMessage(appSlug: appSlug, task: task)),
        ]

        var declaredDone = false
        for step in 1...Self.maximumLoopSteps {
            let reply: String
            do {
                reply = try await provider.respond(
                    systemPrompt: Self.systemPrompt(for: task),
                    conversation: conversation,
                    maximumOutputTokens: Self.maximumOutputTokensPerStep
                )
            } catch {
                await restoreGit()
                return .couldNotFix(reason: "model call failed: \(error.localizedDescription)")
            }
            conversation.append(MaintainChatTurn(role: "assistant", text: reply))

            if reply.range(of: #"(?m)^\s*DONE\s*$"#, options: .regularExpression) != nil {
                declaredDone = true
                break
            }
            guard let command = Self.extractBashCommand(from: reply) else {
                conversation.append(MaintainChatTurn(
                    role: "user",
                    text: "Reply with exactly one ```bash fenced command, or DONE on its own line."
                ))
                continue
            }
            guard let jailed = MaintainSandbox.jailedInvocation(
                forCommand: command, repoRootPath: clonePath
            ) else {
                await restoreGit()
                return .couldNotFix(reason: "could not build the sandbox for a command")
            }
            defer { try? FileManager.default.removeItem(atPath: jailed.profilePath) }
            let result = try? await runner.run(jailed.invocation, deadline: 120)
            let output = String((result?.outputTail ?? "(no output)").suffix(4000))
            irisTrace("maintain: tier-c step \(step) ran a jailed command, exit=\(result?.exitCode ?? -1)")
            conversation.append(MaintainChatTurn(
                role: "user",
                text: "Command exit \(result?.exitCode ?? -1). Output:\n\(output)\n\nNext command, or DONE."
            ))
        }

        // The loop made its edits with no network; verification (build+suite)
        // needs the network and runs outside the jail through the ordinary
        // runner. .git is back, so a passing tree can be committed.
        await restoreGit()

        guard declaredDone else {
            _ = try? await runner.run("git checkout -- . && git clean -fd --quiet", deadline: 120)
            return .couldNotFix(reason: "ran out of steps without a fix")
        }

        // Did the agent actually change anything?
        let dirty = try? await runner.run("git status --porcelain", deadline: 30)
        guard (dirty?.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) else {
            return .couldNotFix(reason: "the agent declared done but changed nothing")
        }

        // On-demand only: a model edit to a build-script file (build.rs,
        // package.json scripts, Makefile, …) would run un-jailed and networked
        // during the verification build below — a jail escape. Catch it HERE,
        // before that build, and revert. The crash path passes false and is
        // unchanged.
        if blockBuildScriptEdits {
            let changedPaths = await Self.changedFilePaths(runner: runner)
            let buildScriptEdits = MaintainBuildScriptGuard.buildScriptFilePaths(inChangedPaths: changedPaths)
            if !buildScriptEdits.isEmpty {
                _ = try? await runner.run("git checkout -- . && git clean -fd --quiet", deadline: 120)
                irisTrace("maintain: on-demand edit BLOCKED — touched build-script file(s)")
                return .couldNotFix(
                    reason: "the change edits build-script files (\(buildScriptEdits.joined(separator: ", "))) that run during an unjailed build — blocked before building"
                )
            }
        }

        let commands = verificationCommandsOverride
            ?? VerificationCommands.defaults(for: appStack, repoRootPath: clonePath)
        let verification = await VerificationHarness.verifyAppliedPatch(
            runner: runner, commands: commands, reproCommand: nil
        )
        guard verification.earnsCleanApply else {
            _ = try? await runner.run("git checkout -- . && git clean -fd --quiet", deadline: 120)
            return .couldNotFix(
                reason: "the fix failed verification (\(verification.blockedStage ?? "unknown"))"
            )
        }

        let vocabulary = commitVocabulary(verification.suitePassed)
        let branchName = await MaintainFixCommit.commitOnBranch(
            plan: MaintainFixCommitPlan(
                branchPrefix: branchPrefix,
                changeId: changeId,
                subject: vocabulary.subject,
                trailerLines: vocabulary.trailerLines
            ),
            runner: runner
        )
        irisTrace("maintain: tier-c committed a change on \(branchName)")
        return .committed(branchName: branchName, suitePassed: verification.suitePassed)
    }

    /// The change's touched paths — tracked changes against HEAD plus untracked
    /// new files — for the build-script guard. Mirrors the pair of git queries
    /// `enforceDiffScope` uses, so the two see the same set of files.
    private static func changedFilePaths(runner: MaintainShellRunner) async -> [String] {
        func linesFrom(_ command: String) async -> [String] {
            guard let result = try? await runner.run(command, deadline: 60) else { return [] }
            return result.outputTail
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let tracked = await linesFrom("git diff --name-only HEAD")
        let untracked = await linesFrom("git ls-files --others --exclude-standard")
        return tracked + untracked
    }

    // MARK: - Prompt and parsing

    /// The system prompt for a bug fix — the incident path AND an on-demand
    /// bug-fix request. Kept verbatim from before the on-demand generalization.
    private static let bugFixSystemPrompt = """
    You are fixing a bug in a local checkout of an open-source app. You work \
    in a sandbox: writes are confined to this repository, and there is NO \
    network — so you cannot fetch anything or run a build that downloads \
    dependencies. Explore and edit only.

    Each turn, reply with EXACTLY ONE command in a ```bash fenced block, and \
    nothing else. Read files, grep, and edit in place (sed, or write a file \
    with a heredoc). Make the SMALLEST change that fixes the reported \
    problem — do not refactor, do not touch unrelated files, do not weaken or \
    delete tests. When you believe the bug is fixed, reply with DONE on its \
    own line and nothing else. A verification build and the full test suite \
    run automatically after you say DONE; you do not run them yourself.
    """

    /// The system prompt for an on-demand feature request. Same jail and DONE
    /// mechanics; the standard is "implement the smallest version of the
    /// requested feature", not "fix the reported problem".
    private static let featureSystemPrompt = """
    You are adding a small, user-requested feature to a local checkout of an \
    open-source app. You work in a sandbox: writes are confined to this \
    repository, and there is NO network — so you cannot fetch anything or run \
    a build that downloads dependencies. Explore and edit only.

    Each turn, reply with EXACTLY ONE command in a ```bash fenced block, and \
    nothing else. Read files, grep, and edit in place (sed, or write a file \
    with a heredoc). Make the SMALLEST change that implements the requested \
    feature — follow the app's existing patterns, do not refactor unrelated \
    code, do not touch files the feature does not need, and do not weaken or \
    delete tests. When you believe the feature is implemented, reply with \
    DONE on its own line and nothing else. A verification build and the full \
    test suite run automatically after you say DONE; you do not run them \
    yourself.
    """

    private static func systemPrompt(for task: MaintainEditTask) -> String {
        switch task {
        case .crashFix, .onDemand(_, .bugFix):
            return bugFixSystemPrompt
        case .onDemand(_, .feature):
            return featureSystemPrompt
        }
    }

    private static func openingMessage(appSlug: String, task: MaintainEditTask) -> String {
        switch task {
        case .crashFix(let evidence):
            return """
            App: \(appSlug). It failed with this evidence (a crash report tail, \
            already scrubbed of personal data):

            \(String(evidence.prefix(3000)))

            Find the cause in the code and fix it. Start by locating the relevant \
            source.
            """
        case .onDemand(let request, .bugFix):
            return """
            App: \(appSlug). A user of this app reported a bug and asked Iris to \
            fix it. In their words:

            \(String(request.prefix(3000)))

            Find the cause in the code and fix it. Start by locating the relevant \
            source.
            """
        case .onDemand(let request, .feature):
            return """
            App: \(appSlug). A user of this app asked Iris to add a feature. In \
            their words:

            \(String(request.prefix(3000)))

            Implement it as a small, self-contained change that follows the app's \
            existing patterns. Start by locating the relevant source.
            """
        }
    }

    static func extractBashCommand(from reply: String) -> String? {
        guard let fenceStart = reply.range(of: "```bash") ?? reply.range(of: "```sh")
            ?? reply.range(of: "```") else { return nil }
        let afterFence = reply[fenceStart.upperBound...]
        guard let fenceEnd = afterFence.range(of: "```") else { return nil }
        let body = afterFence[..<fenceEnd.lowerBound]
        let command = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}

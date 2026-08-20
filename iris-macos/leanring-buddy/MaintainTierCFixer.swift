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

    // Raised from 12 to the researched ~15–20 band (plan §6, decision 6c: the
    // reader pays via their own CLI login, so the richer loop is affordable). The
    // step cap is no longer the ONLY governor — the no-progress detector and the
    // action-dedup below stop a spinning loop well before it burns the cap.
    static let maximumLoopSteps = 20
    static let maximumOutputTokensPerStep = 1200

    /// Stop the loop when the working tree has gone unchanged for this many
    /// CONSECUTIVE steps AFTER the model has begun editing (plan §6 no-progress
    /// detector). Exploration BEFORE the first edit is expected and never counts —
    /// a fix that reads many files before writing must not be killed for it — so
    /// this only bites once the agent is actually mutating the tree and then
    /// stalls, which is the real "spinning" signal.
    static let noProgressStepThreshold = 5

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
            // The crash path keeps its exact verify/commit identity: it derives
            // no Feature-Engine recipe (it still verifies through
            // VerificationCommands.defaults), injects no runtime-shape addendum,
            // and offers no model-authored build-command escape hatch. Only the
            // on-demand Feature Engine opts into those.
            deriveFeatureEngineRecipe: false,
            modelAuthoredBuildCommand: nil,
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
        // Decision 1b (opt-in, OFF by default). A build command the MODEL authored
        // — permitted only after the reader's extra, every-time explicit approval
        // in the coordinator. When non-nil it is screened by the SAME
        // catastrophe/risk classifier the autopilot uses BEFORE it can run
        // un-jailed; a command that trips the gate is surfaced and the edit is
        // abandoned, never run. nil (the default) keeps the code-adjudicated
        // recipe as the only source of the un-jailed build command, so the default
        // behavior is unchanged.
        modelAuthoredBuildCommand: String? = nil,
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
            // The on-demand path IS the Feature Engine: derive a per-repo recipe
            // (plan §4) for the post-DONE verification and the runtime-shape
            // preflight addendum (plan §8), and honor the opt-in model-authored
            // build command (decision 1b).
            deriveFeatureEngineRecipe: true,
            modelAuthoredBuildCommand: modelAuthoredBuildCommand,
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
        // Feature Engine switches (plan §4/§8), both OFF for the crash path so its
        // verify/commit identity stays byte-for-byte. When
        // `deriveFeatureEngineRecipe` is true the loop derives a per-repo recipe
        // from DECLARATIVE signals, injects the runtime-shape preflight addendum,
        // and verifies through the recipe's build/test (falling back to
        // VerificationCommands.defaults). `modelAuthoredBuildCommand`, when non-nil,
        // is the decision-1b escape hatch, screened by the risk classifier before
        // it can run un-jailed.
        deriveFeatureEngineRecipe: Bool,
        modelAuthoredBuildCommand: String?,
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

        // Feature Engine recipe (plan §4/§8), on-demand only so the crash path's
        // verify/commit identity is untouched. Derived from DECLARATIVE repo
        // signals (manifests, CI workflows) — never model-authored — and read here
        // BEFORE the loop edits, since its build/test vocabulary and runtime shape
        // come from config files the edit is not permitted to change (the
        // build-script guard). `.git` is already stripped, but the recipe reads
        // manifests and `.github/workflows`, not `.git`, so it is unaffected.
        let derivedFeatureEngineRecipe: RepoRecipe? = deriveFeatureEngineRecipe
            ? RepoRecipeService.deriveRecipe(repoRootPath: clonePath)
            : nil

        // The offline repo map (plan §6): a cheap, model-call-free symbol summary
        // that helps the agent localize code and grounds it against hallucinated
        // APIs. It is CONTEXT ONLY — it changes no safety behavior, no branch, and
        // no trailer — so injecting it leaves the jail/.git-strip/restore/verify/
        // commit spine (and the crash path's identity) byte-for-byte intact. It is
        // "" for a repo with no recognized declarations, in which case the opening
        // message is exactly what it was.
        let repoMapSummary = FeatureEditRepoMap.summarize(repoRootPath: clonePath)

        // The runtime-shape preflight addendum (plan §8) is on-demand only: it
        // tells the codegen model, up front, to write idempotent / crash-safe /
        // tenant-scoped / flag-gated code appropriate to how THIS app runs. The
        // crash path derives no recipe, so it adds nothing here.
        let runtimeShapePreflightAddendum: String? = derivedFeatureEngineRecipe.map { recipe in
            FeatureEditRuntimeChecklist.preflightPromptAddendum(forRuntimeShape: recipe.runtimeShape)
        }

        var conversation: [MaintainChatTurn] = [
            MaintainChatTurn(role: "user", text: Self.openingMessage(
                appSlug: appSlug,
                task: task,
                repoMapSummary: repoMapSummary,
                runtimeShapePreflightAddendum: runtimeShapePreflightAddendum
            )),
        ]

        // Loop governance OUTSIDE the model (plan §6): action-dedup and a
        // no-progress detector. Both can only STOP EARLY or SKIP a duplicate —
        // never turn a successful outcome into a failure — so the spine is intact.
        // `commandsAlreadyRun` holds every exact command the model has already run;
        // the fingerprint tracks whether the working tree is actually advancing.
        var commandsAlreadyRun: Set<String> = []
        var workingTreeFingerprintFromPreviousStep = Self.workingTreeFingerprint(repoRootPath: clonePath)
        var theModelHasEditedTheTreeAtLeastOnce = false
        var consecutiveNoProgressStepCount = 0

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

            // Action-dedup (plan §6): the model already ran this EXACT command, so
            // re-running it would only spin. Skip it and steer toward something
            // new. The step still counts, so a model that keeps repeating itself is
            // still bounded by the step cap.
            if commandsAlreadyRun.contains(command) {
                irisTrace("maintain: tier-c skipped a repeated identical command at step \(step)")
                conversation.append(MaintainChatTurn(
                    role: "user",
                    text: "You already ran that exact command earlier and its result has not changed. Run a DIFFERENT command that makes progress, or reply DONE."
                ))
                continue
            }
            commandsAlreadyRun.insert(command)

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

            // No-progress detector (plan §6). A fingerprint that CHANGED means the
            // model edited the tree — real progress — so the counter resets and we
            // remember that editing has begun. A fingerprint UNCHANGED after the
            // model has already started editing is a stall; enough consecutive
            // stalls and we stop rather than burn the whole step budget spinning.
            // Pure read/inspect steps before the first edit are expected and never
            // counted, so a fix that explores widely before writing is not killed.
            if let latestFingerprint = Self.workingTreeFingerprint(repoRootPath: clonePath) {
                if let previousFingerprint = workingTreeFingerprintFromPreviousStep,
                   latestFingerprint != previousFingerprint {
                    theModelHasEditedTheTreeAtLeastOnce = true
                    consecutiveNoProgressStepCount = 0
                } else if theModelHasEditedTheTreeAtLeastOnce {
                    consecutiveNoProgressStepCount += 1
                }
                workingTreeFingerprintFromPreviousStep = latestFingerprint

                if consecutiveNoProgressStepCount >= Self.noProgressStepThreshold {
                    irisTrace("maintain: tier-c stopping early — no working-tree progress for \(consecutiveNoProgressStepCount) steps")
                    break
                }
            }
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

        // Select the verification vocabulary (plan §4/§5). Precedence:
        //   1. an explicit test override (the adversarial harness's seam) — wins,
        //      so the existing engine tests keep exercising exactly what they pass.
        //   2. the derived Feature-Engine recipe's build/test — on-demand, when it
        //      resolved something the coarse per-stack default would have missed.
        //      This is what retires the "unknown stack" refusal for real repos.
        //   3. the code-authored VerificationCommands.defaults — the crash path's
        //      unchanged source, and the on-demand fallback when the recipe found
        //      nothing (never DOWNGRADE a working default to an empty recipe).
        var commands: VerificationCommands
        if let verificationCommandsOverride {
            commands = verificationCommandsOverride
        } else {
            commands = VerificationCommands.defaults(for: appStack, repoRootPath: clonePath)
            if let derivedFeatureEngineRecipe {
                let recipeCommands = Self.verificationCommands(fromDerivedRecipe: derivedFeatureEngineRecipe)
                if recipeCommands.buildCommand != nil || recipeCommands.testCommand != nil {
                    commands = recipeCommands
                }
            }
        }

        // Decision 1b (opt-in): a model-authored build command may run un-jailed
        // ONLY after passing the SAME catastrophe/risk classifier the autopilot
        // uses. `autonomyGranted: false` demands the FULL three-tier scrutiny, so a
        // command that is anything other than plainly safe (catastrophe, curl|sh,
        // sudo, rm -rf, a system-folder write, obfuscation, …) is rejected and the
        // edit is abandoned — the dangerous string is never run. Absent (nil) the
        // default behavior is untouched, and an explicit test override is never
        // overridden by this escape hatch.
        if let modelAuthoredBuildCommand, verificationCommandsOverride == nil {
            guard case .runsWithoutAsking = GuideAutopilotRiskAssessment.assess(
                modelAuthoredBuildCommand, autonomyGranted: false
            ) else {
                _ = try? await runner.run("git checkout -- . && git clean -fd --quiet", deadline: 120)
                irisTrace("maintain: on-demand model-authored build command REJECTED by the risk classifier")
                return .couldNotFix(
                    reason: "the model-authored build command was rejected by the safety classifier and was not run"
                )
            }
            commands = VerificationCommands(
                buildCommand: modelAuthoredBuildCommand,
                testCommand: commands.testCommand,
                commandSubdirectory: commands.commandSubdirectory
            )
        }

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

    // MARK: - Feature Engine helpers (plan §4/§6)

    /// Map a derived `RepoRecipe` (plan §4) onto the harness's build/test
    /// vocabulary. The un-jailed verification build runs a build command then a
    /// test command, so:
    ///   - buildCommand = the recipe's build, or its install when there is no
    ///     compile step (interpreted stacks are install-but-no-build, and a clean
    ///     `install` is the meaningful build-level check for them).
    ///   - testCommand  = the recipe's test (nil = no suite, honestly skipped —
    ///     never a silent green).
    /// `VerificationCommands` carries a SINGLE working subdirectory for both legs,
    /// so the build/install command's subdirectory is used, falling back to the
    /// test command's — the common case where build and test share a directory.
    // TODO(iris-feature-engine): a monorepo whose build and test live in DIFFERENT
    // subdirectories is not captured by this single-subdirectory flattening;
    // thread per-command subdirectories through the harness to verify each leg in
    // its own directory.
    private static func verificationCommands(fromDerivedRecipe recipe: RepoRecipe) -> VerificationCommands {
        let buildOrInstallCommand = recipe.build ?? recipe.install
        return VerificationCommands(
            buildCommand: buildOrInstallCommand?.commandLine,
            testCommand: recipe.test?.commandLine,
            commandSubdirectory: buildOrInstallCommand?.workingSubdirectory
                ?? recipe.test?.workingSubdirectory
        )
    }

    /// Directory names the no-progress fingerprint never descends into:
    /// dependency caches and build outputs are GENERATED, not authored, so a build
    /// the model never touched must not make the tree look "changed" — and walking
    /// node_modules/target every step would make the "cheap" fingerprint anything
    /// but. Dot-directories are skipped separately below, which additionally
    /// excludes the temporary `.git` backup and Iris's own `.iris` notes.
    private static let fingerprintIgnoredDirectoryNames: Set<String> = [
        "node_modules", "target", "build", "dist", "out",
        "vendor", "Pods", "DerivedData", "__pycache__", "coverage",
    ]

    /// A cheap, in-process fingerprint of the working tree's AUTHORED files — the
    /// state hash behind the plan §6 no-progress detector. It folds each file's
    /// repo-relative path, byte size, and modification time into a SHA-256 (NOT
    /// the full file contents, which would be far heavier), so it changes whenever
    /// the model writes, grows, or deletes a file and stays identical across pure
    /// read/inspect steps. Generated/dependency directories, dot-directories, and
    /// symlinks are skipped so a stray build output never reads as progress, the
    /// walk stays fast and bounded, and no link can walk it out of the clone.
    /// Returns nil only when the repo root is unreadable, which the caller treats
    /// as "unknown — do not arm the detector".
    private static func workingTreeFingerprint(repoRootPath: String) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: repoRootPath) else { return nil }

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]

        // A generous ceiling that keeps a pathological tree from turning the
        // per-step fingerprint into an unbounded scan (the same reasoning as the
        // repo map's own file-scan limit).
        let fileScanLimit = 20_000

        var hasher = SHA256()
        var scannedFileCount = 0
        var directoryStack: [(url: URL, relativePath: String)] = [
            (URL(fileURLWithPath: repoRootPath), ""),
        ]

        while let currentDirectory = directoryStack.popLast() {
            guard let entryURLs = try? fileManager.contentsOfDirectory(
                at: currentDirectory.url,
                includingPropertiesForKeys: resourceKeys,
                options: []
            ) else { continue }

            // Sort by name so the fold order is deterministic for the same tree —
            // otherwise an unchanged tree could hash differently between steps.
            let sortedEntryURLs = entryURLs.sorted { leftURL, rightURL in
                leftURL.lastPathComponent < rightURL.lastPathComponent
            }

            for entryURL in sortedEntryURLs {
                let entryName = entryURL.lastPathComponent
                let entryRelativePath = currentDirectory.relativePath.isEmpty
                    ? entryName
                    : currentDirectory.relativePath + "/" + entryName

                let resourceValues = try? entryURL.resourceValues(forKeys: Set(resourceKeys))

                // Never follow a symlink (cycle + escape guard).
                if resourceValues?.isSymbolicLink == true { continue }

                if resourceValues?.isDirectory == true {
                    // Skip dot-directories (covers `.git`, `.iris`, tooling caches)
                    // and the generated/dependency directories above.
                    if entryName.hasPrefix(".")
                        || fingerprintIgnoredDirectoryNames.contains(entryName) { continue }
                    directoryStack.append((url: entryURL, relativePath: entryRelativePath))
                    continue
                }

                // A regular file (including a root-level dotfile like `.env`):
                // fold its identity + size + mtime into the running hash.
                let byteSize = resourceValues?.fileSize ?? 0
                let modificationTime = resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? 0
                hasher.update(data: Data("\(entryRelativePath)|\(byteSize)|\(modificationTime)\n".utf8))

                scannedFileCount += 1
                if scannedFileCount >= fileScanLimit {
                    let digest = hasher.finalize()
                    return digest.map { String(format: "%02x", $0) }.joined()
                }
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
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

    /// The opening user turn. Composed of the original task-driven message
    /// (`baseOpeningMessage`, unchanged) plus, appended around it, the offline
    /// repo map (plan §6, context only) and — on-demand only — the runtime-shape
    /// preflight addendum (plan §8). Both extras are additive context: they alter
    /// no branch, trailer, gate, or the verify/commit spine, and an empty repo map
    /// / nil addendum reproduce the original message exactly.
    private static func openingMessage(
        appSlug: String,
        task: MaintainEditTask,
        repoMapSummary: String,
        runtimeShapePreflightAddendum: String?
    ) -> String {
        var sections: [String] = [baseOpeningMessage(appSlug: appSlug, task: task)]

        if !repoMapSummary.isEmpty {
            sections.append("""
            Repo map (an offline, heuristic symbol summary to help you locate \
            code — always confirm the real declaration at the call site before you \
            rely on it):

            \(repoMapSummary)
            """)
        }

        if let runtimeShapePreflightAddendum, !runtimeShapePreflightAddendum.isEmpty {
            sections.append(runtimeShapePreflightAddendum)
        }

        return sections.joined(separator: "\n\n")
    }

    /// The original task-driven opening message, kept verbatim — factored out so
    /// the enriched `openingMessage` above can append the repo map and runtime
    /// addendum around it without disturbing this wording. The crash path receives
    /// only the context-only repo map (no runtime addendum), and its safety
    /// identity — branch, trailers, gates, verify/commit — is unchanged.
    private static func baseOpeningMessage(appSlug: String, task: MaintainEditTask) -> String {
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

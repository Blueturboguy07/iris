//
//  MaintainTierCFixer.swift
//  leanring-buddy
//
//  The last rung: no pooled recipe fit, the user confirmed the bug, and they
//  brought their own model access. A bounded, mini-swe-agent-shaped loop
//  derives a fix from scratch, then it faces the SAME verification gate every
//  other fix does — a novel fix earns no special trust for being clever.
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

import Foundation

enum MaintainTierCResult: Sendable {
    case fixedAndVerified(branchName: String, wasNovel: Bool)
    case couldNotFix(reason: String)
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

    /// Attempt a novel fix in a source-clone repo. `crashEvidence` is the
    /// frozen, scrubbed artifact tail — the model's only description of the
    /// bug, hashed and timestamped by the caller before this runs.
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
        guard MaintainSandbox.isAvailable else {
            return .notEligible(reason: "the sandbox is unavailable on this machine")
        }
        guard let runner = try? MaintainShellRunner(repoRootPath: clonePath) else {
            return .notEligible(reason: "the clone path is not usable")
        }

        // Strip .git so the agent cannot read history to retrieve the fix,
        // and so its edits don't accidentally commit mid-loop. Restored in
        // every exit path below.
        let gitBackup = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-git-backup-\(signatureId.prefix(8))")
        _ = try? await runner.run(
            "rm -rf '\(gitBackup)'; mv .git '\(gitBackup)' 2>/dev/null || true", deadline: 60
        )
        func restoreGit() async {
            _ = try? await runner.run(
                "rm -rf .git 2>/dev/null; mv '\(gitBackup)' .git 2>/dev/null || true", deadline: 60
            )
        }

        var conversation: [MaintainChatTurn] = [
            MaintainChatTurn(role: "user", text: Self.openingMessage(
                appSlug: appSlug, crashEvidence: crashEvidence
            )),
        ]

        var declaredDone = false
        for step in 1...Self.maximumLoopSteps {
            let reply: String
            do {
                reply = try await provider.respond(
                    systemPrompt: Self.systemPrompt,
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

        let dateStamp = Self.compactDateStamp()
        let branchName = "iris/fix-\(signatureId.prefix(12))-\(dateStamp)"
        let commitMessage = "Novel fix for \(appSlug)\n\n"
            + "Break-Signature: \(signatureId)\n"
            + "Fix-Recipe-Match: novel\n"
            + "Verified: build-green\(verification.suitePassed == true ? ", suite-green" : "")\n"
            + "Assisted-by: iris-maintain-mode/1 (tier-c, \(provider.displayName))\n"
            + "Modified-by: Iris (publik) — derived a novel fix under your own model key"
        let commitScript = "git checkout -b '\(branchName)' 2>/dev/null || git checkout '\(branchName)'; "
            + "git add -A && git commit -m '\(commitMessage.replacingOccurrences(of: "'", with: "'\\''"))' --quiet"
        _ = try? await runner.run(commitScript, deadline: 60)
        irisTrace("maintain: tier-c committed a novel fix on \(branchName)")
        return .fixedAndVerified(branchName: branchName, wasNovel: true)
    }

    // MARK: - Prompt and parsing

    private static let systemPrompt = """
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

    private static func openingMessage(appSlug: String, crashEvidence: String) -> String {
        """
        App: \(appSlug). It failed with this evidence (a crash report tail, \
        already scrubbed of personal data):

        \(String(crashEvidence.prefix(3000)))

        Find the cause in the code and fix it. Start by locating the relevant \
        source.
        """
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

    private static func compactDateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}

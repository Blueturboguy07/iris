import Foundation

/// Verifies an already-applied on-demand feature without re-entering the
/// maker loop. The caller owns the Test project registration, clone lock and
/// accepted workflow. This type only performs the existing verification,
/// independent-review and commit stages against that current candidate.
@MainActor
enum MaintainSavedChangeRechecker {

    /// A stop here does not revert the candidate. The source was supplied by a
    /// prior run and belongs to the reader's checked recovery path.
    static let stoppedReason =
        "saved change recheck stopped at your request; source remains for review"

    /// A registration, revision or other caller-owned identity check failed.
    /// The candidate is deliberately left untouched for the recovery card.
    static let staleReason =
        "saved change recheck no longer matches the current project; source remains for review"

    /// Recheck a dirty Test-policy feature candidate. No command in this path
    /// resets, stashes, cleans or otherwise reverts the working tree. A model
    /// call can occur only for the fresh independent review stages.
    static func run(
        runner: MaintainShellRunner,
        clonePath: String,
        appSlug: String,
        appStack: BreakAppStack,
        changeId: String,
        request: String,
        provider: HarnessWorkflowMaintainProvider,
        derivedRecipe: RepoRecipe?,
        isCurrent: @escaping @MainActor () async -> Bool,
        progress: MaintainTierCProgressHandler?,
        cancellation: MaintainTierCCancellationCheck?
    ) async -> MaintainOnDemandEditResult {
        let kind: OnDemandEditKind = .feature
        let task = MaintainEditTask.onDemand(request: request, kind: kind)

        guard IrisTestEnvironment.isEnabled,
              runner.isTestProcessPolicy,
              MaintainSandbox.isAvailable else {
            return .notEligible(reason: "saved feature recheck requires the Iris Test process policy")
        }
        guard runner.repoRootPath == clonePath else {
            return .notEligible(reason: "saved feature recheck clone identity is not canonical")
        }
        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return await identityFailure(isCurrent: isCurrent, cancellation: cancellation)
        }

        var commands = MaintainTierCFixer.resolvedVerificationCommands(
            override: nil,
            appStack: appStack,
            repoRootPath: clonePath,
            derivedRecipe: derivedRecipe
        )
        guard commands.buildCommand != nil else {
            return .couldNotComplete(
                reason: "saved feature recheck has no resolved build command; source remains for review"
            )
        }
        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return await identityFailure(isCurrent: isCurrent, cancellation: cancellation)
        }

        let nativeVerification: IrisTestVerificationPlan.Captured?
        do {
            nativeVerification = try IrisTestVerificationPlan.capture(
                repoRootPath: clonePath,
                commands: commands
            )
        } catch {
            return .couldNotComplete(
                reason: "the declared desktop verification plan is not current; source remains for review"
            )
        }
        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return await identityFailure(isCurrent: isCurrent, cancellation: cancellation)
        }

        if let nativeVerification {
            guard nativeVerification.isCurrent(),
                  let confinedCommands = nativeVerification.declaration.confinedCommands(from: commands) else {
                return .couldNotComplete(
                    reason: "the declared desktop verification plan changed; source remains for review"
                )
            }
            commands = confinedCommands
        }
        guard commands.buildCommand != nil else {
            return .couldNotComplete(
                reason: "the current verification plan has no real build command; source remains for review"
            )
        }

        provider.configureReviewStages(nativeChecksRequired: nativeVerification != nil)

        guard let candidatePaths = await readChangedPaths(
            runner: runner,
            isCurrent: isCurrent,
            cancellation: cancellation
        ) else {
            return await stageFailure(
                isCurrent: isCurrent,
                cancellation: cancellation,
                fallback: "Iris could not read the saved candidate's changed paths; source remains for review"
            )
        }
        guard !candidatePaths.isEmpty else {
            return .couldNotComplete(
                reason: "the saved candidate has no changed source to verify; source remains for review"
            )
        }
        let buildInputPaths = MaintainBuildScriptGuard.buildScriptFilePaths(
            inChangedPaths: candidatePaths
        )
        guard buildInputPaths.isEmpty else {
            return .couldNotComplete(
                reason: "the saved candidate edits build-input files ("
                    + buildInputPaths.joined(separator: ", ")
                    + "); source remains for review"
            )
        }

        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return await identityFailure(isCurrent: isCurrent, cancellation: cancellation)
        }
        guard let fullDiff = await MaintainTierCFixer.reviewDiffIncludingNewFiles(
            runner: runner,
            repoRootPath: clonePath
        ), !fullDiff.isEmpty else {
            return await stageFailure(
                isCurrent: isCurrent,
                cancellation: cancellation,
                fallback: "Iris could not read the saved candidate's complete diff; source remains for review"
            )
        }
        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return await identityFailure(isCurrent: isCurrent, cancellation: cancellation)
        }

        let reviewPurpose = MaintainTierCFixer.reviewPurposeForIndependentReview(
            task: task,
            isTestApplication: IrisTestEnvironment.isEnabled,
            isTestProcessPolicy: runner.isTestProcessPolicy,
            hasDeclaredNativeVerification: nativeVerification != nil,
            hasResolvedTestCommand: commands.testCommand != nil
        )

        progress?(.verifyingTheChange(
            buildCommand: commands.buildCommand,
            testCommand: commands.testCommand
        ))
        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return await identityFailure(isCurrent: isCurrent, cancellation: cancellation)
        }
        var verification = await VerificationHarness.verifyAppliedPatch(
            runner: runner,
            commands: commands,
            reproCommand: nil,
            runtimeShape: derivedRecipe?.runtimeShape
        )
        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return await identityFailure(isCurrent: isCurrent, cancellation: cancellation)
        }

        if !verification.earnsCleanApply {
            progress?(.verificationCompleted(receipt: verification.editReceipt))
            return .couldNotComplete(
                reason: "the saved candidate failed verification at "
                    + (verification.blockedStage ?? "an unknown stage")
                    + "; source remains for review"
            )
        }

        var currentReviewFindings: String?
        // Short-lived provenance from clean code admission to the final native
        // behavior review. It is cleared on a new admission or any rejection.
        var nativeAdmissionEvidence: HarnessNativeVerificationSequence.NativeAdmissionEvidence?
        func performReview(
            purpose: HarnessReviewPurpose,
            verificationEvidence: [String],
            isNativeFinalReview: Bool = false
        ) async -> AdversarialVerdict? {
            currentReviewFindings = nil
            if purpose == .nativeCodeAdmission {
                nativeAdmissionEvidence = nil
            }
            guard !isNativeFinalReview || purpose == .ordinaryBehaviorCoverage else {
                nativeAdmissionEvidence = nil
                return nil
            }
            guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
                return nil
            }

            guard let reviewDiff = await MaintainTierCFixer.reviewDiffIncludingNewFiles(
                runner: runner,
                repoRootPath: clonePath
            ), !reviewDiff.isEmpty else {
                return nil
            }
            guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
                return nil
            }

            let reviewPaths = await readChangedPaths(
                runner: runner,
                isCurrent: isCurrent,
                cancellation: cancellation
            ) ?? []
            guard !reviewPaths.isEmpty else { return nil }
            let changedTestPaths = reviewPaths.filter {
                $0.contains(".test.") || $0.contains(".spec.") || $0.contains("/tests/")
            }
            let declaredNativeTestPaths = HarnessNativeVerificationSequence.reviewContextNativePaths(
                purpose: purpose,
                protectedPaths: nativeVerification.map {
                    Array($0.declaration.native.protectedFileSHA256.keys)
                } ?? [],
                clonePath: clonePath
            )
            let changedDirectories = Set(
                reviewPaths.map { ($0 as NSString).deletingLastPathComponent }
            )
            let mappedSourcePaths = FeatureEditRepoMap.buildFileSymbolSummaries(
                repoRootPath: clonePath,
                fileScanLimit: 100
            ).map(\.repoRelativePath)
            let neighbors = mappedSourcePaths.filter {
                changedDirectories.contains(($0 as NSString).deletingLastPathComponent)
            }
            let repositoryContext = FeatureEditRepositoryContext.collectReviewContext(
                repoRootPath: clonePath,
                changedTestPaths: changedTestPaths,
                declaredNativeTestPaths: declaredNativeTestPaths,
                changedPaths: reviewPaths,
                sameDirectoryNeighborPaths: neighbors,
                candidateSourcePaths: mappedSourcePaths,
                isNativeFinalReview: isNativeFinalReview,
                maxFileCount: 24,
                maxBytes: 64 * 1024
            )
            let suppliedFiles: [String: String] = Dictionary(uniqueKeysWithValues: repositoryContext.files.map {
                ($0.repoRelativePath, $0.utf8Text)
            })
            let finalReviewInstructions: String?
            if isNativeFinalReview {
                guard let evidence = nativeAdmissionEvidence,
                      let prompt = evidence.matchingPrompt(
                          forDiff: reviewDiff,
                          repoRootPath: clonePath
                      )
                else {
                    nativeAdmissionEvidence = nil
                    return nil
                }
                finalReviewInstructions = prompt
            } else {
                finalReviewInstructions = nil
            }
            let revision = HarnessFrozenComparison.digest(Data(reviewDiff.utf8))
            let nativeCommand = nativeVerification.map {
                "\nSeparately declared native argv: " + $0.declaration.native.executablePath
                    + " " + $0.declaration.native.arguments.joined(separator: " ")
            } ?? ""
            let suitePassed = purpose == .ordinaryBehaviorCoverage
                && verification.suite == .passed
            provider.prepareBehaviorReview(
                revision: revision,
                suitePassed: suitePassed,
                testCommand: (commands.testCommand ?? "No confined command") + nativeCommand,
                suppliedFiles: suppliedFiles,
                reviewPurpose: purpose
            )
            let review = MaintainTierCFixer.reviewPrompt(
                request: request,
                kind: kind,
                unifiedDiff: MaintainTierCFixer.boundedReviewDiff(reviewDiff),
                evidenceLog: verificationEvidence,
                repositoryContext: repositoryContext
            )
            progress?(.runningAdversarialReview)
            guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
                return nil
            }
            provider.setHarnessPhase(.review)
            guard let reply = try? await provider.respond(
                systemPrompt: review.system
                    + (finalReviewInstructions.map { "\n" + $0 }
                        ?? (purpose == .nativeCodeAdmission
                            ? "\n" + HarnessNativeVerificationSequence.admissionInstructions
                            : "")),
                conversation: [MaintainChatTurn(role: "user", text: review.user + nativeCommand)],
                maximumOutputTokens: MaintainTierCFixer.maximumOutputTokensPerAdversarialReview
            ) else {
                guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
                    return nil
                }
                currentReviewFindings = "the independent review could not be run"
                progress?(.adversarialReviewRaisedIssues(
                    issues: ["the independent review could not be run"]
                ))
                return AdversarialVerdict(
                    isDisqualifying: true,
                    issues: ["the independent review could not be run"]
                )
            }
            guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
                return nil
            }
            let verdict = FeatureEditAdversarialReviewer.parse(reply: reply)
            if verdict.isDisqualifying {
                nativeAdmissionEvidence = nil
                let readerFindings = verdict.readerFacingIssues.map {
                    GuideAutopilotOutputBuffer.scrubbed(
                        GuideAutopilotOutputBuffer.strippedOfControlSequences($0)
                    )
                }
                let findings = readerFindings.isEmpty
                    ? ["the independent review did not clear the saved candidate"]
                    : readerFindings
                currentReviewFindings = findings.joined(separator: "; ")
                progress?(.adversarialReviewRaisedIssues(issues: findings))
            } else if isNativeFinalReview {
                guard let evidence = nativeAdmissionEvidence,
                      evidence.matchingPrompt(forDiff: reviewDiff, repoRootPath: clonePath) != nil
                else {
                    nativeAdmissionEvidence = nil
                    return nil
                }
            } else if purpose == .nativeCodeAdmission {
                guard let evidence = HarnessNativeVerificationSequence.NativeAdmissionEvidence.capture(
                    diff: reviewDiff,
                    context: repositoryContext
                ), evidence.matchingPrompt(forDiff: reviewDiff, repoRootPath: clonePath) != nil else {
                    nativeAdmissionEvidence = nil
                    return nil
                }
                nativeAdmissionEvidence = evidence
            }
            return verdict
        }

        let initialVerdict = await performReview(
            purpose: reviewPurpose,
            verificationEvidence: verification.evidenceLog
        )
        guard let initialVerdict else {
            return await stageFailure(
                isCurrent: isCurrent,
                cancellation: cancellation,
                fallback: "the saved candidate's independent review could not be completed; source remains for review"
            )
        }
        guard !initialVerdict.isDisqualifying else {
            verification.blockedStage = reviewPurpose == .nativeCodeAdmission
                ? "native-review-required"
                : "independent-review"
            verification.blockedOutputTail = currentReviewFindings
            progress?(.verificationCompleted(receipt: verification.editReceipt))
            return .couldNotComplete(
                reason: "the saved candidate was not cleared by independent review; source remains for review"
            )
        }

        let reviewedDiff = await MaintainTierCFixer.reviewDiffIncludingNewFiles(
            runner: runner,
            repoRootPath: clonePath
        )
        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return await identityFailure(isCurrent: isCurrent, cancellation: cancellation)
        }
        guard let reviewedDiff, !reviewedDiff.isEmpty else {
            return .couldNotComplete(
                reason: "the saved candidate diff disappeared before native checks; source remains for review"
            )
        }
        let admittedRevision = HarnessFrozenComparison.digest(Data(reviewedDiff.utf8))

        if let nativeVerification {
            guard let evidence = nativeAdmissionEvidence,
                  evidence.matchingPrompt(forDiff: reviewedDiff, repoRootPath: clonePath) != nil else {
                return .couldNotComplete(reason:
                    "the saved candidate changed after code admission; source remains for review")
            }
            verification.confinedSuite = verification.suite
            guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
                return await identityFailure(isCurrent: isCurrent, cancellation: cancellation)
            }
            let nativeOutcome = await HarnessNativeVerificationSequence.run(
                admittedRevision: admittedRevision,
                isCancelled: { cancellation?() == true },
                registrationIsCurrent: { nativeVerification.isCurrent() },
                currentRevision: {
                    await MaintainTierCFixer.reviewDiffIncludingNewFiles(
                        runner: runner,
                        repoRootPath: clonePath
                    ).map { HarnessFrozenComparison.digest(Data($0.utf8)) }
                },
                runDeclaredChecks: {
                    progress?(.verifyingTheChange(
                        buildCommand: nil,
                        testCommand: "Declared desktop checks (native launch)"
                    ))
                    guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
                        throw CancellationError()
                    }
                    return try await nativeVerification.run(cancellationCheck: cancellation)
                },
                finalReview: { result in
                    verification.evidenceLog.append(
                        "Declared native desktop suite: exit 0 on unchanged reviewed source. Native launch is not OS-contained.\n"
                            + String(GuideAutopilotOutputBuffer.scrubbed(result.outputTail).suffix(2_048))
                    )
                    guard let finalVerdict = await performReview(
                        purpose: .ordinaryBehaviorCoverage,
                        verificationEvidence: verification.evidenceLog,
                        isNativeFinalReview: true
                    ) else {
                        return false
                    }
                    guard !finalVerdict.isDisqualifying else { return false }
                    var evidence = verification.verificationEvidence ?? VerificationEvidence()
                    evidence.adversarialReviewClean = true
                    evidence.adversarialReviewCleanEvidence =
                        "an independent reviewer named no disqualifying problem after the declared native checks"
                    verification.verificationEvidence = evidence
                    verification.verificationRung =
                        FeatureEditVerificationLadder.highestEarnedRung(from: evidence)
                    verification.evidenceLog.append(contentsOf: evidence.evidenceLogLines())
                    return true
                }
            )
            guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
                return await identityFailure(isCurrent: isCurrent, cancellation: cancellation)
            }
            verification.suite = nativeOutcome.suite
            verification.nativeSuite = nativeOutcome.suite
            verification.blockedStage = nativeOutcome.blockedStage
            verification.blockedOutputTail = nativeOutcome.detail
            if let findings = currentReviewFindings,
               nativeOutcome.blockedStage == "native-final-review" {
                verification.blockedOutputTail = findings
            }
            if verification.blockedStage != nil {
                verification.verificationRung = nil
                verification.verificationEvidence = nil
                progress?(.verificationCompleted(receipt: verification.editReceipt))
                return .couldNotComplete(
                    reason: "the saved candidate failed declared desktop verification; source remains for review"
                )
            }
            guard provider.behaviorAssessment?.permitsAutomaticDelivery(
                forRevision: admittedRevision
            ) == true else {
                verification.blockedStage = "behavior-coverage"
                verification.blockedOutputTail =
                    "the final independent review did not establish every requested behavior"
                progress?(.verificationCompleted(receipt: verification.editReceipt))
                return .couldNotComplete(
                    reason: "the saved candidate lacks reviewed behavior coverage; source remains for review"
                )
            }
        } else if reviewPurpose == .ordinaryBehaviorCoverage {
            guard provider.behaviorAssessment?.permitsAutomaticDelivery(
                forRevision: admittedRevision
            ) == true else {
                verification.blockedStage = "behavior-coverage"
                verification.blockedOutputTail =
                    "the independent review did not establish every requested behavior"
                progress?(.verificationCompleted(receipt: verification.editReceipt))
                return .couldNotComplete(
                    reason: "the saved candidate lacks reviewed behavior coverage; source remains for review"
                )
            }
            var evidence = verification.verificationEvidence ?? VerificationEvidence()
            evidence.adversarialReviewClean = true
            evidence.adversarialReviewCleanEvidence =
                "an independent reviewer named no disqualifying problem"
            verification.verificationEvidence = evidence
            verification.verificationRung =
                FeatureEditVerificationLadder.highestEarnedRung(from: evidence)
            verification.evidenceLog.append(contentsOf: evidence.evidenceLogLines())
        } else {
            guard provider.behaviorAssessment?.manualCodeAdmissionClean == true else {
                verification.blockedStage = "manual-code-admission"
                verification.blockedOutputTail =
                    currentReviewFindings ?? "manual code admission was not explicitly cleared"
                progress?(.verificationCompleted(receipt: verification.editReceipt))
                return .couldNotComplete(
                    reason: "the saved candidate was not cleared for manual testing; source remains for review"
                )
            }
        }

        if verification.blockedStage != nil || !verification.earnsCleanApply {
            progress?(.verificationCompleted(receipt: verification.editReceipt))
            return .couldNotComplete(
                reason: "the saved candidate did not complete verification; source remains for review"
            )
        }
        if let earnedRung = verification.verificationRung {
            progress?(.verificationLadderEarned(
                rung: earnedRung,
                evidenceLog: verification.evidenceLog
            ))
        }
        progress?(.verificationCompleted(receipt: verification.editReceipt))

        guard let finalPaths = await readChangedPaths(
            runner: runner,
            isCurrent: isCurrent,
            cancellation: cancellation
        ) else {
            return await stageFailure(
                isCurrent: isCurrent,
                cancellation: cancellation,
                fallback: "Iris could not recheck the saved candidate before commit; source remains for review"
            )
        }
        guard MaintainBuildScriptGuard.buildScriptFilePaths(inChangedPaths: finalPaths).isEmpty else {
            return .couldNotComplete(
                reason: "the saved candidate changed a build-input file before commit; source remains for review"
            )
        }
        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return await identityFailure(isCurrent: isCurrent, cancellation: cancellation)
        }
        guard let finalDiff = await MaintainTierCFixer.reviewDiffIncludingNewFiles(
            runner: runner,
            repoRootPath: clonePath
        ), !finalDiff.isEmpty else {
            return await stageFailure(
                isCurrent: isCurrent,
                cancellation: cancellation,
                fallback: "the saved candidate diff could not be confirmed before commit; source remains for review"
            )
        }
        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return await identityFailure(isCurrent: isCurrent, cancellation: cancellation)
        }
        guard HarnessFrozenComparison.digest(Data(finalDiff.utf8)) == admittedRevision else {
            return .couldNotComplete(
                reason: "the saved candidate changed after review; source remains for review"
            )
        }

        progress?(.committingTheChange)
        let suiteLabel = verification.suite == .passed ? ", suite-green" : ""
        let trailerLines = [
            "Change-Id: \(changeId)",
            "Change-Kind: on-demand-feature",
            "Applied: build-green\(suiteLabel)",
            "Assisted-by: iris-maintain-mode/1 (tier-c, on-demand, \(provider.displayName))",
            "Modified-by: Iris (publik) - implemented a user-requested change under your own model key",
        ]
        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return await identityFailure(isCurrent: isCurrent, cancellation: cancellation)
        }
        let branchName = await MaintainFixCommit.commitOnBranch(
            plan: MaintainFixCommitPlan(
                branchPrefix: "iris/edit-",
                changeId: changeId,
                subject: "On-demand feature for \(appSlug)",
                trailerLines: trailerLines
            ),
            runner: runner,
            preservingCurrentBranch: true,
            validateBeforeCommit: {
                await currentGate(isCurrent: isCurrent, cancellation: cancellation)
            }
        )
        guard let branchName else {
            return .couldNotComplete(
                reason: "Iris could not save the saved feature as a version. Source changes remain for review; the installed app was not updated."
            )
        }
        // A post-commit stop or registry change cannot truthfully turn an
        // already-created commit into a refusal. Observe the state, then
        // report the commit fact and let the caller's delivery gate decide.
        _ = await currentGate(isCurrent: isCurrent, cancellation: cancellation)
        return .appliedAndRebuilt(
            branchName: branchName,
            changeId: changeId,
            kind: kind,
            suitePassed: verification.suitePassed,
            symptomVerifiedByRepro: false
        )
    }

    private static func currentGate(
        isCurrent: @escaping @MainActor () async -> Bool,
        cancellation: MaintainTierCCancellationCheck?
    ) async -> Bool {
        guard cancellation?() != true else { return false }
        return await isCurrent()
    }

    private static func identityFailure(
        isCurrent: @escaping @MainActor () async -> Bool,
        cancellation: MaintainTierCCancellationCheck?
    ) async -> MaintainOnDemandEditResult {
        if cancellation?() == true {
            return .couldNotComplete(reason: stoppedReason)
        }
        _ = await isCurrent()
        return .couldNotComplete(reason: staleReason)
    }

    private static func stageFailure(
        isCurrent: @escaping @MainActor () async -> Bool,
        cancellation: MaintainTierCCancellationCheck?,
        fallback: String
    ) async -> MaintainOnDemandEditResult {
        if cancellation?() == true {
            return .couldNotComplete(reason: stoppedReason)
        }
        guard await isCurrent() else {
            return .couldNotComplete(reason: staleReason)
        }
        return .couldNotComplete(reason: fallback)
    }

    private static func readChangedPaths(
        runner: MaintainShellRunner,
        isCurrent: @escaping @MainActor () async -> Bool,
        cancellation: MaintainTierCCancellationCheck?
    ) async -> [String]? {
        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return nil
        }
        guard let tracked = try? await runner.run("git diff --name-only HEAD", deadline: 60),
              tracked.succeeded,
              tracked.bytesDroppedBeforeTail == 0 else {
            return nil
        }
        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return nil
        }
        guard let untracked = try? await runner.run(
            "git ls-files --others --exclude-standard",
            deadline: 60
        ), untracked.succeeded, untracked.bytesDroppedBeforeTail == 0 else {
            return nil
        }
        guard await currentGate(isCurrent: isCurrent, cancellation: cancellation) else {
            return nil
        }
        func lines(_ result: MaintainCommandResult) -> [String] {
            result.outputTail
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return lines(tracked) + lines(untracked)
    }
}

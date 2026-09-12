import Foundation
@testable import IrisHarnessNative

private enum CandidatePolicyCheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Pure policy checks for the Iris Test manual-candidate lane. These checks do
/// not create a coordinator, touch a registry, run a build, or install an app.
@main
struct CandidatePolicyChecks {
    @MainActor static func main() {
        do {
            try run()
            print("CANDIDATE POLICY CHECKS PASS: 7 groups")
        } catch {
            print("CANDIDATE POLICY CHECKS FAIL: " + String(describing: error))
            exit(1)
        }
    }

    @MainActor private static func run() throws {
        try checkCleanNoSuiteCandidateIsAllowed()
        try checkEnvironmentAndRegistryGates()
        try checkVerificationGates()
        try checkReviewAndRevisionGates()
        try checkManualCodeAdmissionContract()
        try checkSourceAndStopGates()
        try checkBuildToolPreflightCommand()
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CandidatePolicyCheckError.failed(message) }
    }

    private static func cleanReceipt() -> EditVerificationReceipt {
        EditVerificationReceipt(
            buildPassed: true,
            testsPassed: nil,
            confinedTestsPassed: nil,
            nativeTestsPassed: nil,
            nativeTestsRequired: false,
            symptomReproduced: false,
            failureStage: nil,
            failureOutputTail: nil
        )
    }

    private static func cleanAssessment(
        revision: String = "reviewed-revision"
    ) -> HarnessBehaviorAssessment {
        HarnessBehaviorAssessment(
            revision: revision,
            supported: [],
            pending: [],
            reviewWasClean: false,
            suitePassed: false,
            protocolIssue: nil,
            reviewIssues: [],
            manualCodeAdmissionClean: true
        )
    }

    private static func allows(
        isFeature: Bool = true,
        isTestApplication: Bool = true,
        isExactRegisteredProject: Bool = true,
        hasDeclaredNativeVerification: Bool = false,
        hasResolvedTestCommand: Bool = false,
        suitePassed: Bool? = nil,
        verificationReceipt: EditVerificationReceipt? = cleanReceipt(),
        assessment: HarnessBehaviorAssessment? = cleanAssessment(),
        currentRevision: String? = "reviewed-revision",
        sourceIdentityMatches: Bool = true,
        stopRequested: Bool = false
    ) -> Bool {
        OnDemandEditCoordinator.unverifiedTestCandidatePasses(
            isFeature: isFeature,
            isTestApplication: isTestApplication,
            isExactRegisteredProject: isExactRegisteredProject,
            hasDeclaredNativeVerification: hasDeclaredNativeVerification,
            hasResolvedTestCommand: hasResolvedTestCommand,
            suitePassed: suitePassed,
            verificationReceipt: verificationReceipt,
            assessment: assessment,
            currentRevision: currentRevision,
            sourceIdentityMatches: sourceIdentityMatches,
            stopRequested: stopRequested
        )
    }

    private static func checkCleanNoSuiteCandidateIsAllowed() throws {
        try require(allows(), "a clean Iris Test build with no suite was rejected")
        print("PASS clean no-suite candidate policy")
    }

    private static func checkEnvironmentAndRegistryGates() throws {
        try require(!allows(isFeature: false), "a bug-fix result entered the feature-only lane")
        try require(!allows(isTestApplication: false), "normal Iris was allowed to offer a candidate")
        try require(!allows(isExactRegisteredProject: false), "a changed registry project was allowed")
        try require(!allows(hasDeclaredNativeVerification: true), "a native-verification project was allowed")
        try require(!allows(hasResolvedTestCommand: true), "a project with a test command was allowed")
        print("PASS environment, registry, native and suite gates")
    }

    private static func checkVerificationGates() throws {
        try require(!allows(suitePassed: true), "a suite-passed result entered the no-suite lane")
        try require(!allows(verificationReceipt: nil), "a missing receipt was treated as a clean build")
        try require(!allows(verificationReceipt: EditVerificationReceipt()), "a receipt with no executed stage was allowed")
        try require(!allows(verificationReceipt: EditVerificationReceipt(buildPassed: nil, testsPassed: nil)),
                    "a missing build result was allowed")
        try require(!allows(verificationReceipt: EditVerificationReceipt(buildPassed: false, testsPassed: nil)),
                    "a failed build was allowed")
        try require(!allows(verificationReceipt: EditVerificationReceipt(buildPassed: true, testsPassed: false)),
                    "a failed suite was allowed")
        try require(!allows(verificationReceipt: EditVerificationReceipt(
            buildPassed: true, testsPassed: nil, confinedTestsPassed: true
        )), "a confined suite result was allowed")
        try require(!allows(verificationReceipt: EditVerificationReceipt(
            buildPassed: true, testsPassed: nil, nativeTestsPassed: true, nativeTestsRequired: true
        )), "a native suite result was allowed")
        try require(!allows(verificationReceipt: EditVerificationReceipt(
            buildPassed: true, testsPassed: nil, failureStage: "build"
        )), "a receipt with failure evidence was allowed")
        print("PASS verification and receipt gates")
    }

    private static func checkReviewAndRevisionGates() throws {
        try require(!allows(assessment: nil), "a missing review was allowed")
        try require(!allows(assessment: HarnessBehaviorAssessment(
            revision: "reviewed-revision", supported: [], pending: [], reviewWasClean: false,
            suitePassed: false, protocolIssue: nil, reviewIssues: []
        )), "a dirty review was allowed")
        try require(!allows(assessment: HarnessBehaviorAssessment(
            revision: "reviewed-revision", supported: [], pending: [], reviewWasClean: true,
            suitePassed: false, protocolIssue: "malformed", reviewIssues: []
        )), "a review protocol issue was allowed")
        try require(!allows(assessment: HarnessBehaviorAssessment(
            revision: "reviewed-revision", supported: [], pending: [], reviewWasClean: true,
            suitePassed: false, protocolIssue: nil, reviewIssues: ["finding"]
        )), "review findings were allowed with a clean flag")
        try require(!allows(assessment: HarnessBehaviorAssessment(
            revision: "reviewed-revision", supported: [], pending: [], reviewWasClean: true,
            suitePassed: true, protocolIssue: nil, reviewIssues: []
        )), "a suite-backed assessment entered the no-suite lane")
        try require(!allows(assessment: HarnessBehaviorAssessment(
            revision: "reviewed-revision", supported: [], pending: [], reviewWasClean: false,
            suitePassed: false, protocolIssue: nil, reviewIssues: []
        )), "a missing manual code-admission flag was allowed")
        try require(!allows(assessment: HarnessBehaviorAssessment(
            revision: "reviewed-revision", supported: [], pending: [], reviewWasClean: true,
            suitePassed: false, protocolIssue: nil, reviewIssues: [],
            manualCodeAdmissionClean: true
        )), "behavior-clean state was allowed as manual admission")
        try require(!allows(assessment: HarnessBehaviorAssessment(
            revision: "reviewed-revision", supported: [], pending: [], reviewWasClean: false,
            suitePassed: false, protocolIssue: nil, reviewIssues: ["finding"],
            manualCodeAdmissionClean: true
        )), "manual admission with review findings was allowed")
        try require(!allows(currentRevision: "different-revision"), "a changed diff digest was allowed")
        try require(!allows(currentRevision: nil), "a missing diff digest was allowed")
        try require(!allows(assessment: cleanAssessment(revision: ""), currentRevision: ""),
                    "an empty reviewed revision was allowed")
        print("PASS review, protocol and exact revision gates")
    }

    private static func checkManualCodeAdmissionContract() throws {
        let prompt = HarnessBehaviorAssessment.manualTestCodeAdmissionInstructions
        try require(prompt.contains("MANUAL TEST CODE ADMISSION"),
                    "manual review prompt omitted its explicit purpose")
        try require(prompt.contains("behavior") && prompt.contains("pending"),
                    "manual review prompt did not keep behavior pending")
        try require(prompt.contains("any ISSUE or INSUFFICIENT marker still blocks"),
                    "manual review prompt weakened the fail-closed marker contract")

        let replies = [
            "ISSUE: unsafe write\nVERDICT: CLEAN",
            "INSUFFICIENT: missing source\nVERDICT: CLEAN",
            "INSUFFICIENT:\nVERDICT: CLEAN",
            "not a verdict"
        ]
        for reply in replies {
            try require(
                FeatureEditAdversarialReviewer.parse(reply: reply).isDisqualifying,
                "manual review refusal did not fail closed: " + reply
            )
        }

        let criteria = [HarnessAcceptanceCriterion(id: "launch", statement: "The feature is reachable")]
        let assessment = HarnessBehaviorAssessment.assess(
            reply: "COVERED: launch | test/feature.test.js | reaches feature\nVERDICT: CLEAN",
            criteria: criteria,
            revision: "manual-revision",
            suitePassed: false,
            reviewWasClean: false,
            suppliedTestFiles: ["test/feature.test.js": "reaches feature"],
            manualCodeAdmissionClean: true
        )
        try require(assessment.manualCodeAdmissionClean == true,
                    "clean manual code admission was not recorded")
        try require(!assessment.reviewWasClean && !assessment.suitePassed,
                    "manual admission was credited as behavior review")
        try require(assessment.supported.isEmpty && assessment.pending == criteria,
                    "manual admission fabricated behavior coverage")
        try require(!assessment.permitsAutomaticDelivery,
                    "manual admission enabled automatic delivery")

        let legacyJSON = """
        {"revision":"legacy","supported":[],"pending":[],"reviewWasClean":false,"suitePassed":false,"protocolIssue":null,"reviewIssues":[]}
        """
        let legacy = try JSONDecoder().decode(
            HarnessBehaviorAssessment.self, from: Data(legacyJSON.utf8)
        )
        try require(legacy.manualCodeAdmissionClean == nil,
                    "legacy assessment did not fail closed for missing manual state")
        let encoded = try JSONEncoder().encode(assessment)
        let roundTrip = try JSONDecoder().decode(HarnessBehaviorAssessment.self, from: encoded)
        try require(roundTrip.manualCodeAdmissionClean == true,
                    "manual admission state was lost during persistence")

        let manualPurpose = MaintainTierCFixer.reviewPurposeForIndependentReview(
            task: .onDemand(request: "add feature", kind: .feature),
            isTestApplication: true,
            isTestProcessPolicy: true,
            hasDeclaredNativeVerification: false,
            hasResolvedTestCommand: false
        )
        try require(manualPurpose == .manualTestCodeAdmission,
                    "eligible Test no-suite feature did not select manual admission")
        try require(
            MaintainTierCFixer.reviewPurposeForIndependentReview(
                task: .onDemand(request: "add feature", kind: .feature),
                isTestApplication: true,
                isTestProcessPolicy: false,
                hasDeclaredNativeVerification: false,
                hasResolvedTestCommand: false
            ) == .ordinaryBehaviorCoverage,
            "an unconfined runner entered the manual admission lane"
        )
        try require(
            MaintainTierCFixer.reviewPurposeForIndependentReview(
                task: .onDemand(request: "fix", kind: .bugFix),
                isTestApplication: true,
                isTestProcessPolicy: true,
                hasDeclaredNativeVerification: false,
                hasResolvedTestCommand: false
            ) == .ordinaryBehaviorCoverage,
            "Test bug fix entered the manual feature lane"
        )
        try require(
            MaintainTierCFixer.reviewPurposeForIndependentReview(
                task: .onDemand(request: "add feature", kind: .feature),
                isTestApplication: true,
                isTestProcessPolicy: true,
                hasDeclaredNativeVerification: true,
                hasResolvedTestCommand: false
            ) == .nativeCodeAdmission,
            "native feature lane was changed to manual admission"
        )
        try require(
            MaintainTierCFixer.reviewPurposeForIndependentReview(
                task: .onDemand(request: "add feature", kind: .feature),
                isTestApplication: true,
                isTestProcessPolicy: true,
                hasDeclaredNativeVerification: false,
                hasResolvedTestCommand: true
            ) == .ordinaryBehaviorCoverage,
            "suite-backed Test feature entered the manual lane"
        )
        print("PASS manual code-admission purpose, prompt and persistence contract")
    }

    private static func checkSourceAndStopGates() throws {
        try require(!allows(sourceIdentityMatches: false), "a saved source identity swap was allowed")
        try require(!allows(stopRequested: true), "a stopped edit was allowed to deliver")
        print("PASS source identity and stop gates")
    }

    private static func checkBuildToolPreflightCommand() throws {
        let expected = "cargo --version && rustc --version"
        try require(
            OnDemandEditCoordinator.testBuildToolPreflightCommand(
                isTestApplication: true, ecosystemIdentifier: "rust/tauri"
            ) == expected,
            "Test rust/tauri did not receive the fixed Rust preflight command"
        )
        try require(
            OnDemandEditCoordinator.testBuildToolPreflightCommand(
                isTestApplication: true, ecosystemIdentifier: "rust/cargo"
            ) == expected,
            "Test rust/cargo did not receive the fixed Rust preflight command"
        )
        try require(
            OnDemandEditCoordinator.testBuildToolPreflightCommand(
                isTestApplication: false, ecosystemIdentifier: "rust"
            ) == nil
                && OnDemandEditCoordinator.testBuildToolPreflightCommand(
                    isTestApplication: false, ecosystemIdentifier: "rust/tauri"
                ) == nil,
            "an ordinary Rust app was given the Test-only preflight command"
        )
        for identifier in [nil, "", "rust/swift", "rust/tauri && touch /tmp/iris-preflight"] as [String?] {
            try require(
                OnDemandEditCoordinator.testBuildToolPreflightCommand(
                    isTestApplication: true, ecosystemIdentifier: identifier
                ) == nil,
                "unexpected Test preflight command for ecosystem \(identifier ?? "nil")"
            )
        }
        print("PASS Test-only Rust build-tool preflight command")
    }
}

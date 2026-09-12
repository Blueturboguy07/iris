import Foundation

/// Why the independent reviewer is being called. A code-admission purpose is
/// deliberately distinct from behavior coverage: it may authorize the next
/// declared step, but it never supplies behavior evidence or delivery credit.
nonisolated enum HarnessReviewPurpose: Sendable, Equatable {
    case ordinaryBehaviorCoverage
    case nativeCodeAdmission
    case manualTestCodeAdmission
}

/// A separate review of observed test coverage, not an independent behavioral
/// oracle. A clean build or an editor's DONE never supplies coverage itself.
nonisolated struct HarnessBehaviorAssessment: Codable, Equatable, Sendable {
    struct Coverage: Codable, Equatable, Sendable {
        let criterionID: String
        let testReference: String
    }
    let revision: String
    let supported: [Coverage]
    let pending: [HarnessAcceptanceCriterion]
    let reviewWasClean: Bool
    let suitePassed: Bool
    let protocolIssue: String?
    let reviewIssues: [String]
    /// True only when the explicit manual-test code-admission review cleared
    /// without any ISSUE, INSUFFICIENT or malformed protocol marker. This is
    /// intentionally separate from `reviewWasClean`: a manual candidate still
    /// has no behavior evidence and can never enter automatic delivery.
    /// Optional for persisted assessments written before the manual lane was
    /// introduced. Missing data is treated as false at every admission gate.
    let manualCodeAdmissionClean: Bool?

    init(
        revision: String,
        supported: [Coverage],
        pending: [HarnessAcceptanceCriterion],
        reviewWasClean: Bool,
        suitePassed: Bool,
        protocolIssue: String?,
        reviewIssues: [String],
        manualCodeAdmissionClean: Bool? = nil
    ) {
        self.revision = revision
        self.supported = supported
        self.pending = pending
        self.reviewWasClean = reviewWasClean
        self.suitePassed = suitePassed
        self.protocolIssue = protocolIssue
        self.reviewIssues = reviewIssues
        self.manualCodeAdmissionClean = manualCodeAdmissionClean
    }

    var permitsAutomaticDelivery: Bool {
        !revision.isEmpty && !supported.isEmpty && pending.isEmpty
            && reviewWasClean && suitePassed && protocolIssue == nil
            && manualCodeAdmissionClean != true
    }

    func permitsAutomaticDelivery(forRevision currentRevision: String?) -> Bool {
        permitsAutomaticDelivery && currentRevision == revision
    }

    var readerSummary: String {
        if permitsAutomaticDelivery {
            return "The requested behaviors have reviewed test coverage. Running-app checks are still separate."
        }
        let details = pending.prefix(3).map(\.statement).joined(separator: "; ")
        return "Your change is saved, but Iris has not confirmed every requested behavior. "
            + (details.isEmpty ? "The test review still needs to finish." : "Still to check: " + details)
            + " Your installed app has not been replaced."
    }

    static func assess(reply: String, criteria: [HarnessAcceptanceCriterion], revision: String,
                       suitePassed: Bool, reviewWasClean: Bool,
                       suppliedTestFiles: [String: String], reviewIssues: [String] = [],
                       manualCodeAdmissionClean: Bool? = nil) -> Self {
        let ids = Set(criteria.map(\.id))
        var coverage: [Coverage] = []
        var seen: Set<String> = []
        var issue: String?
        if criteria.isEmpty || ids.count != criteria.count || revision.isEmpty {
            issue = "The behavior contract or source revision is missing."
        }
        for line in reply.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("COVERED:") else { continue }
            let parts = trimmed.dropFirst("COVERED:".count)
                .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, ids.contains(parts[0]), seen.insert(parts[0]).inserted,
                  isTestSource(parts[1]), let source = suppliedTestFiles[parts[1]], !parts[2].isEmpty,
                  parts[2].utf8.count <= 512, source.contains(parts[2]) else {
                issue = "The reviewer returned missing, duplicate or unsupported test references."
                continue
            }
            coverage.append(Coverage(criterionID: parts[0], testReference: parts[1] + "#" + parts[2]))
        }
        // References support a review judgment only when the actual suite ran
        // successfully and the separate reviewer found no disqualifying issues.
        if !suitePassed || !reviewWasClean || issue != nil { coverage = [] }
        let coveredIDs = Set(coverage.map(\.criterionID))
        return Self(revision: revision, supported: coverage,
                    pending: criteria.filter { !coveredIDs.contains($0.id) },
                    reviewWasClean: reviewWasClean, suitePassed: suitePassed, protocolIssue: issue,
                    reviewIssues: Array(reviewIssues.prefix(8)),
                    manualCodeAdmissionClean: manualCodeAdmissionClean)
    }

    private static func isTestSource(_ path: String) -> Bool {
        let lower = path.lowercased()
        let filename = (lower as NSString).lastPathComponent
        let ext = (filename as NSString).pathExtension
        guard ["swift", "js", "mjs", "cjs", "jsx", "ts", "tsx", "py", "rb", "rs", "go", "cs", "java", "kt"].contains(ext) else { return false }
        return lower.split(separator: "/").contains { ["test", "tests", "spec", "specs"].contains(String($0)) }
            || filename.contains(".test.") || filename.contains(".spec.")
            || filename.hasPrefix("test_") || filename.contains("tests.") || filename.contains("_test.")
    }

    static func reviewInstructions(criteria: [HarnessAcceptanceCriterion]) -> String {
        let contract = criteria.map { "\($0.id): \($0.statement)" }.joined(separator: "\n")
        return """
        BEHAVIOR COVERAGE REVIEW
        Assess each requirement below against tests visible in the supplied source,
        the actual test command, and its recorded result. A passing build is not a
        behavior test. A test name alone is not proof: inspect its assertions and
        whether the recorded command actually runs it. Reject tautological tests.
        Before your final VERDICT line, emit one line for each supported requirement:
        COVERED: criterion-id | exact/test/file/path | exact test name or function name
        Only cite complete test files supplied in this review. If the behavior is
        not exercised, omit its COVERED line and explain what check is needed.
        Never infer physical UI, installed-app, network or restart acceptance from
        mocks that do not test that behavior. These are review judgments, not an oracle.
        \(contract)
        """
    }

    /// Instructions for the exact Test/no-suite manual candidate lane. The
    /// reviewer still performs strict code admission; the missing runtime
    /// interaction is an explicit later manual step, not a reason to invent
    /// behavior evidence here. Any returned ISSUE or INSUFFICIENT marker still
    /// fails code admission through the existing parser.
    static let manualTestCodeAdmissionInstructions = """
    MANUAL TEST CODE ADMISSION, NOT BEHAVIOR ACCEPTANCE
    This is the code-admission review for an Iris Test feature whose repository
    has no declared automated test command and no separate native test lane.
    Inspect the diff, supplied source context and evidence for concrete defects,
    missing implementation, unsafe effects and test tampering. A clean result
    permits only a saved manual-test candidate. It does not prove behavior, earn
    behavior coverage or L6, and it must never authorize automatic delivery.
    The rendered UI, navigation and other runtime interactions are deliberately
    pending the reader's explicit manual test after delivery. Do not demand
    their execution result in this code-admission review. If the implementation
    or supplied source context is insufficient to judge the code, emit the
    existing INSUFFICIENT marker; any ISSUE or INSUFFICIENT marker still blocks
    code admission. Keep the existing exact ISSUE / INSUFFICIENT / VERDICT
    protocol and do not emit COVERED lines for this purpose.
    """
}

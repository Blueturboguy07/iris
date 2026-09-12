import Foundation

/// Facts only. This receipt neither changes execution policy nor asks for consent.
/// Nil means a stage was not run, never that it passed.
nonisolated struct EditVerificationReceipt: Equatable, Sendable {
    var buildPassed: Bool?
    var testsPassed: Bool?
    var confinedTestsPassed: Bool? = nil
    var nativeTestsPassed: Bool? = nil
    var nativeTestsRequired = false
    var symptomReproduced: Bool = false
    // Failure evidence stays in the run details, not the compact status label.
    var failureStage: String? = nil
    var failureOutputTail: String? = nil

    /// A bounded, reader-facing view of failure evidence.
    ///
    /// Scrub the stage before truncating it. The stage is usually a short
    /// code-authored label, but rendering treats it as data and follows the
    /// same egress boundary as output.
    var readerFacingFailureDetail: (stage: String, output: String?)? {
        guard let rawStage = failureStage,
              !rawStage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let scrubbedStage = scrubbedVerificationOutputTail(rawStage)
        let collapsedStage = scrubbedStage
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let stage = String(collapsedStage.prefix(96))
        guard !stage.isEmpty else { return nil }

        let output = failureOutputTail.map {
            scrubbedVerificationOutputTail($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (stage: stage, output: output?.isEmpty == false ? output : nil)
    }

    var anyCheckRan: Bool { buildPassed != nil || testsPassed != nil || confinedTestsPassed != nil || nativeTestsPassed != nil || symptomReproduced }
    var hasFailure: Bool { buildPassed == false || testsPassed == false }

    static func label(for result: Bool?) -> String {
        switch result {
        case true?: return "Passed"
        case false?: return "Failed"
        case nil: return "Not run"
        }
    }

    var summary: String {
        "Build: \(Self.label(for: buildPassed)). Tests: \(testSummary)."
            + (symptomReproduced ? " Bug repro passed all three checks." : " Behavior still needs confirmation.")
    }

    var testSummary: String {
        nativeTestsRequired
            ? "Code: \(Self.label(for: confinedTestsPassed)); desktop: \(Self.label(for: nativeTestsPassed))"
            : Self.label(for: testsPassed)
    }

    var commitTrailer: String {
        func token(_ stage: String, _ passed: Bool?) -> String {
            switch passed {
            case true?: return "\(stage)-green"
            case false?: return "\(stage)-failed"
            case nil: return "\(stage)-not-run"
            }
        }
        return (symptomReproduced ? "Verified: repro-legs, " : "Applied: ")
            + [token("build", buildPassed), token("suite", testsPassed)].joined(separator: ", ")
    }
}

nonisolated struct EditDeliveryProgress: Equatable, Sendable {
    var codeSaved = false
    var freshAppBuilt = false
    var installedCopyReplaced = false
    var relaunched = false
    var behavior = "Not confirmed"
}

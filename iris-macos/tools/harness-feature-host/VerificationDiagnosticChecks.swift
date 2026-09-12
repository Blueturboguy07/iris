import Foundation
@testable import IrisHarnessNative

private enum VerificationDiagnosticCheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Pure receipt-path checks for bounded, scrubbed verification diagnostics.
/// This does not run a command or construct an application service.
@MainActor
func runVerificationDiagnosticChecks() throws {
    let omissionMarker = "… earlier verification output omitted …"

    func receipt(for output: String, stage: String? = "suite") -> EditVerificationReceipt {
        var outcome = VerificationOutcome()
        outcome.suite = .failed
        outcome.blockedStage = stage
        outcome.blockedOutputTail = output
        return outcome.editReceipt
    }

    func scrubbedBeforeCap(_ output: String) -> String {
        let controlStripped = output.components(separatedBy: "\n").map {
            GuideAutopilotOutputBuffer.strippedOfControlSequences($0)
        }.joined(separator: "\n")
        return GuideAutopilotOutputBuffer.scrubbed(controlStripped)
    }

    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationDiagnosticCheckError.failed(message) }
    }

    let shortOutput = "\u{1B}[31mshort status\u{1B}[0m\nfinal line"
    try require(receipt(for: shortOutput).failureOutputTail == scrubbedBeforeCap(shortOutput),
                "short scrubbed output changed before the cap")

    let longCredentialStage = "native-final-review Authorization: "
        + String(repeating: "s", count: 180)
    var readerReceipt = EditVerificationReceipt(buildPassed: nil, testsPassed: false)
    readerReceipt.failureStage = "\u{1B}[31m  \(longCredentialStage) \t"
    readerReceipt.failureOutputTail = "Error: verification stopped\nAuthorization: OUTPUT_SECRET_CANARY_VALUE_123456"
    guard let readerDetail = readerReceipt.readerFacingFailureDetail else {
        throw VerificationDiagnosticCheckError.failed("scrubbed receipt detail was missing")
    }
    try require(readerDetail.stage.count <= 96,
                "reader-facing failure stage exceeded its compact bound")
    try require(readerDetail.stage.contains("native-final-review"),
                "reader-facing failure stage lost its useful label")
    try require(!readerDetail.stage.contains("\u{1B}"),
                "control sequence survived failure-stage scrubbing")
    try require(!readerDetail.stage.contains("\t") && !readerDetail.stage.contains("\n"),
                "failure-stage whitespace was not collapsed")
    try require(!readerDetail.stage.contains(String(repeating: "s", count: 24)),
                "credential value leaked when the failure stage was bounded")
    try require(!(readerDetail.output?.contains("OUTPUT_SECRET_CANARY") ?? true),
                "reader-facing failure output exposed a credential")

    let stageOnlyReceipt = receipt(for: "", stage: "  suite   ")
    guard let stageOnlyDetail = stageOnlyReceipt.readerFacingFailureDetail else {
        throw VerificationDiagnosticCheckError.failed("stage-only receipt detail was missing")
    }
    try require(stageOnlyDetail.stage == "suite" && stageOnlyDetail.output == nil,
                "empty failure output was invented for a stage-only receipt")

    let rootCause = "Error: unable to find the note editor after selecting a saved note"
    let domLines = (0..<160).map { index in
        switch index % 4 {
        case 0: return "  <svg data-index=\"\(index)\" width=\"24\" height=\"24\">"
        case 1: return "    class=\"icon icon-\(index)\""
        case 2: return "    d=\"M0 0 L\(index) \(index)\""
        default: return "  </svg>"
        }
    }
    let noisyOutput = ([
        "<div data-error=\"expected a rendered note\">",
        "  class=\"note-shell\"",
        rootCause,
    ] + domLines + ["Tests 1 failed | 137 passed"]).joined(separator: "\n")
    guard let noisyTail = receipt(for: noisyOutput).failureOutputTail else {
        throw VerificationDiagnosticCheckError.failed("noisy failure output was missing")
    }
    try require(noisyTail.count <= 2_000,
                "noisy diagnostic output exceeded the receipt cap")
    try require(noisyTail.hasPrefix(rootCause + "\n"),
                "the early actionable diagnostic was not prioritized")
    try require(noisyTail.contains(omissionMarker),
                "long diagnostic output did not disclose omitted content")
    try require(noisyTail.contains("Tests 1 failed | 137 passed"),
                "the final verification summary was dropped")

    let longSecret = "BOUNDARY_PREFIX_" + String(repeating: "s", count: 2_600)
        + "_BOUNDARY_SUFFIX_CANARY"
    let longHeader = "Authorization: Bearer " + String(repeating: "b", count: 2_600)
        + "_AUTH_SUFFIX_CANARY"
    let secretOutput = ([
        "Failed: verification could not find the saved note OPENAI_API_KEY=\(longSecret)",
        longHeader,
    ] + domLines + ["Tests 1 failed | 13 passed"]).joined(separator: "\n")
    guard let secretTail = receipt(for: secretOutput).failureOutputTail else {
        throw VerificationDiagnosticCheckError.failed("secret-bearing failure output was missing")
    }
    try require(secretTail.count <= 2_000,
                "secret-bearing diagnostic output exceeded the receipt cap")
    try require(secretTail.hasPrefix("Failed: verification could not find the saved note"),
                "scrub-before-selection lost the actionable failure line")
    try require(secretTail.contains("[REDACTED]"),
                "long credential values were not scrubbed")
    try require(!secretTail.contains("BOUNDARY_PREFIX_"),
                "the long assignment prefix leaked into the receipt")
    try require(!secretTail.contains("_BOUNDARY_SUFFIX_CANARY")
                    && !secretTail.contains("_AUTH_SUFFIX_CANARY"),
                "credential suffixes straddling the cap leaked into the receipt")

    let neutralOutput = (0..<32).map { index in
        "ordinary verification trace line \(index): " + String(repeating: "x", count: 100)
    }.joined(separator: "\n")
    let neutralTail = receipt(for: neutralOutput).failureOutputTail
    let expectedNeutralTail = String(scrubbedBeforeCap(neutralOutput).suffix(2_000))
    try require(neutralTail == expectedNeutralTail,
                "long output without a diagnostic marker changed its legacy suffix")
    try require(!(neutralTail?.contains(omissionMarker) ?? true),
                "a diagnostic omission marker was invented for neutral output")

    let oversizedLine = "Fatal: " + String(repeating: "q", count: 3_500)
        + "\nTests 1 failed | 2 passed"
    guard let oversizedTail = receipt(for: oversizedLine).failureOutputTail else {
        throw VerificationDiagnosticCheckError.failed("oversized diagnostic output was missing")
    }
    try require(oversizedTail.count <= 2_000,
                "an oversized diagnostic line exceeded the receipt cap")
    try require(oversizedTail.hasPrefix("Fatal:") && oversizedTail.contains(omissionMarker),
                "an oversized diagnostic line was not bounded and retained")
    try require(oversizedTail.contains("Tests 1 failed | 2 passed"),
                "an oversized diagnostic line dropped the final summary")

    var missingOutput = VerificationOutcome()
    missingOutput.suite = .failed
    missingOutput.blockedStage = "suite"
    missingOutput.blockedOutputTail = nil
    try require(missingOutput.editReceipt.failureOutputTail == nil,
                "missing failure output was invented")

    var staleOutput = VerificationOutcome()
    staleOutput.suite = .passed
    staleOutput.blockedStage = nil
    staleOutput.blockedOutputTail = "stale failure output"
    try require(staleOutput.editReceipt.failureOutputTail == nil,
                "stale failure output survived a non-blocked receipt")
    switch staleOutput.editReceipt.readerFacingFailureDetail {
    case .none:
        break
    case .some:
        throw VerificationDiagnosticCheckError.failed(
            "stale failure detail survived a non-blocked receipt"
        )
    }

    print("PASS verification diagnostic checks: receipt selection, stage scrubbing, markup skipping, scrub-before-cap, legacy suffix and nil state")
}

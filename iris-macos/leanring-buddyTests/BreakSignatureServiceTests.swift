//
//  BreakSignatureServiceTests.swift
//  leanring-buddyTests
//
//  The fixture is a real `.ips` from a deliberately-crashed Swift binary
//  (array bounds → EXC_BREAKPOINT/SIGTRAP), username-scrubbed. It exercises
//  the exact case the normalizer exists for: the Swift runtime's reporting
//  frames on top, the real culprit below them.
//

import Foundation
import Testing
@testable import leanring_buddy

@Suite struct BreakSignatureServiceTests {

    private func fixtureText() throws -> String {
        let url = Bundle(for: BundleToken.self)
            .url(forResource: "swift-trap-crash", withExtension: "ips")
        let unwrapped = try #require(url, "swift-trap-crash.ips missing from the test bundle")
        return try String(contentsOf: unwrapped, encoding: .utf8)
    }

    @Test func parsesTheTwoBlobFormat() throws {
        let report = try BreakSignatureService.parseCrashReport(fromIPSText: try fixtureText())
        #expect(report.appName == "iris-fixture-crasher")
        #expect(report.exceptionType == "EXC_BREAKPOINT")
        #expect(report.exceptionSignal == "SIGTRAP")
        #expect(!report.faultingFrames.isEmpty)
        #expect(!report.imageUUIDsByIndex.isEmpty)
    }

    @Test func walksPastTheSwiftRuntimeToTheCaller() throws {
        let report = try BreakSignatureService.parseCrashReport(fromIPSText: try fixtureText())
        let signature = BreakSignatureService.nativeCrashSignature(
            fromParsedReport: report, appSlug: "cue", appStack: .swiftMacOS
        )
        // The runtime chose to crash; the identity is the caller, never
        // _assertionFailure — or every Swift trap in an app buckets as one.
        #expect(signature.fingerprintLoose.contains("deepThree"))
        #expect(!signature.protoSignature.contains("_assertionFailure"))
        #expect(signature.signatureId.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil)
    }

    @Test func signaturesAreDeterministic() throws {
        let report = try BreakSignatureService.parseCrashReport(fromIPSText: try fixtureText())
        let first = BreakSignatureService.nativeCrashSignature(
            fromParsedReport: report, appSlug: "cue", appStack: .swiftMacOS
        )
        let second = BreakSignatureService.nativeCrashSignature(
            fromParsedReport: report, appSlug: "cue", appStack: .swiftMacOS
        )
        #expect(first.signatureId == second.signatureId)
    }

    @Test func differentAppsNeverShareASignature() throws {
        let report = try BreakSignatureService.parseCrashReport(fromIPSText: try fixtureText())
        let cue = BreakSignatureService.nativeCrashSignature(
            fromParsedReport: report, appSlug: "cue", appStack: .swiftMacOS
        )
        let lunara = BreakSignatureService.nativeCrashSignature(
            fromParsedReport: report, appSlug: "lunara", appStack: .swiftMacOS
        )
        #expect(cue.signatureId != lunara.signatureId)
    }

    // Parity with lib/break-signature.ts — the web and the desktop must
    // bucket the same message identically or the pool splits in two. These
    // vectors are copied from tests/break-signature.test.ts verbatim.
    @Test func messageNormalizationMatchesTheWebSide() {
        #expect(
            BreakSignatureService.normalizeMessage(
                "Crash at 0xDEADBEEF in /Users/mann/app/main.swift:412"
            ) == "crash at <addr> in <path>"
        )
        #expect(
            BreakSignatureService.normalizeMessage(
                "session 3f1b2c4d-1111-2222-3333-abcdefabcdef expired after 3600s"
            ) == "session <uuid> expired after <n>s"
        )
        #expect(
            BreakSignatureService.normalizeMessage(
                "failed to open C:\\Users\\mann\\AppData\\iris.log"
            ) == "failed to open <path>"
        )
        #expect(BreakSignatureService.normalizeMessage("word ".repeated(500)).count <= 300)
    }

    @Test func categoricalSignaturesCarryNoStack() {
        let hang = BreakSignatureService.hangSignature(
            appSlug: "whimprflow", appStack: .tauri, blockedTopFrame: "AudioCapture::drain + 48"
        )
        #expect(hang.kind == .hang)
        #expect(hang.topFrames.isEmpty)
        #expect(!hang.protoSignature.contains("48"))
    }
}

private final class BundleToken {}

private extension String {
    func repeated(_ count: Int) -> String { String(repeating: self, count: count) }
}

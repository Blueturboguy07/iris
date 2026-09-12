//
//  CredentialWatchExpectationReproTests.swift
//  leanring-buddyTests
//
//  Anthropic-key live run, Sep 2026 fix round, findings:
//
//  "paste-key step's completion gate never verifies a paste happened — only
//  checks Iris is foreground." The step used to declare
//  `foregroundApp: com.publikhq.iris`, which a live run proved is satisfied by
//  anything that brings Iris frontmost — a click on an unrelated control, even
//  a forced activation — with zero key ever pasted.
//
//  "verify-key showed '✓ Key accepted' with no credential ever entered this
//  session." The live run could not tell whether this was a fabricated
//  success or a silently reused stale key already sitting in this machine's
//  Keychain from earlier testing — either way, the step right behind
//  paste-key inherited whatever false-positive paste-key handed it.
//
//  `.credentialWasSaved` is the real signal: satisfied only when the named
//  Keychain secret's value is present AND different from whatever it was (or
//  was not) when the step started being watched. These tests cover both
//  halves the old `foregroundApp` watch could not tell apart — "nothing
//  happened" and "something was already there before the reader did
//  anything" — neither of which may complete the step, only an actual write
//  during the step's own lifetime may.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct CredentialWatchExpectationReproTests {

    /// A stale key already in Keychain from an earlier session/test loop must
    /// not, on its own, satisfy a step whose whole point is confirming a FRESH
    /// paste. This is the scenario the live run flagged as indistinguishable
    /// from a fabricated success: a key present before the step ever opened,
    /// still present and UNCHANGED after, must read as "not done".
    @Test("a credential already present before the step opened does not satisfy it on its own")
    func preexistingCredentialDoesNotSatisfyTheWatch() async throws {
        let watchLoopUnderTest = WatchLoopTests.makeWatchLoop()
        // The Anthropic key from a previous session/test loop is already
        // sitting in Keychain BEFORE this step is ever watched.
        watchLoopUnderTest.localSignalSource.storedCredentialFingerprintsByKind[.anthropicAPIKey] =
            "fingerprint-of-the-stale-key-from-an-earlier-session"

        watchLoopUnderTest.watchLoop.beginWatching(step: WatchLoopTests.step(
            id: "paste-key",
            watch: IrisStepWatch(
                expect: [.credentialWasSaved(secretKind: "anthropic-api-key")],
                sensitive: true
            )
        ))

        var verdictsReported: [WatchVerdict] = []
        watchLoopUnderTest.watchLoop.onVerdict = { verdict in verdictsReported.append(verdict) }

        // The baseline frame, then a meaningful screen change — the reader
        // switching apps, scrolling, anything — with the Keychain untouched.
        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        await WatchLoopTests.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)

        #expect(
            verdictsReported.isEmpty,
            "a key that was already in Keychain before this step opened, and was never touched, must not silently complete a 'paste it' step"
        )

        // The reader genuinely pastes a NEW key now — the value changes.
        watchLoopUnderTest.localSignalSource.storedCredentialFingerprintsByKind[.anthropicAPIKey] =
            "fingerprint-of-the-freshly-pasted-key"
        await WatchLoopTests.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: 0x0F0F)

        #expect(
            verdictsReported == [.completed],
            "a value that actually CHANGED during this step must complete it"
        )
    }

    /// The everyday path: nothing stored when the step opens, the reader
    /// pastes a key, the value appears. This is what a real first-time user
    /// does, and it must complete the step exactly once the write lands —
    /// never merely from Iris becoming the frontmost app.
    @Test("a credential written for the first time during the step satisfies it")
    func freshlyWrittenCredentialSatisfiesTheWatch() async throws {
        let watchLoopUnderTest = WatchLoopTests.makeWatchLoop()
        // Nothing in Keychain yet.
        watchLoopUnderTest.localSignalSource.storedCredentialFingerprintsByKind[.anthropicAPIKey] = nil

        watchLoopUnderTest.watchLoop.beginWatching(step: WatchLoopTests.step(
            id: "paste-key",
            watch: IrisStepWatch(
                expect: [.credentialWasSaved(secretKind: "anthropic-api-key")],
                sensitive: true
            )
        ))

        var verdictsReported: [WatchVerdict] = []
        watchLoopUnderTest.watchLoop.onVerdict = { verdict in verdictsReported.append(verdict) }

        await watchLoopUnderTest.watchLoop.performOneWatchTick()

        // Iris becomes the frontmost application — the OLD watch
        // (`foregroundApp: com.publikhq.iris`) would have completed the step
        // right here. Nothing has been pasted.
        watchLoopUnderTest.localSignalSource.frontmostBundleIdentifier = "com.publikhq.iris"
        await WatchLoopTests.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)

        #expect(
            verdictsReported.isEmpty,
            "becoming the frontmost app is not a credential write and must not complete this step"
        )

        // The reader actually pastes the key into Iris's settings field.
        watchLoopUnderTest.localSignalSource.storedCredentialFingerprintsByKind[.anthropicAPIKey] =
            "fingerprint-of-the-freshly-pasted-key"
        await WatchLoopTests.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: 0x0F0F)

        #expect(verdictsReported == [.completed])
    }

    /// An unrecognized `secretKind` string (a client older or newer than the
    /// guide) must read as "not satisfied", never crash and never silently
    /// complete the step it cannot evaluate.
    @Test("an unrecognized secretKind never satisfies the watch")
    func unrecognizedSecretKindNeverSatisfies() async throws {
        let watchLoopUnderTest = WatchLoopTests.makeWatchLoop()
        watchLoopUnderTest.watchLoop.beginWatching(step: WatchLoopTests.step(
            id: "paste-key",
            watch: IrisStepWatch(expect: [.credentialWasSaved(secretKind: "not-a-real-kind")])
        ))

        var verdictsReported: [WatchVerdict] = []
        watchLoopUnderTest.watchLoop.onVerdict = { verdict in verdictsReported.append(verdict) }

        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        await WatchLoopTests.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)

        #expect(verdictsReported.isEmpty)
    }

    /// The Codable round trip the live guide JSON actually goes over the wire
    /// as, mirroring the pattern every other expectation type is covered by.
    @Test("credentialWasSaved decodes and re-encodes losslessly")
    func credentialWasSavedCodableRoundTrip() throws {
        let json = """
        {"type": "credentialWasSaved", "secretKind": "anthropic-api-key"}
        """
        let decoded = try JSONDecoder().decode(IrisStepExpectation.self, from: Data(json.utf8))
        #expect(decoded == .credentialWasSaved(secretKind: "anthropic-api-key"))
        #expect(decoded.requiresLookingAtTheScreen == false)

        let reencoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(IrisStepExpectation.self, from: reencoded)
        #expect(roundTripped == decoded)
    }
}

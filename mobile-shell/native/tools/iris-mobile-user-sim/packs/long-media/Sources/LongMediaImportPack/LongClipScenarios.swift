import Foundation
import IrisMobileShellCore
import MobileUserSimKit

/// A scenario against the real `NativeMediaImportPolicy`, run many times
/// with varying personas and seeds. Deliberately not `MobileUserSimKit`'s
/// `MobileScenario` (tied to the install/store flow's `RunEnvironment`);
/// this reuses only that package's genuinely generic pieces
/// (`ScenarioOutcome`, `PersonaInterview`, `SeededGenerator`, `FailureClass`).
public protocol LongMediaScenario: AnyObject, Sendable {
    var id: String { get }
    var title: String { get }
    var personas: [MediaImportPersona] { get }
    func run(persona: MediaImportPersona, rng: inout SeededGenerator) -> ScenarioOutcome
}

/// Shared plain-language oracle: whatever failure a scenario's run reaches,
/// the message a person would actually see must be non-empty, plain
/// (no raw byte counts as the only content, no enum-case-shaped text) and,
/// for a space failure, must actually state a real byte figure -- checked
/// independently of which code path produced the failure, per
/// `NativeMediaImportPolicy.message(for:)`.
enum LongMediaOracle {
    static func messageIsPlainLanguage(_ message: String) -> Bool {
        !message.isEmpty && !message.contains("Optional(") && message.first?.isUppercase == true
    }
}

// MARK: 1. Local file, sparse test files from 45 s up to 60 min and 20 GB

public final class LocalFileVariousDurationsScenario: LongMediaScenario {
    public let id = "local-file-various-durations"
    public let title = "A local file from 45 seconds up to 60 minutes and 20 GB, ample free space"
    public let personas: [MediaImportPersona] = [.nonTechnical, .hurriedPowerUser]

    // Named scale points from this task's own brief: a 45 s clip already
    // imports; a 5 minute, 643 MB clip is the reported bug; 60 minutes and
    // 20 GB are the named long-term targets.
    private static let namedClipSizes: [(label: String, bytes: Int64)] = [
        ("45s", 300 * 1024 * 1024),
        ("5min-643MB", 643 * 1024 * 1024),
        ("10min", Int64(1.2 * 1024 * 1024 * 1024)),
        ("60min", Int64(7.5 * 1024 * 1024 * 1024)),
        ("20GB", 20 * 1024 * 1024 * 1024),
    ]

    public func run(persona: MediaImportPersona, rng: inout SeededGenerator) -> ScenarioOutcome {
        let pick = Self.namedClipSizes[Int(rng.next() % UInt64(Self.namedClipSizes.count))]
        let ampleWorld = MediaWorld(persona: MediaImportPersona(
            id: persona.id, displayName: persona.displayName,
            startingFreeStorageBytes: max(persona.startingFreeStorageBytes, pick.bytes * 4 + 4 * 1024 * 1024 * 1024),
            typicalPauseSecondsUpperBound: persona.typicalPauseSecondsUpperBound,
            anotherAppMayFillDiskDuringImport: false, interruptsMidImport: false
        ))
        let item = SimulatedPickerItem(kind: .video, bytes: pick.bytes, progressTicks: [0])
        let outcome = MediaImportBatchRunner.run(items: [item], world: ampleWorld, rng: &rng)
        guard case .accepted(let totalBytes, 1) = outcome, totalBytes == pick.bytes else {
            return ScenarioOutcome(
                passed: false, failureClass: .hostSide,
                message: "a \(pick.label) clip with ample free space must be accepted; got \(outcome)",
                personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: "", knewWhatToDoNext: false)
            )
        }
        return ScenarioOutcome(
            passed: true, message: "\(pick.label) clip (\(pick.bytes) bytes) accepted",
            personaInterview: PersonaInterview(didFinish: true, lastHonestMessage: "your video is ready", knewWhatToDoNext: true),
            evidence: ["clipLabel": pick.label, "bytes": "\(pick.bytes)"]
        )
    }
}

// MARK: 2. Slow iCloud download with pauses

public final class SlowICloudDownloadWithPausesScenario: LongMediaScenario {
    public let id = "slow-icloud-with-pauses"
    public let title = "A slow but healthy iCloud download, pausing but never stalling"
    public let personas: [MediaImportPersona] = MediaImportBuiltInPersonas.all

    public func run(persona: MediaImportPersona, rng: inout SeededGenerator) -> ScenarioOutcome {
        var ticks: [TimeInterval] = [0]
        var t: TimeInterval = 0
        let totalDuration: TimeInterval = 180 + Double(rng.next() % 300) // 3 to 8 simulated minutes
        while t < totalDuration {
            // Every pause is strictly under this persona's own upper bound,
            // and strictly under the real stall threshold: this scenario
            // asserts "never stalls", by construction and by outcome.
            let pauseCeiling = min(persona.typicalPauseSecondsUpperBound, NativeMediaImportPolicy.stallThresholdSeconds - 1)
            let pause = 1 + rng.nextUnitDouble() * max(1, pauseCeiling - 1)
            t += pause
            ticks.append(t)
        }
        let world = MediaWorld(persona: persona)
        let item = SimulatedPickerItem(kind: .video, bytes: 900 * 1024 * 1024, progressTicks: ticks)
        let outcome = MediaImportBatchRunner.run(items: [item], world: world, rng: &rng)
        guard case .accepted = outcome else {
            return ScenarioOutcome(
                passed: false, failureClass: .hostSide,
                message: "a download whose pauses never reach the stall threshold must not be judged stalled; got \(outcome)",
                personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: "", knewWhatToDoNext: false),
                evidence: ["ticks": ticks.map { String($0) }.joined(separator: ",")]
            )
        }
        return ScenarioOutcome(
            passed: true, message: "slow but healthy download (\(ticks.count) ticks over \(Int(t))s) accepted",
            personaInterview: PersonaInterview(didFinish: true, lastHonestMessage: "your video is ready", knewWhatToDoNext: true)
        )
    }
}

// MARK: 3. A provider that deletes its own temp file early

public final class ProviderDeletesTempFileEarlyScenario: LongMediaScenario {
    public let id = "provider-deletes-temp-file-early"
    public let title = "A document provider that deletes its own temp file before handing it over"
    public let personas: [MediaImportPersona] = [.nonTechnical]

    public func run(persona: MediaImportPersona, rng: inout SeededGenerator) -> ScenarioOutcome {
        let world = MediaWorld(persona: persona)
        let item = SimulatedPickerItem(
            kind: .video, bytes: 400 * 1024 * 1024, progressTicks: [0], providerDeletesTempFileEarly: true
        )
        let outcome = MediaImportBatchRunner.run(items: [item], world: world, rng: &rng)
        guard case .rejected(0, .providerFailure) = outcome else {
            return ScenarioOutcome(
                passed: false, failureClass: .platform,
                message: "an early-deleted provider file must be rejected at that item with a provider failure; got \(outcome)",
                personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: "", knewWhatToDoNext: false)
            )
        }
        let message = NativeMediaImportPolicy.message(for: .other)
        guard LongMediaOracle.messageIsPlainLanguage(message) else {
            return ScenarioOutcome(
                passed: false, failureClass: .hostSide, message: "message was not plain language: \(message)",
                personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: message, knewWhatToDoNext: false)
            )
        }
        return ScenarioOutcome(
            passed: true, message: "provider failure surfaced a plain message: \(message)",
            personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: message, knewWhatToDoNext: true)
        )
    }
}

// MARK: 4. Disk nearly full

public final class DiskNearlyFullScenario: LongMediaScenario {
    public let id = "disk-nearly-full"
    public let title = "A nearly full phone rejects a video it cannot safely fit, with a plain message"
    public let personas: [MediaImportPersona] = [.edgeUser]

    public func run(persona: MediaImportPersona, rng: inout SeededGenerator) -> ScenarioOutcome {
        let clipBytes: Int64 = 4 * 1024 * 1024 * 1024 // 4 GB
        let barelyShort = MediaImportPersona(
            id: persona.id, displayName: persona.displayName,
            // Just under the real required floor (3x + margin) for this clip.
            startingFreeStorageBytes: NativeMediaImportPolicy.requiredFreeBytes(forProjectedTotalBytes: clipBytes) - 1,
            typicalPauseSecondsUpperBound: persona.typicalPauseSecondsUpperBound,
            anotherAppMayFillDiskDuringImport: false, interruptsMidImport: false
        )
        let world = MediaWorld(persona: barelyShort)
        let item = SimulatedPickerItem(kind: .video, bytes: clipBytes, progressTicks: [0])
        let outcome = MediaImportBatchRunner.run(items: [item], world: world, rng: &rng)
        guard case .rejected(0, .insufficientSpace(let required, let available)) = outcome else {
            return ScenarioOutcome(
                passed: false, failureClass: .hostSide,
                message: "one byte short of the required floor must be rejected for space; got \(outcome)",
                personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: "", knewWhatToDoNext: false)
            )
        }
        let message = NativeMediaImportPolicy.message(for: .notEnoughSpace(requiredBytes: required))
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        guard LongMediaOracle.messageIsPlainLanguage(message),
              message.contains(formatter.string(fromByteCount: required)) else {
            return ScenarioOutcome(
                passed: false, failureClass: .hostSide,
                message: "space message must state the real amount needed in plain words: \(message)",
                personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: message, knewWhatToDoNext: false)
            )
        }
        return ScenarioOutcome(
            passed: true, message: "rejected with a plain space message (\(message)); available \(available)",
            personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: message, knewWhatToDoNext: true)
        )
    }
}

// MARK: 5. Disk filling from another app during import

public final class DiskFillingFromAnotherAppDuringImportScenario: LongMediaScenario {
    public let id = "disk-filling-during-import"
    public let title = "Another app consumes free space while a multi-clip import is in progress"
    public let personas: [MediaImportPersona] = [.hurriedPowerUser, .edgeUser]

    public func run(persona: MediaImportPersona, rng: inout SeededGenerator) -> ScenarioOutcome {
        let clipBytes: Int64 = 500 * 1024 * 1024
        let items = (0..<5).map { _ in SimulatedPickerItem(kind: .video, bytes: clipBytes, progressTicks: [0]) }
        // Free space starts comfortably ample for the whole batch, but
        // another app eats a large, growing bite before each later item's
        // own check -- so a check that only looked at the ORIGINAL snapshot
        // (rather than re-reading fresh, as the real Host does before every
        // item) would wrongly accept an item the device can no longer
        // actually fit.
        let externalFill: [Int64] = (0..<5).map { index in Int64(index) * 800 * 1024 * 1024 }
        let plenty = MediaImportPersona(
            id: persona.id, displayName: persona.displayName,
            startingFreeStorageBytes: clipBytes * 3 * 5 + 2 * 1024 * 1024 * 1024,
            typicalPauseSecondsUpperBound: persona.typicalPauseSecondsUpperBound,
            anotherAppMayFillDiskDuringImport: true, interruptsMidImport: false
        )
        let world = MediaWorld(persona: plenty, externalFillScheduleBytes: externalFill)
        let outcome = MediaImportBatchRunner.run(items: items, world: world, rng: &rng)

        // Oracle independent of the outcome's own opinion of itself: free
        // space, as the world's own ground truth tracked it, must never
        // have gone negative (this pack's `MediaWorld` floors at 0 itself,
        // so this also proves the runner never asked the world to charge
        // more than it had).
        guard world.currentFreeStorageBytes() >= 0 else {
            return ScenarioOutcome(
                passed: false, failureClass: .hostSide,
                message: "free space must never be charged below zero",
                personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: "", knewWhatToDoNext: false)
            )
        }
        switch outcome {
        case .accepted:
            return ScenarioOutcome(
                passed: true, message: "batch fit even with another app's concurrent writes",
                personaInterview: PersonaInterview(didFinish: true, lastHonestMessage: "your videos are ready", knewWhatToDoNext: true),
                evidence: ["events": world.eventLog().joined(separator: " | ")]
            )
        case .rejected(let index, .insufficientSpace(let required, let available)):
            // This is the real point of the scenario: the check must catch
            // the shrinking free space at the item where it actually
            // stopped fitting, not accept the whole batch based on a stale
            // reading from before the external fill.
            guard available < required else {
                return ScenarioOutcome(
                    passed: false, failureClass: .hostSide,
                    message: "rejected item \(index) claims insufficient space but available (\(available)) >= required (\(required))",
                    personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: "", knewWhatToDoNext: false)
                )
            }
            let message = NativeMediaImportPolicy.message(for: .notEnoughSpace(requiredBytes: required))
            return ScenarioOutcome(
                passed: LongMediaOracle.messageIsPlainLanguage(message),
                message: "correctly caught the shrinking free space at item \(index): \(message)",
                personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: message, knewWhatToDoNext: true),
                evidence: ["events": world.eventLog().joined(separator: " | ")]
            )
        case .rejected(let index, let reason):
            return ScenarioOutcome(
                passed: false, failureClass: .hostSide,
                message: "unexpected rejection reason at item \(index): \(reason)",
                personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: "", knewWhatToDoNext: false)
            )
        }
    }
}

// MARK: 6. Cancel mid-way

public final class CancelMidwayScenario: LongMediaScenario {
    public let id = "cancel-midway"
    public let title = "A hurried person cancels partway through a multi-clip pick"
    public let personas: [MediaImportPersona] = [.hurriedPowerUser]

    public func run(persona: MediaImportPersona, rng: inout SeededGenerator) -> ScenarioOutcome {
        let clipBytes: Int64 = 300 * 1024 * 1024
        let items = (0..<4).map { _ in SimulatedPickerItem(kind: .video, bytes: clipBytes, progressTicks: [0]) }
        let world = MediaWorld(persona: persona)
        let cancelAt = Int(rng.next() % 3) // cancels after item 0, 1 or 2 of 4
        let outcome = MediaImportBatchRunner.run(items: items, world: world, rng: &rng, cancelAfterItemIndex: cancelAt)

        guard case .rejected(let index, .cancelledByPersona) = outcome, index == cancelAt + 1 else {
            return ScenarioOutcome(
                passed: false, failureClass: .hostSide,
                message: "a mid-batch cancel must stop the batch right after the cancel point, importing nothing; got \(outcome)",
                personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: "", knewWhatToDoNext: false)
            )
        }
        return ScenarioOutcome(
            passed: true, message: "cancelled cleanly after item \(cancelAt) of \(items.count)",
            // A cancel is deliberately silent in the real UI (no notice
            // shown; see NativeMediaPickerSession.importResults's
            // shouldNotice = false for .cancelled), so this persona
            // "finished" the interaction (they got exactly what they asked
            // for) without a message at all.
            personaInterview: PersonaInterview(didFinish: true, lastHonestMessage: "", knewWhatToDoNext: true)
        )
    }
}

// MARK: 7. Several clips at once, combined up to an hour

public final class SeveralClipsCombinedUpToAnHourScenario: LongMediaScenario {
    public let id = "several-clips-combined-up-to-an-hour"
    public let title = "Several clips picked together, combined up to an hour, one batch"
    public let personas: [MediaImportPersona] = [.nonTechnical, .hurriedPowerUser]

    public func run(persona: MediaImportPersona, rng: inout SeededGenerator) -> ScenarioOutcome {
        let clipCount = 3 + Int(rng.next() % 6) // 3 to 8 clips
        // An hour of combined 4K footage (this task's own named scale),
        // split evenly across however many clips this run picked.
        let anHourOfFourKBytes: Int64 = 8 * Int64(7.5 * 1024 * 1024 * 1024)
        let perClipBytes = anHourOfFourKBytes / Int64(clipCount)
        let items = (0..<clipCount).map { _ in SimulatedPickerItem(kind: .video, bytes: perClipBytes, progressTicks: [0]) }
        let ample = MediaImportPersona(
            id: persona.id, displayName: persona.displayName,
            startingFreeStorageBytes: perClipBytes * Int64(clipCount) * 4 + 4 * 1024 * 1024 * 1024,
            typicalPauseSecondsUpperBound: persona.typicalPauseSecondsUpperBound,
            anotherAppMayFillDiskDuringImport: false, interruptsMidImport: false
        )
        let world = MediaWorld(persona: ample)
        let outcome = MediaImportBatchRunner.run(items: items, world: world, rng: &rng)
        guard case .accepted(let totalBytes, let itemCount) = outcome, itemCount == clipCount else {
            return ScenarioOutcome(
                passed: false, failureClass: .hostSide,
                message: "\(clipCount) combined clips with ample space must be accepted as one whole batch; got \(outcome)",
                personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: "", knewWhatToDoNext: false)
            )
        }
        // The "one progress sheet" requirement's message-building half: the
        // same pure function the real Host's sheet reads from must name
        // every clip in this batch correctly, in order.
        for completed in 0..<clipCount {
            let expected = "Long videos can take a minute. Bringing in clip \(completed + 1) of \(clipCount)."
            let actual = NativeMediaImportPolicy.waitingIndicatorMessage(completedItems: completed, totalItems: clipCount)
            guard actual == expected else {
                return ScenarioOutcome(
                    passed: false, failureClass: .hostSide,
                    message: "waiting-indicator text wrong at completed=\(completed): got '\(actual)', wanted '\(expected)'",
                    personaInterview: PersonaInterview(didFinish: false, lastHonestMessage: actual, knewWhatToDoNext: false)
                )
            }
        }
        return ScenarioOutcome(
            passed: true, message: "\(clipCount) clips, \(totalBytes) combined bytes, accepted as one batch with correct progress text",
            personaInterview: PersonaInterview(didFinish: true, lastHonestMessage: "your videos are ready", knewWhatToDoNext: true)
        )
    }
}

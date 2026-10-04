import Foundation

// Exercises the REAL, unchanged
// Sources/IrisMobileShellHost/NativeAudioSessionPolicy.swift (compiled
// alongside this file by run.sh) against a fake session controller. Only the
// pure Foundation-only half of that file is reachable here: this target is
// macOS, so the `#if os(iOS)` adapter (the real AVAudioSession, WebKit,
// anything native) is not compiled in, exactly as it would not be in any
// other macOS build of that file. No simulator, no WebKit, no native app.

// MARK: - Fake session controller

/// Records every call the policy makes and can be told to throw once, to
/// simulate another app already holding the session.
final class FakeAudioSessionController: NativeAudioSessionControlling {
    enum Call: Equatable, CustomStringConvertible {
        case setCategory
        case setActive(Bool)

        var description: String {
            switch self {
            case .setCategory: return "setCategory"
            case .setActive(let active): return "setActive(\(active))"
            }
        }
    }

    struct FakeSessionError: Error, CustomStringConvertible {
        let description: String
    }

    private(set) var calls: [Call] = []
    var failNextSetPlaybackCategory = false
    var failNextSetActiveTrue = false

    func setPlaybackCategory() throws {
        calls.append(.setCategory)
        if failNextSetPlaybackCategory {
            failNextSetPlaybackCategory = false
            throw FakeSessionError(description: "another app holds the session")
        }
    }

    func setActive(_ active: Bool) throws {
        calls.append(.setActive(active))
        if active, failNextSetActiveTrue {
            failNextSetActiveTrue = false
            throw FakeSessionError(description: "another app holds the session")
        }
    }
}

// MARK: - Independent reference oracle
//
// Built from the rules in the task, not from NativeAudioSessionPolicy's own
// code: different state shape (no "which presentation activated" field, no
// try/catch, no controller calls of its own), different guard conditions.
// It never calls into the policy or the fake controller.

struct ReferenceSessionOracle {
    private var openID: UUID?
    private var openIsMedia = false
    private var interrupted = false

    var mediaAppIsOpen: Bool { openID != nil && openIsMedia }
    var expectedActive: Bool { mediaAppIsOpen && !interrupted }

    mutating func open(id: UUID, isMedia: Bool) {
        if openID == id {
            // Same presentation reopening (a duplicate onAppear, or a
            // retry) does not by itself clear an in-progress interruption;
            // only a genuinely different open, a resumed interruption end,
            // or a media-services reset does.
            openIsMedia = isMedia
            return
        }
        openID = id
        openIsMedia = isMedia
        interrupted = false
    }

    mutating func close(id: UUID) {
        guard openID == id else { return }
        openID = nil
        openIsMedia = false
        interrupted = false
    }

    mutating func interruptionBegan() {
        guard mediaAppIsOpen else { return }
        interrupted = true
    }

    mutating func interruptionEnded(shouldResume: Bool) {
        guard interrupted else { return }
        if shouldResume { interrupted = false }
    }

    mutating func mediaServicesWereReset() {
        interrupted = false
    }
}

// MARK: - Check recorder

@MainActor
final class CheckRecorder {
    private(set) var passedCount = 0
    private(set) var failures: [String] = []

    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        if condition() {
            passedCount += 1
        } else {
            failures.append(label)
        }
    }

    var totalCount: Int { passedCount + failures.count }
}

// MARK: - wantsPlayback classification

@MainActor
func scenarioWantsPlaybackClassification(recorder: CheckRecorder) {
    recorder.check(
        NativeAudioSessionPolicy.wantsPlayback(requestedCapabilities: ["web.storage", "web.media.photo-picker", "web.media.export"]),
        "kneecap's capabilities want playback")
    recorder.check(
        NativeAudioSessionPolicy.wantsPlayback(requestedCapabilities: ["web.media.camera"]),
        "freeharmony's capability wants playback")
    recorder.check(
        !NativeAudioSessionPolicy.wantsPlayback(requestedCapabilities: ["web.storage"]),
        "web.storage alone does not want playback (nut ai / storage-only apps)")
    recorder.check(
        !NativeAudioSessionPolicy.wantsPlayback(requestedCapabilities: []),
        "no capabilities does not want playback")
    recorder.check(
        !NativeAudioSessionPolicy.wantsPlayback(requestedCapabilities: ["web.media"]),
        "the bare prefix without a trailing dot is not a match")
    recorder.check(
        !NativeAudioSessionPolicy.wantsPlayback(requestedCapabilities: ["native.microphone"]),
        "a native capability is not a web.media capability")
    recorder.check(
        !NativeAudioSessionPolicy.wantsPlayback(requestedCapabilities: ["xweb.media.export"]),
        "web.media. appearing mid-string does not count: this is a prefix match, not a substring match")
}

// MARK: - Scenario (a): a phone call interrupts and resumes

@MainActor
func scenarioPhoneCallInterruptsAndResumes(recorder: CheckRecorder) {
    let controller = FakeAudioSessionController()
    let policy = NativeAudioSessionPolicy(controller: controller)
    let kneecap = UUID()

    // A person opens Kneecap with the silent switch on and plays.
    policy.appDidOpen(presentationID: kneecap, requestedCapabilities: ["web.storage", "web.media.photo-picker", "web.media.export"])
    recorder.check(policy.isSessionActive, "kneecap opening a media app becomes active")
    recorder.check(controller.calls == [.setCategory, .setActive(true)], "kneecap open sets category then activates")

    // A phone call interrupts.
    policy.interruptionBegan()
    recorder.check(!policy.isSessionActive, "a phone call interrupting reports the session inactive")
    recorder.check(controller.calls == [.setCategory, .setActive(true)], "the interruption itself makes no session call: iOS already deactivated it")

    // The call ends with shouldResume.
    policy.interruptionEnded(shouldResume: true)
    recorder.check(policy.isSessionActive, "the call ending with shouldResume brings audio back")
    recorder.check(
        controller.calls == [.setCategory, .setActive(true), .setCategory, .setActive(true)],
        "resuming re-applies the category before reactivating")
}

// MARK: - Scenario (b): a hurried app switch must not cross-deactivate

@MainActor
func scenarioHurriedSwitchProtectsNewApp(recorder: CheckRecorder) {
    let controller = FakeAudioSessionController()
    let policy = NativeAudioSessionPolicy(controller: controller)
    let kneecap = UUID()
    let nutAI = UUID()
    let freeHarmony = UUID()

    policy.appDidOpen(presentationID: kneecap, requestedCapabilities: ["web.media.export"])
    recorder.check(policy.isSessionActive, "kneecap opens and activates")
    let callsBeforeNutAI = controller.calls.count

    // A hurried person goes Home and opens Nut AI, which declares no
    // web.media.* capability, before Kneecap's own close has arrived.
    policy.appDidOpen(presentationID: nutAI, requestedCapabilities: [])
    let callsDuringNutAIOpen = Array(controller.calls.dropFirst(callsBeforeNutAI))
    recorder.check(
        !callsDuringNutAIOpen.contains(.setCategory) && !callsDuringNutAIOpen.contains(.setActive(true)),
        "opening Nut AI never itself sets a category or activates the session")
    recorder.check(!policy.isSessionActive, "Nut AI is not active (it never asked to be)")

    // Then FreeHarmony, which does declare a media capability.
    policy.appDidOpen(presentationID: freeHarmony, requestedCapabilities: ["web.media.camera"])
    recorder.check(policy.isSessionActive, "FreeHarmony opens and activates")
    recorder.check(controller.calls.last == .setActive(true), "FreeHarmony's activation is the most recent call")

    // Kneecap's onDisappear, delayed by its own dismissal animation,
    // finally arrives after FreeHarmony is already open and active.
    policy.appDidClose(presentationID: kneecap)
    recorder.check(policy.isSessionActive, "the late Kneecap close does not deactivate FreeHarmony")
    recorder.check(controller.calls.last == .setActive(true), "no deactivate call was made for the late, stale close")
}

// MARK: - Scenario (b2): a non-media app never touches the session, open or close

@MainActor
func scenarioNonMediaAppNeverCallsTheSession(recorder: CheckRecorder) {
    // Round 5 (integrator B): found by the mutation check. Removing the
    // "was this presentation the one that activated" guard on close still
    // passed every earlier check, because none of them looked at what a
    // non-media app's CLOSE does. Nut AI opening and closing must leave the
    // controller with no call at all, in either direction.
    let controller = FakeAudioSessionController()
    let policy = NativeAudioSessionPolicy(controller: controller)
    let nutAI = UUID()
    policy.appDidOpen(presentationID: nutAI, requestedCapabilities: ["web.storage"])
    policy.appDidClose(presentationID: nutAI)
    recorder.check(controller.calls.isEmpty, "a storage-only app opening then closing makes no session call at all")

    // A media app whose activation failed also has nothing to undo on close.
    let failing = FakeAudioSessionController()
    failing.failNextSetActiveTrue = true
    let failingPolicy = NativeAudioSessionPolicy(controller: failing)
    let kneecap = UUID()
    failingPolicy.appDidOpen(presentationID: kneecap, requestedCapabilities: ["web.media.export"])
    failingPolicy.appDidClose(presentationID: kneecap)
    recorder.check(
        !failing.calls.contains(.setActive(false)),
        "closing a media app whose activation never succeeded does not deactivate a session it never held")
}

// MARK: - Scenario (c): a misbehaving world (activation failures, then a working retry)

@MainActor
func scenarioActivationFailureThenRetry(recorder: CheckRecorder) {
    let controller = FakeAudioSessionController()
    controller.failNextSetActiveTrue = true
    let policy = NativeAudioSessionPolicy(controller: controller)
    let kneecap = UUID()

    // Another app is holding the session, so the first activation fails.
    policy.appDidOpen(presentationID: kneecap, requestedCapabilities: ["web.media.export"])
    recorder.check(!policy.isSessionActive, "an activation failure leaves the session reporting inactive")
    recorder.check(policy.lastActivationFailed, "the policy records the activation failure")

    // The person reopens Kneecap (or the hook's onAppear fires again);
    // this time the other app has released the session.
    policy.appDidOpen(presentationID: kneecap, requestedCapabilities: ["web.media.export"])
    recorder.check(policy.isSessionActive, "the retry succeeds")
    recorder.check(!policy.lastActivationFailed, "the failure flag clears once the retry succeeds")
}

@MainActor
func scenarioCategoryFailureAlsoRecovers(recorder: CheckRecorder) {
    let controller = FakeAudioSessionController()
    controller.failNextSetPlaybackCategory = true
    let policy = NativeAudioSessionPolicy(controller: controller)
    let kneecap = UUID()

    policy.appDidOpen(presentationID: kneecap, requestedCapabilities: ["web.media.export"])
    recorder.check(!policy.isSessionActive, "a setPlaybackCategory failure also leaves the session inactive")
    recorder.check(policy.lastActivationFailed, "a setPlaybackCategory failure is recorded as an activation failure")
    recorder.check(controller.calls == [.setCategory], "setActive is never attempted once setPlaybackCategory has thrown")

    policy.appDidOpen(presentationID: kneecap, requestedCapabilities: ["web.media.export"])
    recorder.check(policy.isSessionActive, "the retry after a category failure succeeds")
}

// MARK: - Scenario (c continued): media services reset mid-session

@MainActor
func scenarioMediaServicesResetMidSession(recorder: CheckRecorder) {
    let controller = FakeAudioSessionController()
    let policy = NativeAudioSessionPolicy(controller: controller)
    let kneecap = UUID()

    policy.appDidOpen(presentationID: kneecap, requestedCapabilities: ["web.media.export"])
    recorder.check(policy.isSessionActive, "kneecap is active before the reset")

    policy.mediaServicesWereReset()
    recorder.check(policy.isSessionActive, "still active after mediaserverd restarts")
    recorder.check(
        controller.calls == [.setCategory, .setActive(true), .setCategory, .setActive(true)],
        "the reset re-applies the category and reactivates, not just reactivates")

    // With nothing open, a reset must not spuriously activate anything.
    policy.appDidClose(presentationID: kneecap)
    let callsBeforeReset = controller.calls
    policy.mediaServicesWereReset()
    recorder.check(controller.calls == callsBeforeReset, "a reset with nothing open makes no session call")
    recorder.check(!policy.isSessionActive, "still inactive after a reset with nothing open")
}

// MARK: - Seeded randomized sweep

/// A small deterministic PRNG (splitmix64), reimplemented here rather than
/// shared, so this tool does not depend on any other tool's copy (same
/// convention as tools/iris-mobile-user-sim/Sources/MobileUserSimKit/SeededGenerator.swift).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextBool() -> Bool { next() & 1 == 1 }
    mutating func nextIndex(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

enum SweepAction: CustomStringConvertible {
    case open
    case close
    case interruptBegin
    case interruptEnd
    case reset

    var description: String {
        switch self {
        case .open: return "open"
        case .close: return "close"
        case .interruptBegin: return "interruptBegin"
        case .interruptEnd: return "interruptEnd"
        case .reset: return "reset"
        }
    }

    static func random(_ rng: inout SplitMix64) -> SweepAction {
        switch rng.nextIndex(14) {
        case 0, 1, 2, 3, 4, 5: return .open
        case 6, 7, 8, 9: return .close
        case 10, 11: return .interruptBegin
        case 12: return .interruptEnd
        default: return .reset
        }
    }
}

/// A fixed pool entry: a presentation ID together with the capabilities it
/// was "launched" with. A real `presentationID` is generated once per app
/// launch and its capabilities come from the signed, verified launch
/// descriptor, so they never change across the ID's lifetime; the pool
/// mirrors that by fixing each ID's capabilities once, rather than
/// re-rolling them on every open.
struct PoolEntry {
    let id: UUID
    let isMedia: Bool
    let requestedCapabilities: [String]
}

/// A person opening, closing, backgrounding and being interrupted in some
/// unpredictable order across a small pool of app presentations, checked
/// after every step against `ReferenceSessionOracle`.
@MainActor
func sweepScenario(seed: UInt64, recorder: CheckRecorder) {
    var rng = SplitMix64(seed: seed)
    let rawIDs: [UUID] = [
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
    ]
    let pool: [PoolEntry] = rawIDs.map { id in
        let isMedia = rng.nextBool()
        let capabilities: [String]
        if isMedia {
            capabilities = ["web.media.export"]
        } else {
            // Sometimes web.storage, to also guard against a "treat
            // web.storage as media" regression.
            capabilities = rng.nextBool() ? ["web.storage"] : []
        }
        return PoolEntry(id: id, isMedia: isMedia, requestedCapabilities: capabilities)
    }
    let controller = FakeAudioSessionController()
    let policy = NativeAudioSessionPolicy(controller: controller)
    var oracle = ReferenceSessionOracle()

    let stepCount = 50
    for step in 0..<stepCount {
        let action = SweepAction.random(&rng)
        switch action {
        case .open:
            let entry = pool[rng.nextIndex(pool.count)]
            policy.appDidOpen(presentationID: entry.id, requestedCapabilities: entry.requestedCapabilities)
            oracle.open(id: entry.id, isMedia: entry.isMedia)
        case .close:
            let entry = pool[rng.nextIndex(pool.count)]
            policy.appDidClose(presentationID: entry.id)
            oracle.close(id: entry.id)
        case .interruptBegin:
            policy.interruptionBegan()
            oracle.interruptionBegan()
        case .interruptEnd:
            let shouldResume = rng.nextBool()
            policy.interruptionEnded(shouldResume: shouldResume)
            oracle.interruptionEnded(shouldResume: shouldResume)
        case .reset:
            policy.mediaServicesWereReset()
            oracle.mediaServicesWereReset()
        }

        recorder.check(
            policy.isSessionActive == oracle.expectedActive,
            "seed \(seed) step \(step) [\(action)]: isSessionActive=\(policy.isSessionActive) expected=\(oracle.expectedActive)")
        if !oracle.mediaAppIsOpen {
            recorder.check(
                controller.calls.isEmpty || controller.calls.last == .setActive(false),
                "seed \(seed) step \(step) [\(action)]: no media app open, but the last session call was \(controller.calls.last?.description ?? "none")")
        }
    }

    // Structural check: a deactivate never outnumbers the activations that
    // came before it (a close must not release a session nobody held).
    var activations = 0
    var deactivations = 0
    for call in controller.calls {
        if call == .setActive(true) { activations += 1 }
        if call == .setActive(false) {
            deactivations += 1
            recorder.check(deactivations <= activations, "seed \(seed): a setActive(false) with no earlier setActive(true) to undo")
        }
    }

    // Structural check over the whole run: every activation is immediately
    // preceded by its own category call (catches a dropped category call
    // that a boolean-only comparison could miss).
    for (index, call) in controller.calls.enumerated() where call == .setActive(true) {
        recorder.check(
            index > 0 && controller.calls[index - 1] == .setCategory,
            "seed \(seed): setActive(true) at call #\(index) was not immediately preceded by setPlaybackCategory")
    }
}

// MARK: - Entry point

@main
@MainActor
struct ShellAudioChecks {
    static func main() {
        let recorder = CheckRecorder()
        scenarioWantsPlaybackClassification(recorder: recorder)
        scenarioPhoneCallInterruptsAndResumes(recorder: recorder)
        scenarioHurriedSwitchProtectsNewApp(recorder: recorder)
        scenarioNonMediaAppNeverCallsTheSession(recorder: recorder)
        scenarioActivationFailureThenRetry(recorder: recorder)
        scenarioCategoryFailureAlsoRecovers(recorder: recorder)
        scenarioMediaServicesResetMidSession(recorder: recorder)
        for seed in UInt64(1)...200 {
            sweepScenario(seed: seed, recorder: recorder)
        }

        print("shell-audio-checks: \(recorder.passedCount)/\(recorder.totalCount) checks passed")
        if !recorder.failures.isEmpty {
            print("shell-audio-checks: \(recorder.failures.count) FAILED:")
            for failure in recorder.failures {
                print(" - \(failure)")
            }
            exit(1)
        }
    }
}

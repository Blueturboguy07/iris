import Foundation

struct NativeAppCloseToken: Equatable, Hashable, Sendable {
    let presentationID: UUID
    let documentHandle: UUID
}

enum NativeAppClosePreparationResult: Equatable, Sendable {
    case noHook
    case ready
    case failed
}

enum NativeAppCloseWarning: Equatable, Sendable {
    case failed
    case timedOut
}

/// Owns only the decision to leave one exact full-screen document.
///
/// The injected evaluator is the Host's fixed, no-argument close hook seam. This
/// helper never constructs JavaScript, accepts app content, or creates a native
/// bridge. Timeout/cancellation invalidates callback acceptance; it deliberately
/// does not claim to cancel work which may still be running inside WebKit.
@MainActor
final class NativeAppCloseLifecycle {
    enum State: Equatable, Sendable {
        case idle
        case preparing
        case warning(NativeAppCloseWarning)
        case closing
    }

    typealias PreparationCompletion = @MainActor (NativeAppClosePreparationResult) -> Void
    typealias FixedHookEvaluator = @MainActor (@escaping PreparationCompletion) -> Void
    typealias CloseHandler = @MainActor () -> Void
    typealias StateHandler = @MainActor (State) -> Void

    private(set) var state: State = .idle {
        didSet { stateDidChange(state) }
    }
    private(set) var currentToken: NativeAppCloseToken?

    private let timeoutNanoseconds: UInt64
    private let stateDidChange: StateHandler
    private var requestGeneration: UInt64 = 0
    private var timeoutTask: Task<Void, Never>?
    private var pendingClose: CloseHandler?

    init(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        stateDidChange: @escaping StateHandler = { _ in }
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.stateDidChange = stateDidChange
    }

    /// Binds Home to the exact current presentation + WebView document handle.
    /// Replacing the token invalidates an older preparation even when WebKit later
    /// reports its callback after cancellation or timeout.
    func updateToken(_ token: NativeAppCloseToken) {
        guard currentToken != token else { return }
        invalidatePendingRequest()
        currentToken = token
        state = .idle
    }

    /// Home is single-flight. The per-request callbacks are supplied by the
    /// integration so they capture only this exact WebView/document instance.
    func requestClose(
        for token: NativeAppCloseToken,
        evaluate: @escaping FixedHookEvaluator,
        onClose: @escaping CloseHandler
    ) {
        guard currentToken == token, state == .idle else { return }

        requestGeneration &+= 1
        let generation = requestGeneration
        pendingClose = onClose
        state = .preparing

        let timeout = timeoutNanoseconds
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.finishTimeout(for: token, generation: generation)
        }

        evaluate { [weak self] result in
            guard let self else { return }
            self.finishPreparation(result, for: token, generation: generation)
        }
    }

    /// Reader chose to remain in the app. During preparation this invalidates
    /// callback acceptance; after a warning it simply dismisses the warning.
    func keepEditing(for token: NativeAppCloseToken) {
        guard currentToken == token else { return }
        switch state {
        case .preparing, .warning:
            invalidatePendingRequest()
            state = .idle
        case .idle, .closing:
            return
        }
    }

    /// Preparation failure never closes implicitly. Discard is a separate,
    /// explicit reader decision available only from the warning state.
    func discardAndClose(for token: NativeAppCloseToken) {
        guard currentToken == token, case .warning = state else { return }
        closeOnce(for: token)
    }

    /// Invalidates one exact document on teardown. The surrounding presentation
    /// already owns teardown, so this never invokes the close callback itself.
    func invalidate(for token: NativeAppCloseToken) {
        guard currentToken == token else { return }
        invalidatePendingRequest()
        currentToken = nil
        state = .idle
    }

    private func finishPreparation(
        _ result: NativeAppClosePreparationResult,
        for token: NativeAppCloseToken,
        generation: UInt64
    ) {
        guard currentToken == token,
              requestGeneration == generation,
              state == .preparing else { return }

        timeoutTask?.cancel()
        timeoutTask = nil

        switch result {
        case .noHook, .ready:
            closeOnce(for: token)
        case .failed:
            state = .warning(.failed)
        }
    }

    private func finishTimeout(for token: NativeAppCloseToken, generation: UInt64) {
        guard currentToken == token,
              requestGeneration == generation,
              state == .preparing else { return }
        timeoutTask = nil
        state = .warning(.timedOut)
    }

    private func closeOnce(for token: NativeAppCloseToken) {
        guard currentToken == token,
              state != .closing,
              let close = pendingClose else { return }
        requestGeneration &+= 1
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingClose = nil
        state = .closing
        close()
    }

    private func invalidatePendingRequest() {
        requestGeneration &+= 1
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingClose = nil
    }
}

// MARK: - Full-screen session lifecycle (M7)

/// The whole visible lifetime of one full-screen mini app, from the moment
/// Home starts opening it to the moment it is fully gone. This is a second,
/// broader machine next to `NativeAppCloseLifecycle` above: that type owns
/// only the reader's decision to leave one document (the "prepare close"
/// hook, fired only once closing has already been decided); this type owns
/// which phase the session is in, including phases `NativeAppCloseLifecycle`
/// never sees at all (opening, backgrounded, exporting, saving). A real
/// integration drives both: this machine decides when `closing` may start at
/// all (never mid export or mid save), and `NativeAppCloseLifecycle` still
/// owns the one page-level "did you mean to leave" hook once it does.
///
/// Every transition is driven by one explicit `Event` the Host observed at
/// the OS boundary (SwiftUI `scenePhase`, an export session's own
/// start/finish callback, a save sheet's own start/finish callback, or the
/// reader's own close decision). This type never reads or writes project
/// data, never touches WebKit, Files, or Photos, and never starts a
/// background task itself: it only says which phase the session claims to
/// be in. "The project is unchanged" is therefore true by construction for
/// every event this type accepts, since nothing here has the capability to
/// mutate a project either way; a caller cannot forget to preserve it.
///
/// A real device force-quit is not an event this live object can ever
/// receive (the process, and this object with it, is simply gone). What
/// happens on the next launch, including "force quit between stage and
/// activate reopens the previous version", is an invariant of
/// `NativeStarterInstaller`/`NativeRevisionStore`'s stage/activate pointer
/// swap (both outside this unit's owned paths), not of this type: this
/// machine only ever starts a fresh session at `.opening` and has no memory
/// across launches, which is itself the correct behavior for a force quit.
struct NativeFullscreenSessionLifecycle: Equatable, Sendable {
    /// What the session was doing right before the OS backgrounded Iris.
    /// Recorded so foregrounding resumes the same activity instead of
    /// guessing, and so a result that arrives while backgrounded (WebKit and
    /// export/save work keep running behind the reader's back, at least
    /// briefly, under the OS's own background execution budget) is never
    /// lost.
    enum InterruptedActivity: Equatable, Sendable {
        case none
        case exporting
        case saving
    }

    enum State: Equatable, Sendable {
        case opening
        case running
        case backgrounded(InterruptedActivity)
        case exporting
        case saving
        case closing
        case closed
    }

    enum ExportOutcome: Equatable, Sendable {
        case succeeded
        case failed
    }

    enum SaveOutcome: Equatable, Sendable {
        case succeeded
        case failed(diskFull: Bool)
    }

    /// What the reader should be told the moment they next look at the
    /// screen. Cleared only by `acknowledgeResumeNotice()`, never by another
    /// event arriving, so a notice raised while backgrounded is never
    /// silently overwritten or dropped even if several OS events land
    /// before the reader looks back at the screen.
    enum ResumeNotice: Equatable, Sendable {
        case exportResumed
        case exportFinishedWhileAway(ExportOutcome)
        case saveFinishedWhileAway(SaveOutcome)
    }

    enum Event: Equatable, Sendable {
        case openFinished
        case openFailed
        case didEnterBackground
        case willEnterForeground
        case exportStarted
        case exportEnded(ExportOutcome)
        case saveStarted
        case saveEnded(SaveOutcome)
        case closeRequested
        /// The reader chose "Keep editing" after closing began (the
        /// `NativeAppCloseLifecycle` warning), so the app is running again.
        /// Added by R2-mobile-integration: without it a cancelled close left
        /// this machine in `.closing` for good, which then refused every later
        /// export start and so could no longer protect that export.
        case closeCancelled
        case closeFinished
    }

    /// One rejected transition: the event a caller tried, and the state it
    /// was tried from. Returned rather than thrown so a caller replaying a
    /// whole seeded event sequence can collect every rejection in one pass.
    /// A caller that ignores this would hide a real bug, for example a
    /// WebKit delegate firing an already-handled callback a second time.
    struct RejectedEvent: Equatable, Sendable, Error {
        let event: Event
        let state: State
    }

    private(set) var state: State = .opening
    private(set) var resumeNotice: ResumeNotice?

    init() {}

    @discardableResult
    mutating func apply(_ event: Event) -> RejectedEvent? {
        guard let next = Self.transition(state, event) else {
            return RejectedEvent(event: event, state: state)
        }
        state = next.state
        if let notice = next.notice {
            resumeNotice = notice
        }
        return nil
    }

    mutating func acknowledgeResumeNotice() {
        resumeNotice = nil
    }

    /// An export or a save is writing a file right now (foreground or not).
    var isWriting: Bool {
        switch state {
        case .exporting, .saving, .backgrounded(.exporting), .backgrounded(.saving): return true
        case .opening, .running, .backgrounded(.none), .closing, .closed: return false
        }
    }

    /// The Home control's gate (CLICK-PATH-002, wired by
    /// R2-mobile-integration). `true` means the caller may start
    /// `NativeAppCloseLifecycle.requestClose`; `false` means an export or
    /// save is still writing and the reader is told to wait. A session that
    /// never finished opening (a load failure says "Use Home to return") or
    /// is already closing never traps the reader: those always proceed.
    @discardableResult
    mutating func beginClose() -> Bool {
        switch state {
        case .opening, .closing, .closed:
            return true
        case .running, .backgrounded, .exporting, .saving:
            return apply(.closeRequested) == nil
        }
    }

    /// The pure transition table. `nil` means the event is invalid from that
    /// state and must be rejected, never silently ignored and never guessed
    /// at. In particular `closeRequested` is valid only from `.running` or a
    /// backgrounded session with nothing interrupted: never while
    /// `.exporting` or `.saving`, and never while backgrounded mid export or
    /// mid save, so a caller can never tear the session down under a
    /// project write in flight.
    private static func transition(
        _ state: State,
        _ event: Event
    ) -> (state: State, notice: ResumeNotice?)? {
        switch (state, event) {
        case (.opening, .openFinished):
            return (.running, nil)
        case (.opening, .openFailed):
            return (.closed, nil)

        case (.running, .exportStarted):
            return (.exporting, nil)
        case (.running, .saveStarted):
            return (.saving, nil)
        case (.running, .closeRequested):
            return (.closing, nil)
        case (.running, .didEnterBackground):
            return (.backgrounded(.none), nil)

        case (.exporting, .didEnterBackground):
            return (.backgrounded(.exporting), nil)
        case (.exporting, .exportEnded):
            // Already foregrounded when the result arrives: the UI observes
            // the export session's own callback directly, so no notice is
            // queued here. Only the backgrounded case below queues one.
            return (.running, nil)

        case (.saving, .didEnterBackground):
            return (.backgrounded(.saving), nil)
        case (.saving, .saveEnded):
            return (.running, nil)

        case (.backgrounded(let interrupted), .willEnterForeground):
            switch interrupted {
            case .none:
                return (.running, nil)
            case .exporting:
                return (.exporting, .exportResumed)
            case .saving:
                return (.saving, nil)
            }

        case (.backgrounded(.exporting), .exportEnded(let outcome)):
            // The export finished on its own while Iris was backgrounded and
            // the reader has not foregrounded yet. Stay backgrounded (the
            // reader's location has not changed) but remember an honest
            // result now, so it is delivered the instant they look instead
            // of the foreground path above claiming "resumed" for a task
            // that, by then, has actually already ended.
            return (.backgrounded(.none), .exportFinishedWhileAway(outcome))

        case (.backgrounded(.saving), .saveEnded(let outcome)):
            return (.backgrounded(.none), .saveFinishedWhileAway(outcome))

        case (.backgrounded(.none), .closeRequested):
            return (.closing, nil)

        case (.closing, .closeFinished):
            return (.closed, nil)
        case (.closing, .closeCancelled):
            return (.running, nil)

        default:
            return nil
        }
    }
}

import Foundation

/// Installs bundled "starter" app content on first launch through the exact
/// same review, local-approval and stage/activate path a downloaded catalog
/// package uses. It adds no separate trust decision and no bypass of hash,
/// signature, base-revision or capability checks: every package that is
/// staged still goes through `NativeShellLibraryCoordinator.reviewImportIfIdle`
/// / `approvePendingReviewLocallyAndStage` and `DeliveryPackageV1Validator`.
/// The only thing this type supplies on the owner's behalf is the
/// reader-approval tap, because these exact package bytes were already
/// reviewed by the owner before they were bundled into the app (see PLAN.md
/// section 8, item 4).
///
/// A chain is one or more packages for the same app/project, oldest first.
/// The first package's declared base revision must be `nil` (a fresh app)
/// and every later package's declared base must equal the previous
/// package's revision id, exactly like a normal sequence of catalog
/// updates. This lets the starter content carry an app forward through
/// real reviewed fixes without any special-cased "seed" path in
/// `NativeRevisionStore`.
///
/// Sharing the coordinator with the live UI: the app runs this in a
/// background task against the same coordinator the reader is using, and
/// that coordinator has a single pending-review slot. This type is a polite
/// user of that slot. It plans the chain without the slot at all, takes the
/// slot only when it is empty (never replacing a review the reader can
/// see), holds it for one step, and when the reader's own import replaces
/// its review it waits and retries instead of dropping the chain. Keeping
/// one coordinator (rather than giving the starter pass its own) is
/// deliberate: `NativeRevisionStore` relies on being the only actor
/// touching an identity's directory, and a second coordinator would create
/// a second store actor for the same starter apps the reader can open,
/// revert or update while they install.
public struct NativeStarterInstaller: Sendable {
    public struct AppChain: Sendable {
        public let displayName: String
        /// Oldest (base) package first, most recent last.
        public let orderedPackages: [Data]

        public init(displayName: String, orderedPackages: [Data]) {
            self.displayName = displayName
            self.orderedPackages = orderedPackages
        }
    }

    public enum StepOutcome: Equatable, Sendable {
        case installed(revisionId: String)
        /// The revision's bytes were already staged (for example a previous
        /// launch was killed after `stage` but before `activate`). Nothing
        /// was written again; this call only advanced the active pointer.
        case alreadyStaged(revisionId: String)
    }

    public enum AppResult: Equatable, Sendable {
        case installed([StepOutcome], finalRevisionId: String)
        /// This identity already had an installed revision (starter or
        /// real) that this chain must not move: the chain's own final
        /// revision, a revision the chain does not know, or a version the
        /// reader chose (for example by reverting). Starter content never
        /// overwrites, reorders or reactivates existing user state.
        case alreadyPresent(currentRevisionId: String)
        case failed(String)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case emptyChain(String)
        case chainNotContiguous(label: String, atIndex: Int)
        /// The reader kept their own package review open longer than
        /// `ReviewSlotWait` allows. Nothing was half-written; the chain
        /// resumes from here on a later launch.
        case readerReviewStillOpen(label: String)

        public var description: String {
            switch self {
            case .emptyChain(let label):
                return "starter chain for \(label) has no packages"
            case .chainNotContiguous(let label, let index):
                return "starter chain for \(label) is not contiguous at index \(index)"
            case .readerReviewStillOpen(let label):
                return "starter chain for \(label) stopped waiting for the reader's own package review; it resumes on a later launch"
            }
        }
    }

    /// How long one chain step waits while someone else (the reader's file
    /// import, a website install) holds the coordinator's review slot.
    /// Exponential backoff from `initialDelayNanoseconds`, capped at
    /// `maximumDelayNanoseconds`, for at most `maximumAttempts` waits per
    /// step. The default gives up after about 36 seconds of one review
    /// staying open; the whole bundled chain stays in memory while waiting,
    /// so this is deliberately not unbounded.
    public struct ReviewSlotWait: Equatable, Sendable {
        public let initialDelayNanoseconds: UInt64
        public let maximumDelayNanoseconds: UInt64
        public let maximumAttempts: Int

        public init(initialDelayNanoseconds: UInt64, maximumDelayNanoseconds: UInt64, maximumAttempts: Int) {
            self.initialDelayNanoseconds = initialDelayNanoseconds
            self.maximumDelayNanoseconds = maximumDelayNanoseconds
            self.maximumAttempts = maximumAttempts
        }

        public static let `default` = ReviewSlotWait(
            initialDelayNanoseconds: 50_000_000,
            maximumDelayNanoseconds: 1_000_000_000,
            maximumAttempts: 40
        )
    }

    private let reviewSlotWait: ReviewSlotWait

    public init(reviewSlotWait: ReviewSlotWait = .default) {
        self.reviewSlotWait = reviewSlotWait
    }

    /// Installs every chain whose identity is not already where the chain
    /// ends. Chains are processed independently: a capability or validation
    /// failure for one app (for example Kneecap's `web.media.export` on an
    /// iOS 17 device that only supports `web.storage`) never blocks the
    /// others. Safe to call on every launch; a fully-installed identity costs
    /// a local byte check of its bundled packages (off the coordinator, never
    /// touching the review slot) and one `libraryEntry` read.
    @discardableResult
    public func installMissing(
        _ chains: [String: AppChain],
        into coordinator: NativeShellLibraryCoordinator
    ) async -> [String: AppResult] {
        var results: [String: AppResult] = [:]
        for label in chains.keys.sorted() {
            let chain = chains[label]!
            do {
                results[label] = try await installChainIfMissing(label: label, chain: chain, into: coordinator)
            } catch {
                results[label] = .failed(String(describing: error))
            }
        }
        return results
    }

    /// RC-11 (round 6): sets up ONE starter from its bundled chain and reports
    /// how it went. The same steps as `installMissing` for a single label, so a
    /// Get on a starter that someone removed can re-install it in place without
    /// touching the other two. Never throws: a problem comes back as `.failed`.
    public func installOne(
        _ chain: AppChain,
        label: String,
        into coordinator: NativeShellLibraryCoordinator
    ) async -> AppResult {
        do {
            return try await installChainIfMissing(label: label, chain: chain, into: coordinator)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// A quick, read-only check of which chains still need installing,
    /// without staging anything: for each chain this runs the same shape
    /// validation `installMissing` runs (Pass 1 below) and reads the
    /// identity's current library entry exactly once (never the review
    /// slot, never a write). Safe to call before deciding whether to show
    /// any "setting up" UI at all: on a launch where every chain is already
    /// installed this returns an empty set from a handful of `libraryEntry`
    /// reads, rather than only becoming clear after `installMissing` and its
    /// slower staging work has run for every chain.
    ///
    /// A chain whose shape is invalid is reported as still needing install
    /// too, so it appears while setup runs; `installMissing` is what
    /// actually surfaces that as a `.failed` result once it runs the same
    /// check itself.
    public func stillNeeded(
        _ chains: [String: AppChain],
        into coordinator: NativeShellLibraryCoordinator
    ) async -> Set<String> {
        var needed = Set<String>()
        for label in chains.keys.sorted() {
            let chain = chains[label]!
            guard let (identity, plan) = try? planChain(label: label, chain: chain) else {
                needed.insert(label)
                continue
            }
            let entry = try? await coordinator.libraryEntry(identity: identity)
            switch position(of: entry, in: plan) {
            case .next:
                needed.insert(label)
            case .complete, .leaveAlone:
                break
            }
        }
        return needed
    }

    /// One package's identity within a chain, established by a planning
    /// pass before anything is staged.
    private struct PlannedPackage {
        let packageBytes: Data
        let revisionId: String
    }

    /// Where a chain stands, judged only from states this installer itself
    /// can leave behind.
    private enum ChainPosition {
        case next(index: Int)
        case complete(finalRevisionId: String)
        case leaveAlone(currentRevisionId: String)
    }

    /// Validates one chain's whole shape and learns every package's revision
    /// id up front, without staging anything. This runs the same
    /// `DeliveryPackageV1Validator.inspect` that `coordinator.reviewImport`
    /// runs, but directly: it writes nothing, does not occupy the
    /// coordinator actor while hashing, and never takes the coordinator's
    /// single review slot. Shared by `installChainIfMissing` (which then
    /// stages/activates) and `stillNeeded` (which only reads the current
    /// position and stages nothing), so both agree on what a chain's
    /// packages resolve to.
    private func planChain(
        label: String,
        chain: AppChain
    ) throws -> (identity: NativeShellAppIdentity, plan: [PlannedPackage]) {
        guard !chain.orderedPackages.isEmpty else { throw Failure.emptyChain(label) }
        var identity: NativeShellAppIdentity?
        var plan: [PlannedPackage] = []
        for (index, packageBytes) in chain.orderedPackages.enumerated() {
            let inspection = try DeliveryPackageV1Validator().inspect(packageBytes: packageBytes)
            let packageIdentity = NativeShellAppIdentity(appId: inspection.appId, projectId: inspection.projectId)
            if let identity, identity != packageIdentity {
                throw NativeShellLibraryError.reviewIdentityMismatch(expected: identity, actual: packageIdentity)
            }
            identity = packageIdentity
            let expectedBase = index == 0 ? nil : plan[index - 1].revisionId
            guard inspection.baseRevisionId == expectedBase else {
                throw Failure.chainNotContiguous(label: label, atIndex: index)
            }
            plan.append(PlannedPackage(packageBytes: packageBytes, revisionId: inspection.revisionId))
        }
        guard let identity else { throw Failure.emptyChain(label) }
        return (identity, plan)
    }

    private func installChainIfMissing(
        label: String,
        chain: AppChain,
        into coordinator: NativeShellLibraryCoordinator
    ) async throws -> AppResult {
        let (identity, plan) = try planChain(label: label, chain: chain)

        // Pass 2: advance one package at a time, re-reading where the
        // identity stands before every step. Re-reading (rather than
        // planning the start index once) is what lets a step that yielded
        // the review slot to the reader, or lost a race with a second
        // starter pass, pick up exactly where the store now is.
        var steps: [StepOutcome] = []
        var backoff = SlotBackoff(policy: reviewSlotWait)
        while true {
            let entry = try await coordinator.libraryEntry(identity: identity)
            let nextIndex: Int
            switch position(of: entry, in: plan) {
            case .leaveAlone(let currentRevisionId):
                return .alreadyPresent(currentRevisionId: currentRevisionId)
            case .complete(let finalRevisionId):
                return steps.isEmpty
                    ? .alreadyPresent(currentRevisionId: finalRevisionId)
                    : .installed(steps, finalRevisionId: finalRevisionId)
            case .next(let index):
                nextIndex = index
            }
            let planned = plan[nextIndex]

            // A previous launch may have staged this exact revision (real
            // bytes, real delivery nonce) and then been killed before
            // activating it - the effect of a force-quit mid-install.
            // Re-staging the identical bytes would replay that already-used
            // delivery nonce and be refused, so once this revision is
            // confirmed present on disk, skip straight to activation. Checked
            // before reviewing so an already-staged step never touches the
            // review slot.
            if let entry, entry.revisions.contains(where: { $0.revisionId == planned.revisionId }) {
                steps.append(.alreadyStaged(revisionId: planned.revisionId))
            } else {
                // Never replace a review someone else has open: the reader's
                // visible sheet, or a website install's commit.
                guard let review = try await coordinator.reviewImportIfIdle(
                    packageBytes: planned.packageBytes,
                    expectedIdentity: identity
                ) else {
                    try await backoff.wait(label: label)
                    continue
                }
                let outcome: NativeShellStageOutcome
                do {
                    outcome = try await coordinator.approvePendingReviewLocallyAndStage(
                        reviewToken: review.reviewToken,
                        packageSHA256: review.packageSHA256
                    )
                } catch NativeShellLibraryError.reviewTokenMismatch, NativeShellLibraryError.noPendingReview {
                    // The reader's own import replaced this review between
                    // the two calls. They win; retry this step once the slot
                    // is free again.
                    try await backoff.wait(label: label)
                    continue
                }
                steps.append(
                    outcome.alreadyStaged
                        ? .alreadyStaged(revisionId: outcome.revisionId)
                        : .installed(revisionId: outcome.revisionId)
                )
            }

            try await coordinator.activate(identity: identity, revisionId: planned.revisionId)
            backoff.reset()
        }
    }

    /// A current revision this chain does not know is a real, foreign install
    /// (a real catalog install/import, or a different app at this identity):
    /// leave it alone. A current revision that IS one of this chain's own
    /// packages is resumed only when the fallback shows forward-only
    /// activation along the chain, the only shape an earlier interrupted
    /// launch can leave. Any other fallback means the reader chose this
    /// version themselves (for example "Use previous version" moves the
    /// newer revision into the fallback slot), and that choice stands.
    private func position(of entry: NativeShellLibraryEntry?, in plan: [PlannedPackage]) -> ChainPosition {
        guard let currentRevisionId = entry?.currentRevisionId else { return .next(index: 0) }
        guard let currentIndex = plan.firstIndex(where: { $0.revisionId == currentRevisionId }) else {
            return .leaveAlone(currentRevisionId: currentRevisionId)
        }
        if currentIndex == plan.count - 1 { return .complete(finalRevisionId: currentRevisionId) }
        let fallbackLeftByThisChain = currentIndex == 0 ? nil : plan[currentIndex - 1].revisionId
        guard entry?.fallbackRevisionId == fallbackLeftByThisChain else {
            return .leaveAlone(currentRevisionId: currentRevisionId)
        }
        return .next(index: currentIndex + 1)
    }

    private struct SlotBackoff {
        let policy: ReviewSlotWait
        private var attempts = 0
        private var nextDelay: UInt64

        init(policy: ReviewSlotWait) {
            self.policy = policy
            nextDelay = policy.initialDelayNanoseconds
        }

        mutating func reset() {
            attempts = 0
            nextDelay = policy.initialDelayNanoseconds
        }

        mutating func wait(label: String) async throws {
            guard attempts < policy.maximumAttempts else { throw Failure.readerReviewStillOpen(label: label) }
            attempts += 1
            try await Task.sleep(nanoseconds: nextDelay)
            nextDelay = nextDelay > policy.maximumDelayNanoseconds / 2
                ? policy.maximumDelayNanoseconds
                : max(nextDelay * 2, 1)
        }
    }
}

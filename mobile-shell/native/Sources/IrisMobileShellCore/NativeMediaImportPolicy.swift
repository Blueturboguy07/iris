import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Pure decision logic for bringing a picked photo or video into the app
/// through the shell's own photo picker. No file handle, clock read, or
/// UIKit type here: every time value and byte count is a parameter, so the
/// exact same decisions this type hands the Host run unchanged in a
/// `swift test` run on the Mac.
///
/// The original bug this existed to fix: a real iPhone video clip longer than
/// a few seconds was rejected because one flat 32 MB cap covered every picked
/// item, the whole session was capped at 96 MB, and any provider load that
/// took more than 15 seconds (routine for an iCloud-backed clip) was killed.
///
/// Round 3 (long-clip import, 2026-09-28): the owner asked for video imports
/// that are essentially unlimited -- a 10 minute clip, or several clips
/// combined up to an hour, must work, with free space on the device as the
/// only real ceiling. So this type now carries NO fixed video byte cap and
/// NO fixed total-session byte cap: `evaluateSize` always accepts a video,
/// and the old flat `maximumSessionBytes` is gone, replaced by
/// `evaluateSpace`/`requiredFreeBytes`, which sizes the free-space
/// requirement from the real number of full-size copies the file's bytes
/// pass through on their way from the picker into Kneecap's own storage (see
/// "Free-space derivation" below). Photos still need a real
/// memory-conscious limit (the shell's picker completion handler hands back
/// a small in-memory-friendly file either way), so images keep their small
/// cap unchanged.
///
/// The old flat 15 s / 60 s-stall-with-15-min-ceiling provider timeout is
/// also gone: `evaluateProgress` now only ever ends an import for a genuine
/// stall (no `Progress` advance for `stallThresholdSeconds`), never for
/// total elapsed time, so a slow but still-moving iCloud download is never
/// killed just for taking a while.
public enum NativeMediaImportPolicy {
    /// What the picked item actually is, decided from its UTType, never from
    /// its file extension or size.
    public enum Kind: Equatable, Sendable {
        case image
        case video
    }

    // MARK: Size limits

    /// Photos stay small; this cap is unchanged by the long-clip work. The
    /// shell's own picker completion handler always hands back a real file
    /// on disk (never holds the whole image in memory at once), but photos
    /// this large are almost always a mistake (a burst-exported panorama, a
    /// misidentified RAW/HEIC stack), so the check stays as a sanity limit,
    /// not a memory limit.
    public static let maximumImageFileBytes: Int64 = 32 * 1024 * 1024
    /// PHPickerConfiguration.selectionLimit for one picker presentation. Not
    /// a byte limit: free space is the only byte-level limit now (see
    /// `evaluateSpace`).
    public static let maximumItems = 8

    /// `nil` for video: there is no fixed byte cap. Free space
    /// (`evaluateSpace`) is the only limit on how large a video can be.
    public static func maximumFileBytes(for kind: Kind) -> Int64? {
        switch kind {
        case .image: return maximumImageFileBytes
        case .video: return nil
        }
    }

    #if canImport(UniformTypeIdentifiers)
    /// Decides image vs video from the UTType of the chosen representation,
    /// never from a file extension or a byte count.
    public static func kind(forTypeIdentifier identifier: String) -> Kind? {
        guard let type = UTType(identifier) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .video }
        if type.conforms(to: .image) { return .image }
        return nil
    }
    #endif

    public enum SizeDecision: Equatable, Sendable {
        case accepted
        case tooLarge(kind: Kind, actualBytes: Int64, maximumBytes: Int64)
    }

    /// Video is always `.accepted` here, whatever `bytes` is (there is no
    /// fixed video cap any more); only an image can be rejected by size.
    public static func evaluateSize(kind: Kind, bytes: Int64) -> SizeDecision {
        guard let maximum = maximumFileBytes(for: kind) else { return .accepted }
        guard bytes > maximum else { return .accepted }
        return .tooLarge(kind: kind, actualBytes: bytes, maximumBytes: maximum)
    }

    // MARK: Free space -- the only real limit on video size or a multi-clip
    // batch's total size.
    //
    // Free-space derivation (why `peakConcurrentCopies` is 3, not 1 or 2):
    // traced end to end across both A-media-import/HANDOFF.md and
    // kneecap-long-clips/HANDOFF.md, the picked file's bytes exist as up to
    // three separate full-size copies on disk at once, at peak, before the
    // import is "done" from the person's point of view:
    //   1. This lease's own copy (`NativeSelectedMediaLease.copySelectedFile`,
    //      what this file's `evaluateSpace` gates). A same-volume move
    //      (see `NativeSelectedMediaLease.attemptAtomicMove`) usually avoids
    //      ever creating this as a *second* copy of the source, but the
    //      free-space check below stays conservative and assumes a copy,
    //      since a move can fail (cross-volume picker-provided temp file,
    //      sandbox restriction) and silently fall back to one.
    //   2. WebKit's own copy: the moment the shell hands this lease's file to
    //      the web view's file-input open panel, WebKit copies it again into
    //      its own `tmp/WKFileUploadPanel-*` (named directly in this task's
    //      brief; not something this Core/Host code controls or can skip).
    //   3. Kneecap's own persisted copy: `OPFSAdapter.set` (fixed to stream,
    //      kneecap-long-clips/HANDOFF.md section 2) still writes one full
    //      copy of the bytes into its own OPFS/IndexedDB storage right after
    //      WebKit hands it the file, so the device needs room for that third
    //      copy too.
    // In a multi-clip batch, every item's lease copy (step 1) stays resident
    // until the whole batch commits (`NativeSelectedMediaLease` never frees a
    // batch member early), while at most one item at a time is mid-handoff
    // through steps 2 and 3. Checking each item's own bytes against three
    // full copies, every time an item is added to the running batch total,
    // is therefore a safe (if slightly conservative for very large batches)
    // bound: it never lets an import proceed that could run the device out
    // of space partway through steps 2 or 3, which -- unlike step 1's own
    // reservation bookkeeping -- this code cannot observe or roll back.
    public static let peakConcurrentCopies: Int64 = 3

    /// A flat 1 GiB margin is sensible for an ordinary clip but is a
    /// rounding error next to a 20 GB import (three copies of a 20 GB file
    /// is 60 GB; the device needs real extra headroom -- for the OS, for
    /// other apps, for the fact this can run for minutes while other things
    /// happen -- proportional to an operation that size, not a fixed 1 GiB).
    /// Scales at 5% of the projected total once that total passes 20 GiB
    /// (5% of 20 GiB is exactly the 1 GiB floor, so the two pieces meet
    /// continuously at that point); stays at the flat 1 GiB floor below it,
    /// same as before this change for any ordinary-sized import.
    public static func safetyMarginBytes(forProjectedTotalBytes total: Int64) -> Int64 {
        let floor: Int64 = 1024 * 1024 * 1024
        let scaled = total / 20
        return max(floor, scaled)
    }

    /// The free space required to safely bring `total` projected bytes
    /// through the three-copy path derived above.
    public static func requiredFreeBytes(forProjectedTotalBytes total: Int64) -> Int64 {
        total * peakConcurrentCopies + safetyMarginBytes(forProjectedTotalBytes: total)
    }

    public enum SpaceDecision: Equatable, Sendable {
        case accepted
        case insufficient(requiredBytes: Int64, availableBytes: Int64)
    }

    /// `availableBytes` is read by the caller from the lease directory's
    /// volume (`URLResourceKey.volumeAvailableCapacityForImportantUsageKey`)
    /// fresh, right before this item is copied -- so it already reflects
    /// every byte a prior item in this batch has actually consumed on disk.
    /// `alreadyCommittedBytes` is every byte already copied into this
    /// lease's *current* batch (0 for a single-item pick, or the running
    /// total for item 2, 3, ... of a multi-clip pick): it only widens the
    /// safety margin to match the whole batch's scale, it is never added a
    /// second time against `availableBytes` (that would double-count bytes
    /// the read of `availableBytes` already accounts for).
    ///
    /// This is the "one space check governing the total" required behavior:
    /// every item in a multi-clip pick is checked against a margin sized to
    /// the whole batch, not just that one file, so a combination of clips
    /// that would not safely fit is rejected together (via
    /// `NativeSelectedMediaLease`'s existing batch rollback), not left as a
    /// partial N-of-M import.
    public static func evaluateSpace(
        alreadyCommittedBytes: Int64, addingBytes: Int64, availableBytes: Int64
    ) -> SpaceDecision {
        let projectedTotal = alreadyCommittedBytes + addingBytes
        let required = addingBytes * peakConcurrentCopies + safetyMarginBytes(forProjectedTotalBytes: projectedTotal)
        guard availableBytes < required else { return .accepted }
        return .insufficient(requiredBytes: required, availableBytes: availableBytes)
    }

    // MARK: A whole picker selection, decided the same way the Host's
    // incremental reserve-then-rollback bookkeeping decides it, so a test
    // here predicts what a real multi-item pick does. Pure and
    // deterministic: `availableBytes` is a single snapshot (the real Host
    // re-reads the volume before each item; this predicts the common case
    // where nothing else on the device is writing to the volume at the same
    // time -- see the MiroFish "disk filling from another app during
    // import" scenario for the case where that assumption does not hold).

    public enum BatchRejectionReason: Equatable, Sendable {
        case tooManyItems(count: Int, maximum: Int)
        case tooLarge(kind: Kind, actualBytes: Int64, maximumBytes: Int64)
        case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    }

    public enum BatchDecision: Equatable, Sendable {
        case accepted(totalBytes: Int64)
        case rejected(failingItemIndex: Int, reason: BatchRejectionReason)
    }

    public static func evaluateBatch(
        items: [(kind: Kind, bytes: Int64)], availableBytes: Int64
    ) -> BatchDecision {
        guard items.count <= maximumItems else {
            return .rejected(
                failingItemIndex: maximumItems,
                reason: .tooManyItems(count: items.count, maximum: maximumItems)
            )
        }
        var total: Int64 = 0
        // Mirrors the real Host: `availableBytes` drops by each accepted
        // item's own bytes (the conservative assumption throughout this
        // file -- a copy, not a move -- so this never predicts more headroom
        // than the real device will actually have once earlier items in the
        // batch are really on disk). Without this, a batch could never be
        // rejected for its *combined* total, only for one item's own charge
        // against the original snapshot alone.
        var remainingAvailable = availableBytes
        for (index, item) in items.enumerated() {
            if case .tooLarge(let kind, let actualBytes, let maximumBytes) = evaluateSize(kind: item.kind, bytes: item.bytes) {
                return .rejected(failingItemIndex: index, reason: .tooLarge(kind: kind, actualBytes: actualBytes, maximumBytes: maximumBytes))
            }
            if case .insufficient(let requiredBytes, let stillAvailable) = evaluateSpace(
                alreadyCommittedBytes: total, addingBytes: item.bytes, availableBytes: remainingAvailable
            ) {
                return .rejected(failingItemIndex: index, reason: .insufficientSpace(requiredBytes: requiredBytes, availableBytes: stillAvailable))
            }
            total += item.bytes
            remainingAvailable -= item.bytes
        }
        return .accepted(totalBytes: total)
    }

    // MARK: Provider load progress (replaces the old flat 15 s timeout, and
    // -- round 3 -- drops the old 15 minute overall ceiling too: a slow but
    // still-moving iCloud download must never be killed just for taking a
    // while. Only silence (no progress at all for `stallThresholdSeconds`)
    // ends an import now.)

    public enum ProgressDecision: Equatable, Sendable {
        case keepWaiting
        case stalled
    }

    public static let stallThresholdSeconds: TimeInterval = 60

    /// `now` and `lastProgressAt` are supplied by the caller (real `Date` on
    /// the phone, a fake clock in tests) so this function never reads the
    /// wall clock itself. There is no `startedAt`/ceiling parameter any
    /// more: total elapsed time by itself is never a reason to stop.
    public static func evaluateProgress(now: TimeInterval, lastProgressAt: TimeInterval) -> ProgressDecision {
        if now - lastProgressAt >= stallThresholdSeconds { return .stalled }
        return .keepWaiting
    }

    // MARK: Waiting indicator (avoid a flash for a fast import)

    public static let waitingIndicatorDelaySeconds: TimeInterval = 1

    public static func shouldShowWaitingIndicator(elapsedSeconds: TimeInterval) -> Bool {
        elapsedSeconds >= waitingIndicatorDelaySeconds
    }

    /// One progress sheet governs a whole multi-clip pick (requirement:
    /// several clips import one after another with one progress sheet, not
    /// one per clip). Pure so the exact copy is testable without UIKit:
    /// `totalItems <= 1` (a single-item pick, or before the batch's item
    /// count is known) keeps the original one-clip wording; more than one
    /// item names which clip is in progress.
    public static func waitingIndicatorMessage(completedItems: Int, totalItems: Int) -> String {
        guard totalItems > 1 else { return "Long videos can take a minute." }
        let current = min(completedItems + 1, totalItems)
        return "Long videos can take a minute. Bringing in clip \(current) of \(totalItems)."
    }

    // MARK: Plain-language failure messages

    public enum ImportFailure: Equatable, Sendable {
        /// Kept for API completeness (`NativeSelectedMediaLease.Failure.tooLarge`
        /// is still a general shape used for images); the picker path never
        /// actually reaches this for a video any more, since `evaluateSize`
        /// always accepts one. See the "cap reinstated" mutation check in
        /// this task's HANDOFF.md for the test that would catch a regression
        /// here.
        case tooLargeVideo(actualBytes: Int64)
        case tooLargeImage(actualBytes: Int64)
        case notEnoughSpace(requiredBytes: Int64)
        case stalled
        case other
    }

    /// One plain sentence a person can act on. Carries the real size so the
    /// message can say it, using `ByteCountFormatter` so it reads the way
    /// the rest of the app already shows sizes.
    public static func message(for failure: ImportFailure) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        switch failure {
        case .tooLargeVideo(let actualBytes):
            // RC-09b / M-04 (apple-compliance AUDIT.md, REQUIRED_CHANGES.md):
            // this case is currently unreachable from the picker path
            // (`evaluateSize` always accepts video; kept only for API
            // completeness -- see this case's own doc comment), but the old
            // wording stated a fixed "up to 2 GB" cap that stopped being
            // true the moment requirement 1 removed the video cap entirely.
            // Reworded to state the real rule (the same three-copies-plus-
            // margin free-space math `evaluateSpace` actually enforces)
            // instead of a number that does not exist anywhere in this
            // codebase any more.
            let size = formatter.string(fromByteCount: actualBytes)
            return "This video is \(size). Bringing it in needs about three times its size free on your iPhone. Free up space, then try again."
        case .tooLargeImage(let actualBytes):
            let size = formatter.string(fromByteCount: actualBytes)
            return "This photo is \(size). Iris Apps can bring in photos up to 32 MB."
        case .notEnoughSpace(let requiredBytes):
            let size = formatter.string(fromByteCount: requiredBytes)
            return "Your iPhone needs about \(size) free to bring in this video. Free up space, then try again."
        case .stalled:
            return "The video stopped loading. If it is in iCloud, open it once in Photos so it downloads, then try again."
        case .other:
            return "That item could not be brought in. Pick up to 8 items and try again."
        }
    }

    /// Convenience for the common case: a rejected size decision, turned
    /// straight into the right plain-language message.
    public static func message(forRejectedSize decision: SizeDecision) -> String? {
        guard case .tooLarge(let kind, let actualBytes, _) = decision else { return nil }
        switch kind {
        case .video: return message(for: .tooLargeVideo(actualBytes: actualBytes))
        case .image: return message(for: .tooLargeImage(actualBytes: actualBytes))
        }
    }

    /// Convenience for the common case: a rejected space decision, turned
    /// straight into the right plain-language message.
    public static func message(forRejectedSpace decision: SpaceDecision) -> String? {
        guard case .insufficient(let requiredBytes, _) = decision else { return nil }
        return message(for: .notEnoughSpace(requiredBytes: requiredBytes))
    }
}

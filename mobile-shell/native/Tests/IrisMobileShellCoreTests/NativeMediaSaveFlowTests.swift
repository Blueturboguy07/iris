import XCTest
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
@testable import IrisMobileShellCore

/// Pure decision-logic tests for the export-to-Photos choice: no
/// `PHPhotoLibrary`, no `UIAlertController`, no real file. `MediaSaveFlowHarness`
/// below is a fake Photos library and a fake file system wired to
/// `NativeMediaSaveFlow` through the exact same effects the real Host acts
/// on, so a test can assert what a person would see and what the fake
/// library actually ended up holding, never a constant the test set and
/// read back. Deleting the flow's real branching (see the mutation check
/// recorded in the phone-fixes handoff) makes several of these fail.
final class NativeMediaSaveFlowTests: XCTestCase {

    // MARK: - Kind classification

    #if canImport(UniformTypeIdentifiers)
    func testVideoExtensionsClassifyAsVideo() {
        for ext in ["mp4", "mov"] {
            let type = try! XCTUnwrap(UTType(filenameExtension: ext))
            XCTAssertEqual(NativeMediaSaveKind.classify(type), .video, "extension \(ext)")
        }
    }

    func testImageExtensionsClassifyAsImage() {
        for ext in ["png", "jpg", "gif", "webp", "heic"] {
            let type = try! XCTUnwrap(UTType(filenameExtension: ext))
            XCTAssertEqual(NativeMediaSaveKind.classify(type), .image, "extension \(ext)")
        }
    }

    func testNonMediaExtensionsClassifyAsOther() {
        for ext in ["pdf", "json", "csv", "txt"] {
            let type = try! XCTUnwrap(UTType(filenameExtension: ext))
            XCTAssertEqual(NativeMediaSaveKind.classify(type), .other, "extension \(ext)")
        }
    }
    #endif

    // MARK: - A video/image classification is not proof Photos can import it

    func testEffectiveKindDowngradesAVideoOrImagePhotosCannotActuallyImportToOther() {
        // A web export can be `.mp4`/`.webm` with a codec (VP9/Opus WebM
        // in particular) Photos does not support. `classify` only reads
        // the file extension/UTType; `effectiveKind` is what the Host
        // actually acts on, folding in a real Photos-compatibility check
        // (`UIVideoAtPathIsCompatibleWithSavedPhotosAlbum` for video) so
        // "Save to Photos" is never offered for a save that would only
        // fail.
        XCTAssertEqual(NativeMediaSaveKind.effectiveKind(rawKind: .video, isPhotosCompatible: false), .other)
        XCTAssertEqual(NativeMediaSaveKind.effectiveKind(rawKind: .video, isPhotosCompatible: true), .video)
        XCTAssertEqual(NativeMediaSaveKind.effectiveKind(rawKind: .image, isPhotosCompatible: false), .other)
        XCTAssertEqual(NativeMediaSaveKind.effectiveKind(rawKind: .image, isPhotosCompatible: true), .image)
        XCTAssertEqual(NativeMediaSaveKind.effectiveKind(rawKind: .other, isPhotosCompatible: false), .other)
        XCTAssertEqual(NativeMediaSaveKind.effectiveKind(rawKind: .other, isPhotosCompatible: true), .other)
    }

    func testAnIncompatibleWebmLikeExportGoesStraightToFilesNotThePhotosChoice() {
        let downgradedKind = NativeMediaSaveKind.effectiveKind(rawKind: .video, isPhotosCompatible: false)
        let harness = MediaSaveFlowHarness(kind: downgradedKind)
        let effects = harness.send(.start)
        XCTAssertEqual(effects, [.presentFilesPicker], "an unimportable video must go straight to Files, never the Photos choice")
        XCTAssertEqual(harness.flow.step, .none)
        XCTAssertEqual(harness.library.requestAuthorizationCallCount, 0)
    }

    // MARK: - Copy

    func testCopyNeverContainsAnEmDash() {
        let strings = [
            NativeMediaSaveCopy.choiceTitle(for: .video),
            NativeMediaSaveCopy.choiceTitle(for: .image),
            NativeMediaSaveCopy.saveToPhotosButton,
            NativeMediaSaveCopy.saveToFilesButton,
            NativeMediaSaveCopy.cancelButton,
            NativeMediaSaveCopy.savedTitle,
            NativeMediaSaveCopy.openPhotosButton,
            NativeMediaSaveCopy.doneButton,
            NativeMediaSaveCopy.accessUnavailableMessage,
            NativeMediaSaveCopy.openSettingsButton,
            NativeMediaSaveCopy.saveFailedMessage,
            NativeMediaSaveCopy.photosLibraryUsageDescription,
        ]
        for string in strings {
            XCTAssertFalse(string.contains("\u{2014}"), "em dash in: \(string)")
        }
    }

    func testChoiceTitleNamesTheKind() {
        XCTAssertEqual(NativeMediaSaveCopy.choiceTitle(for: .video), "Your video is ready")
        XCTAssertEqual(NativeMediaSaveCopy.choiceTitle(for: .image), "Your photo is ready")
    }

    // MARK: - A non-media file goes straight to Files, unchanged

    func testNonMediaFileGoesStraightToFilesWithoutEverShowingAChoice() {
        let harness = MediaSaveFlowHarness(kind: .other)
        let effects = harness.send(.start)
        XCTAssertEqual(effects, [.presentFilesPicker])
        XCTAssertEqual(harness.flow.step, .none)
        XCTAssertEqual(harness.library.requestAuthorizationCallCount, 0)
        XCTAssertEqual(harness.library.performSaveCallCount, 0)
    }

    // MARK: - P1: a non-technical person taps the first button

    func testP1TapsSaveToPhotosAndEndsWithTheVideoSavedAndTheSavedStepShown() {
        let harness = MediaSaveFlowHarness(kind: .video)
        harness.send(.start)
        XCTAssertEqual(harness.flow.step, .choice(.video))

        harness.send(.tapSaveToPhotos)
        harness.resolveAuthorization(.authorized)
        let saveEffects = harness.resolveSave()

        XCTAssertEqual(harness.library.savedAssets, [harness.fileURL])
        XCTAssertEqual(harness.flow.step, .saved)
        XCTAssertEqual(harness.fileSystem.removeCallCount, 0, "the temp file must still exist while Saved to Photos is on screen")
        XCTAssertEqual(
            saveEffects, [.cancelAbandonmentTimeout],
            "once the file is safely in Photos, the Host's own abandonment timer must stop, or a person who leaves "
                + "Saved to Photos on screen a while would wrongly see the export reported as timed out"
        )

        harness.send(.tapDone)
        XCTAssertEqual(harness.fileSystem.removeCallCount, 1)
        XCTAssertFalse(harness.fileSystem.fileExists(harness.fileURL))
    }

    func testOnlyASuccessfulSaveCancelsTheAbandonmentTimeout() {
        // The timeout must keep protecting the still-unsaved temp file in
        // every other outcome: denied access and a save that throws both
        // still legitimately want it armed while the person decides.
        do {
            let harness = MediaSaveFlowHarness(kind: .video)
            harness.send(.start)
            harness.send(.tapSaveToPhotos)
            let effects = harness.resolveAuthorization(.denied)
            XCTAssertFalse(effects.contains(.cancelAbandonmentTimeout))
        }
        do {
            let harness = MediaSaveFlowHarness(kind: .video)
            harness.library.saveShouldThrow = true
            harness.send(.start)
            harness.send(.tapSaveToPhotos)
            harness.resolveAuthorization(.authorized)
            let effects = harness.resolveSave()
            XCTAssertFalse(effects.contains(.cancelAbandonmentTimeout))
        }
    }

    func testOpenPhotosAlsoEndsTheFlowAndOpensPhotos() {
        let harness = MediaSaveFlowHarness(kind: .image)
        harness.send(.start)
        harness.send(.tapSaveToPhotos)
        harness.resolveAuthorization(.authorized)
        harness.resolveSave()
        let effects = harness.send(.tapOpenPhotos)
        XCTAssertEqual(effects, [.openPhotosApp, .finish])
        XCTAssertEqual(harness.fileSystem.removeCallCount, 1)
    }

    // MARK: - P2: a hurried double tap on Save to Photos

    func testP2HurriedDoubleTapSavesExactlyOnceAndCleansUpExactlyOnce() {
        let harness = MediaSaveFlowHarness(kind: .video)
        harness.send(.start)

        harness.send(.tapSaveToPhotos)
        // The permission sheet has not resolved yet; a hurried second tap
        // lands while still `.saving`.
        let secondTapEffects = harness.send(.tapSaveToPhotos)
        XCTAssertEqual(secondTapEffects, [], "a second tap while still awaiting authorization must do nothing")
        XCTAssertEqual(harness.library.requestAuthorizationCallCount, 1)

        harness.resolveAuthorization(.authorized)
        // The save itself has not resolved yet; a third tap lands here too.
        let thirdTapEffects = harness.send(.tapSaveToPhotos)
        XCTAssertEqual(thirdTapEffects, [], "a tap while the save itself is running must do nothing")

        harness.resolveSave()
        XCTAssertEqual(harness.library.performSaveCallCount, 1)
        XCTAssertEqual(harness.library.savedAssets, [harness.fileURL])
        XCTAssertEqual(harness.flow.step, .saved)

        harness.send(.tapDone)
        harness.send(.tapDone) // a hurried second Done tap
        XCTAssertEqual(harness.fileSystem.removeCallCount, 1)
    }

    // MARK: - P3: denied access offers Settings, keeps the file until chosen

    func testP3DeniedAccessOffersSettingsAndFilesKeepsFileUntilChosenThenCleansUpOnce() {
        let harness = MediaSaveFlowHarness(kind: .image)
        harness.send(.start)
        harness.send(.tapSaveToPhotos)
        harness.resolveAuthorization(.denied)

        XCTAssertEqual(harness.flow.step, .accessUnavailable)
        XCTAssertTrue(harness.fileSystem.fileExists(harness.fileURL), "the temp file is kept while the person is still deciding")
        XCTAssertEqual(harness.fileSystem.removeCallCount, 0)
        XCTAssertEqual(harness.library.savedAssets, [], "nothing was ever saved to the fake library")

        harness.send(.tapCancel)
        harness.send(.tapCancel) // a hurried second cancel
        XCTAssertFalse(harness.fileSystem.fileExists(harness.fileURL))
        XCTAssertEqual(harness.fileSystem.removeCallCount, 1)
    }

    func testEveryInadequateAuthorizationStatusOffersTheSameAccessUnavailableStep() {
        for status: NativeMediaSaveAuthorization in [.denied, .restricted, .limited, .notDetermined] {
            let harness = MediaSaveFlowHarness(kind: .video)
            harness.send(.start)
            harness.send(.tapSaveToPhotos)
            harness.resolveAuthorization(status)
            XCTAssertEqual(harness.flow.step, .accessUnavailable, "status \(status)")
        }
    }

    func testAccessUnavailableSaveToFilesHandsOffToTheExistingFilesFlowWithoutCleaningUpYet() {
        let harness = MediaSaveFlowHarness(kind: .video)
        harness.send(.start)
        harness.send(.tapSaveToPhotos)
        harness.resolveAuthorization(.restricted)
        let effects = harness.send(.tapSaveToFiles)
        XCTAssertEqual(effects, [.presentFilesPicker])
        // Ownership of the file now belongs to the existing, unchanged
        // Files picker flow, which cleans it up itself; this flow does
        // not additionally clean it up.
        XCTAssertEqual(harness.fileSystem.removeCallCount, 0)
    }

    func testAccessUnavailableOpenSettingsOpensSettingsAndEndsTheFlow() {
        let harness = MediaSaveFlowHarness(kind: .video)
        harness.send(.start)
        harness.send(.tapSaveToPhotos)
        harness.resolveAuthorization(.denied)
        let effects = harness.send(.tapOpenSettings)
        XCTAssertEqual(effects, [.openSettings, .finish])
        XCTAssertEqual(harness.fileSystem.removeCallCount, 1)
    }

    // MARK: - A save that throws for some other reason

    func testSaveFailureShowsOneMessageAndOffersFilesOrCancel() {
        let harness = MediaSaveFlowHarness(kind: .video)
        harness.library.saveShouldThrow = true
        harness.send(.start)
        harness.send(.tapSaveToPhotos)
        harness.resolveAuthorization(.authorized)
        harness.resolveSave()

        XCTAssertEqual(harness.flow.step, .saveFailed)
        XCTAssertEqual(harness.library.savedAssets, [])
        XCTAssertEqual(harness.fileSystem.removeCallCount, 0, "the file is kept so Save to Files can still use it")

        let effects = harness.send(.tapSaveToFiles)
        XCTAssertEqual(effects, [.presentFilesPicker])
        XCTAssertEqual(harness.fileSystem.removeCallCount, 0)
    }

    func testSaveFailureCancelCleansUpExactlyOnce() {
        let harness = MediaSaveFlowHarness(kind: .image)
        harness.library.saveShouldThrow = true
        harness.send(.start)
        harness.send(.tapSaveToPhotos)
        harness.resolveAuthorization(.authorized)
        harness.resolveSave()
        harness.send(.tapCancel)
        harness.send(.tapCancel)
        XCTAssertEqual(harness.fileSystem.removeCallCount, 1)
    }

    // MARK: - Choice-level Files and Cancel (no Photos attempt at all)

    func testChoiceSaveToFilesNeverTouchesThePhotosLibrary() {
        let harness = MediaSaveFlowHarness(kind: .video)
        harness.send(.start)
        let effects = harness.send(.tapSaveToFiles)
        XCTAssertEqual(effects, [.presentFilesPicker])
        XCTAssertEqual(harness.library.requestAuthorizationCallCount, 0)
        XCTAssertEqual(harness.fileSystem.removeCallCount, 0)
    }

    func testChoiceCancelCleansUpAndNeverTouchesThePhotosLibrary() {
        let harness = MediaSaveFlowHarness(kind: .video)
        harness.send(.start)
        let effects = harness.send(.tapCancel)
        XCTAssertEqual(effects, [.finish])
        XCTAssertEqual(harness.library.requestAuthorizationCallCount, 0)
        XCTAssertEqual(harness.fileSystem.removeCallCount, 1)
    }

    // MARK: - A second export attempting to restart an open choice

    func testASecondStartWhileTheChoiceIsAlreadyOpenDoesNothing() {
        // The cross-session guard that stops a second WKDownload from
        // being accepted while one export is already in flight lives in
        // `NativeMediaExportSessionDecision.candidateAction` (unchanged by
        // this feature). This is this flow's own half of that guarantee:
        // even if something called `.start` again on the same flow while
        // its choice is already open, for example a duplicate delegate
        // callback, it would not reset or duplicate anything.
        var flow = NativeMediaSaveFlow(kind: .video)
        XCTAssertEqual(flow.handle(.start), [])
        XCTAssertEqual(flow.step, .choice(.video))
        XCTAssertEqual(flow.handle(.start), [])
        XCTAssertEqual(flow.step, .choice(.video))
    }

    // MARK: - Nothing happens after the flow is finished (backgrounding, stray callbacks)

    func testEventsAfterFinishAreIgnored() {
        let harness = MediaSaveFlowHarness(kind: .video)
        harness.send(.start)
        harness.send(.tapCancel)
        XCTAssertEqual(harness.fileSystem.removeCallCount, 1)

        // A late authorization or save result arriving after the export
        // already tore down (for example the app was backgrounded and the
        // session was closed) must not resurrect the flow or clean up a
        // second time.
        XCTAssertEqual(harness.send(.authorizationResolved(.authorized)), [])
        XCTAssertEqual(harness.send(.saveSucceeded), [])
        XCTAssertEqual(harness.send(.tapDone), [])
        XCTAssertEqual(harness.fileSystem.removeCallCount, 1)
        XCTAssertEqual(harness.flow.step, .none)
    }

    func testASecondStartAfterFinishDoesNotRestartTheFlow() {
        // `.none` is both the step before the flow ever starts and the
        // step every terminal transition leaves it in, so only the
        // private `isFinished` flag tells "never started" apart from
        // "already finished". A stray extra `.start` after Cancel, Done,
        // or a Files handoff must not reopen the choice or clean up the
        // temp file a second time.
        let harness = MediaSaveFlowHarness(kind: .video)
        harness.send(.start)
        harness.send(.tapCancel)
        XCTAssertEqual(harness.fileSystem.removeCallCount, 1)
        XCTAssertEqual(harness.flow.step, .none)

        let effects = harness.send(.start)
        XCTAssertEqual(effects, [], "a start after the flow already finished must do nothing")
        XCTAssertEqual(harness.flow.step, .none, "it must not reopen the choice")
        XCTAssertEqual(harness.fileSystem.removeCallCount, 1, "it must not clean up a second time")
    }
}

// MARK: - Test fakes

/// A fake `PHPhotoLibrary` boundary. Every call is counted so a test can
/// assert exactly how many times the real Host would have talked to
/// PhotoKit, and `savedAssets` is the fake library's own contents, not a
/// constant the test sets and reads back.
private final class FakePhotosLibrary {
    enum Failure: Error { case saveThrew }

    var saveShouldThrow = false
    private(set) var requestAuthorizationCallCount = 0
    private(set) var performSaveCallCount = 0
    private(set) var savedAssets: [URL] = []

    /// Records that the real Host would have called
    /// `PHPhotoLibrary.requestAuthorization(for: .addOnly)` right now. The
    /// call and its result are two different moments in real, asynchronous
    /// life (the whole point of the P2 test below), so this only counts
    /// the call; the result is supplied later, explicitly, by
    /// `MediaSaveFlowHarness.resolveAuthorization`.
    func recordAuthorizationRequest() {
        requestAuthorizationCallCount += 1
    }

    func performSave(fileURL: URL) throws {
        performSaveCallCount += 1
        if saveShouldThrow { throw Failure.saveThrew }
        savedAssets.append(fileURL)
    }
}

/// A fake temporary-export-file boundary standing in for the real lease
/// directory `NativeMediaExportSession.finish` deletes.
private final class FakeFileSystem {
    private(set) var removeCallCount = 0
    private var existingFiles: Set<URL>

    init(fileURL: URL) {
        existingFiles = [fileURL]
    }

    func removeItem(at url: URL) {
        removeCallCount += 1
        existingFiles.remove(url)
    }

    func fileExists(_ url: URL) -> Bool {
        existingFiles.contains(url)
    }
}

/// Drives `NativeMediaSaveFlow` against the fakes above through exactly
/// the effects the real Host acts on. Authorization and save results are
/// resolved on demand (`resolveAuthorization`/`resolveSave`), never
/// automatically, so a test can interleave extra taps into the exact
/// window where the real async call would still be outstanding, which is
/// the window a hurried double tap actually lands in.
private final class MediaSaveFlowHarness {
    let fileURL = URL(fileURLWithPath: "/tmp/iris-media-export-fixture/export.bin")
    private(set) var flow: NativeMediaSaveFlow
    let library = FakePhotosLibrary()
    let fileSystem: FakeFileSystem
    private var pendingAuthorizationRequests = 0
    private var pendingSaveRequests = 0

    init(kind: NativeMediaSaveKind) {
        flow = NativeMediaSaveFlow(kind: kind)
        fileSystem = FakeFileSystem(fileURL: fileURL)
    }

    @discardableResult
    func send(_ event: NativeMediaSaveEvent) -> [NativeMediaSaveEffect] {
        let effects = flow.handle(event)
        for effect in effects {
            switch effect {
            case .requestAddOnlyAuthorization:
                pendingAuthorizationRequests += 1
                library.recordAuthorizationRequest()
            case .performSave:
                pendingSaveRequests += 1
            case .presentFilesPicker, .openPhotosApp, .openSettings, .cancelAbandonmentTimeout:
                break
            case .finish:
                fileSystem.removeItem(at: fileURL)
            }
        }
        return effects
    }

    @discardableResult
    func resolveAuthorization(_ status: NativeMediaSaveAuthorization) -> [NativeMediaSaveEffect] {
        guard pendingAuthorizationRequests > 0 else {
            XCTFail("no authorization request is outstanding")
            return []
        }
        pendingAuthorizationRequests -= 1
        return send(.authorizationResolved(status))
    }

    @discardableResult
    func resolveSave() -> [NativeMediaSaveEffect] {
        guard pendingSaveRequests > 0 else {
            XCTFail("no save request is outstanding")
            return []
        }
        pendingSaveRequests -= 1
        do {
            try library.performSave(fileURL: fileURL)
            return send(.saveSucceeded)
        } catch {
            return send(.saveFailed)
        }
    }
}

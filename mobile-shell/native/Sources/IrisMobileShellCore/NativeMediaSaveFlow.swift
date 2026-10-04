import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Whether an exported file is a video, a photo, or something else. Only a
/// video or a photo export offers to save into Photos; every other file
/// type keeps the shell's existing Files-only Save sheet unchanged.
public enum NativeMediaSaveKind: Equatable, Sendable {
    case video
    case image
    case other

    #if canImport(UniformTypeIdentifiers)
    /// Matches the product decision exactly: a type that conforms to
    /// `.movie` or `.audiovisualContent` is a video, a type that conforms
    /// to `.image` is a photo, anything else is left alone.
    public static func classify(_ type: UTType) -> NativeMediaSaveKind {
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .video }
        if type.conforms(to: .image) { return .image }
        return .other
    }
    #endif

    /// The kind that should actually drive the choice, once the Host also
    /// knows whether Photos can really accept this exact file. A file's
    /// extension/UTType alone is not proof Photos can import it (a web
    /// export can be `.mp4`/`.webm` with a codec, like VP9/Opus WebM,
    /// Photos does not support), so a `.video`/`.image` classification is
    /// downgraded to `.other` (straight to Files, exactly like a file
    /// this shell never recognized) whenever the Host's own
    /// Photos-compatibility check says no. This keeps "offer Save to
    /// Photos" and "Photos can actually take it" from ever disagreeing:
    /// nobody taps the first button only to land on a save failure that
    /// was foreseeable before the choice was ever shown.
    public static func effectiveKind(rawKind: NativeMediaSaveKind, isPhotosCompatible: Bool) -> NativeMediaSaveKind {
        rawKind != .other && !isPhotosCompatible ? .other : rawKind
    }
}

/// Mirrors the outcomes `PHPhotoLibrary.requestAuthorization(for: .addOnly)`
/// can report, without this file importing PhotoKit. Keeping the Photos
/// framework out of this type is what lets it run under `swift test` on
/// the Mac; the Host layer maps the real `PHAuthorizationStatus` onto this
/// enum at the one call site that talks to PhotoKit.
public enum NativeMediaSaveAuthorization: Equatable, Sendable {
    case authorized
    case limited
    case denied
    case restricted
    case notDetermined

    /// Only a full add-only grant lets the save proceed. A person who has
    /// only ever granted the read/write "Limited Photos" selection, or who
    /// has not answered yet, is treated the same as an outright refusal:
    /// the shell asks once, then either it can save or it plainly cannot.
    public var permitsSave: Bool { self == .authorized }
}

/// What the person is looking at right now for one export's save choice.
public enum NativeMediaSaveStep: Equatable, Sendable {
    /// "Your video is ready" / "Your photo is ready", offering Save to
    /// Photos (first and default), Save to Files and Cancel.
    case choice(NativeMediaSaveKind)
    /// The add-only Photos permission prompt or the save itself is under
    /// way. No button from `choice` is shown again while this is current,
    /// so a second, hurried tap on it cannot start a second save.
    case saving
    /// "Saved to Photos", offering Open Photos and Done.
    case saved
    /// Access is off (denied, restricted, limited, or never decided).
    /// Offers Save to Files, Open Settings and Cancel.
    case accessUnavailable
    /// The save failed for a reason other than access. Offers Save to
    /// Files and Cancel.
    case saveFailed
    /// Nothing of this flow's own is on screen: either the file was never
    /// a photo or video, so the shell went straight to the existing Files
    /// sheet, or the flow already reached one of its endings.
    case none
}

/// Something that happened: a button tap, or an async result coming back
/// from PhotoKit. The Host is the only caller; tests drive this directly.
public enum NativeMediaSaveEvent: Equatable, Sendable {
    case start
    case tapSaveToPhotos
    case tapSaveToFiles
    case tapCancel
    case authorizationResolved(NativeMediaSaveAuthorization)
    case saveSucceeded
    case saveFailed
    case tapOpenPhotos
    case tapOpenSettings
    case tapDone
}

/// One thing the Host must actually do in response to an event. Each case
/// here has exactly one real counterpart: an add-only authorization
/// request, one `PHPhotoLibrary.performChanges` call, presenting the
/// existing (unchanged) Files picker, opening Photos or Settings through
/// `UIApplication`, or concluding the export exactly like today (the
/// existing `NativeMediaExportSession.finish` call, which is what actually
/// deletes the temporary export file and completes the web page's download
/// callback exactly once).
public enum NativeMediaSaveEffect: Equatable, Sendable {
    case requestAddOnlyAuthorization
    case performSave(kind: NativeMediaSaveKind)
    case presentFilesPicker
    case openPhotosApp
    case openSettings
    /// The file is already safely copied into Photos: the Host's
    /// abandonment safety-net timer (armed so a person who walks away
    /// from the choice or the permission prompt does not keep the
    /// temporary export file around forever) must stop now. Left running,
    /// it would fire "The export timed out without a confirmed save"
    /// after a person leaves "Saved to Photos" on screen a while, which
    /// contradicts the save that already happened.
    case cancelAbandonmentTimeout
    case finish
}

/// Pure decision logic for what the person sees, and what the Host must
/// do, after one export finishes downloading. No file handle, no
/// `PHPhotoLibrary`, no `UIAlertController`; every real side effect the
/// Host performs is named once in `NativeMediaSaveEffect` and handed back
/// from `handle(_:)`, so this type can be driven directly by a fake Photos
/// library and a fake file system in a test and by the real ones in the
/// app, from the exact same state machine.
///
/// Every state this type can reach is terminal exactly once: the first
/// event that reaches a "this is decided" transition (Cancel, Done, a
/// files handoff, Open Settings) marks the flow finished, and every event
/// after that returns no effects and leaves `step` unchanged. That single
/// rule is what makes a hurried double tap on the same button, or a save
/// result that arrives after the person already backed out, produce
/// exactly one `.finish`, exactly one `.performSave`, and exactly one
/// `.requestAddOnlyAuthorization` no matter how many times the Host calls
/// `handle(_:)`.
public struct NativeMediaSaveFlow: Equatable, Sendable {
    public let kind: NativeMediaSaveKind
    public private(set) var step: NativeMediaSaveStep = .none
    private var isFinished = false

    public init(kind: NativeMediaSaveKind) {
        self.kind = kind
    }

    @discardableResult
    public mutating func handle(_ event: NativeMediaSaveEvent) -> [NativeMediaSaveEffect] {
        guard !isFinished else { return [] }
        switch (step, event) {
        case (.none, .start):
            if kind == .other {
                isFinished = true
                return [.presentFilesPicker]
            }
            step = .choice(kind)
            return []

        case (.choice, .tapSaveToPhotos):
            step = .saving
            return [.requestAddOnlyAuthorization]

        case (.choice, .tapSaveToFiles):
            isFinished = true
            step = .none
            return [.presentFilesPicker]

        case (.choice, .tapCancel):
            isFinished = true
            step = .none
            return [.finish]

        case (.saving, .authorizationResolved(let status)):
            if status.permitsSave {
                return [.performSave(kind: kind)]
            }
            step = .accessUnavailable
            return []

        case (.saving, .saveSucceeded):
            step = .saved
            return [.cancelAbandonmentTimeout]

        case (.saving, .saveFailed):
            step = .saveFailed
            return []

        case (.accessUnavailable, .tapSaveToFiles):
            isFinished = true
            step = .none
            return [.presentFilesPicker]

        case (.accessUnavailable, .tapOpenSettings):
            isFinished = true
            step = .none
            return [.openSettings, .finish]

        case (.accessUnavailable, .tapCancel):
            isFinished = true
            step = .none
            return [.finish]

        case (.saved, .tapOpenPhotos):
            isFinished = true
            step = .none
            return [.openPhotosApp, .finish]

        case (.saved, .tapDone):
            isFinished = true
            step = .none
            return [.finish]

        case (.saveFailed, .tapSaveToFiles):
            isFinished = true
            step = .none
            return [.presentFilesPicker]

        case (.saveFailed, .tapCancel):
            isFinished = true
            step = .none
            return [.finish]

        default:
            // Anything else is either a stray duplicate of an event this
            // exact step already consumed (a second "Save to Photos"
            // while still `.saving`, a second "Done" once already
            // finished) or a callback that arrived for a step the person
            // already left, for example an authorization result coming
            // back after the whole export was torn down. Both are
            // ignored rather than acted on again.
            return []
        }
    }
}

/// The exact, plain-language copy for this flow's alerts. Centralized so
/// the Host never re-types it and a test can check it word for word. One
/// idea per sentence; no em dash anywhere.
public enum NativeMediaSaveCopy {
    public static func choiceTitle(for kind: NativeMediaSaveKind) -> String {
        switch kind {
        case .video: return "Your video is ready"
        case .image: return "Your photo is ready"
        case .other: return ""
        }
    }

    public static let saveToPhotosButton = "Save to Photos"
    public static let saveToFilesButton = "Save to Files"
    public static let cancelButton = "Cancel"

    public static let savedTitle = "Saved to Photos"
    public static let openPhotosButton = "Open Photos"
    public static let doneButton = "Done"

    public static let accessUnavailableMessage =
        "Iris Apps can't save to Photos because access is off. "
        + "You can turn it on in Settings, or save to Files instead."
    public static let openSettingsButton = "Open Settings"

    public static let saveFailedMessage =
        "Iris Apps could not save this to Photos. You can try Files instead."

    public static let photosLibraryUsageDescription =
        "Iris Apps saves videos and photos you export to your Photos library."
}

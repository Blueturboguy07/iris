//
//  OverlayEyeInputBarDropTarget.swift
//  leanring-buddy
//
//  Dragging a screenshot onto the bar, and the reason it could not be done.
//
//  THE REPORT (Sep 3 2026): "i cant drag and drop screenshots into it because
//  when i click off it closes." Exactly right, and by design up to now: the
//  bar's click-outside monitor dismissed it on the LEFT MOUSE DOWN of any click
//  in another app. A drag starts with that same mouse down — on a Finder icon,
//  on the floating screenshot thumbnail — so the bar was gone before the
//  reader's hand had moved. There was nothing to drop onto.
//
//  MEASURED, NOT ASSUMED. A two-process harness (a drag source in one process,
//  a drop target with Iris's global monitor in another, driven by real CGEvents
//  through the window server) established what the monitor actually sees while
//  another app runs a drag session:
//
//      leftMouseDown              seen, drag pasteboard changeCount unchanged
//      leftMouseDragged (x20)     seen; changeCount moved on the SECOND one
//      draggingEntered (ours)     ~500ms before the release
//      leftMouseUp                seen — 4ms BEFORE performDragOperation
//      performDragOperation       the drop, last
//
//  So deferring the dismissal from the press to the release is not enough on
//  its own: the release still lands before the drop and would tear the bar
//  down with the file in mid-air. Two earlier signals settle it, and this file
//  uses both: the bar's own `draggingEntered` (a drag is over us — the release
//  is going to be a drop), and the system drag pasteboard's change count (a
//  drag session began somewhere since the press — this is not a click). A
//  press that was never followed by either is a plain click outside, and the
//  bar goes away on its release exactly as it used to on its press. Nobody can
//  see the difference in a click; everybody can see it in a drag.
//
//  A RIGHT click is never the start of a drag and still dismisses at once.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Deciding whether a click outside was a click

/// The rule for "a click outside the bar dismisses it", made drag-aware. Plain
/// values in, a decision out, so the rule is testable without a window, a
/// monitor, or a mouse.
struct OverlayEyeInputBarClickOutsideDismissal: Equatable {

    enum Decision: Equatable {
        case keepTheBar
        case dismissTheBar
    }

    /// True between a left press outside the bar and its release.
    private(set) var aPressOutsideTheBarIsPending = false

    /// `NSPasteboard(name: .drag).changeCount` at the press. Any drag session
    /// on the system — in Finder, in a browser, in the screenshot thumbnail —
    /// writes to that pasteboard and moves the count, and it is readable from
    /// every process.
    private var dragPasteboardChangeCountAtThePress = 0

    /// Set by the bar's own drop target when a drag crosses into it.
    private var aDragEnteredTheBarSinceThePress = false

    init() {}

    /// The left button went down somewhere that is not the bar. Nothing is
    /// decided yet — the release decides.
    mutating func readerPressedTheLeftButtonOutsideTheBar(dragPasteboardChangeCount: Int) {
        aPressOutsideTheBarIsPending = true
        dragPasteboardChangeCountAtThePress = dragPasteboardChangeCount
        aDragEnteredTheBarSinceThePress = false
    }

    /// A drag session's pointer entered the bar's window. From here the
    /// pending press can only be the start of a drop, never a click.
    mutating func aDragEnteredTheBar() {
        aDragEnteredTheBarSinceThePress = true
    }

    /// The left button came up. This is the moment the old press-time decision
    /// moves to, with the two drag signals consulted first.
    mutating func readerReleasedTheLeftButton(dragPasteboardChangeCount: Int) -> Decision {
        guard aPressOutsideTheBarIsPending else { return .keepTheBar }
        let aDragSessionBeganSinceThePress = dragPasteboardChangeCount != dragPasteboardChangeCountAtThePress
        let thePressWasTheStartOfADrag = aDragEnteredTheBarSinceThePress || aDragSessionBeganSinceThePress
        theBarWentAwayOrTheGestureEnded()
        return thePressWasTheStartOfADrag ? .keepTheBar : .dismissTheBar
    }

    /// Back to the resting state: the bar was hidden, or a gesture completed.
    mutating func theBarWentAwayOrTheGestureEnded() {
        aPressOutsideTheBarIsPending = false
        aDragEnteredTheBarSinceThePress = false
    }
}

// MARK: - The drop, in SwiftUI

/// The bar accepts a drop through SwiftUI's own `.onDrop`, NOT an AppKit view.
///
/// The first cut subclassed `NSHostingView` and registered for dragged types
/// on it. The types registered, the subclass WAS the panel's content view, and
/// the drop still never arrived: `NSHostingView` runs SwiftUI's own dragging
/// destination on internal subviews that sit in front of the host's own
/// methods, so the drag was caught there (and refused, there being no SwiftUI
/// `.onDrop`) before any override could run. Measured live — the callbacks
/// never fired while `registeredDraggedTypes` was full. So the drop is wired
/// the way the host is already listening for: a `DropDelegate` on the bar.
///
/// The dismissal fix does NOT depend on this: a drag onto the bar is kept
/// alive by the drag pasteboard's change count moving since the press
/// (`OverlayEyeInputBarClickOutsideDismissal`), which needs no cooperation
/// from the drop target at all. This delegate only turns an accepted drop into
/// attachments and lights the "drop to attach" state while a drag is over the
/// bar.
struct OverlayEyeBarDropDelegate: DropDelegate {

    let attachment: OverlayEyePastedImageAttachment

    /// The content types worth trying to load from a dropped item, image data
    /// first (a browser image, a screenshot thumbnail's promise) then a file
    /// URL (Finder, the desktop). `public.image` covers every concrete image
    /// UTI, which is what a promise usually advertises.
    static let droppedContentTypes: [UTType] = [.image, .fileURL]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.droppedContentTypes)
    }

    func dropEntered(info: DropInfo) {
        attachment.aDragIsHoveringOverTheBar = true
    }

    func dropExited(info: DropInfo) {
        attachment.aDragIsHoveringOverTheBar = false
    }

    func performDrop(info: DropInfo) -> Bool {
        attachment.aDragIsHoveringOverTheBar = false
        let providers = info.itemProviders(for: Self.droppedContentTypes)
        guard !providers.isEmpty else { return false }
        for provider in providers.prefix(OverlayEyePastedImageReader.mostImagesOneMessageMayCarry) {
            loadOneImage(from: provider)
        }
        return true
    }

    /// Image DATA first (works for a browser drag and a screenshot thumbnail's
    /// promise without ever touching disk); a file URL is the fallback for a
    /// Finder drag, read through the same file reader a picked file uses.
    private func loadOneImage(from provider: NSItemProvider) {
        if provider.canLoadObject(ofClass: NSImage.self) || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let bitmap = NSBitmapImageRep(data: data),
                      let image = OverlayEyePastedImageReader.sendableImage(from: bitmap) else {
                    self.loadFileURL(from: provider)
                    return
                }
                DispatchQueue.main.async { self.attachment.attach(image) }
            }
            return
        }
        loadFileURL(from: provider)
    }

    private func loadFileURL(from provider: NSItemProvider) {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            let images = OverlayEyePastedImageReader.imagesInFiles([url])
            guard let image = images.first else { return }
            DispatchQueue.main.async { self.attachment.attach(image) }
        }
    }
}

extension View {
    /// Lets images dropped anywhere on the bar become attachments, and lights
    /// the "drop to attach" state while a drag is over it. Paired with the
    /// release-time dismissal rule so the drag that ends in this drop never
    /// tears the bar down first.
    @MainActor
    func acceptsImagesDroppedOnTheBar(
        attachedTo attachment: OverlayEyePastedImageAttachment = .shared
    ) -> some View {
        onDrop(
            of: OverlayEyeBarDropDelegate.droppedContentTypes,
            delegate: OverlayEyeBarDropDelegate(attachment: attachment)
        )
    }
}

import AppKit
import SwiftUI
import Testing

@testable import Iris

/// WHY THIS FILE EXISTS.
///
/// Five clusters of Test 7 work landed at once, and three of them finished with
/// their fix sitting BEHIND a hookup in a file another cluster owned — a
/// `.acceptsAnImagePastedIntoTheField()` on the text field, a
/// `OverlayEyePastedImageThumbnailRow()` above it. Everything behind those two
/// lines was landed, tested and revert-checked; the lines themselves were not
/// written yet, so the reader's cmd-V was still dropped on the floor.
///
/// When the gate applied them, the full suite came back with the SAME 15 failing
/// test names and the same 39 issues as without them — which is the good news
/// (nothing regressed) and the bad news in one number: **no test in the tree
/// could tell whether the hookups were there at all.** A fix that is inert
/// unless somebody remembers one line, and that no test notices the absence of,
/// is a fix waiting to be lost in the next merge.
///
/// So these tests assert the WIRING, not the machinery. They render the real
/// bar into a real window and look for the real views in the real hierarchy.
/// Deleting either hookup line turns them red; the paste machinery's own tests
/// (`Test7PasteImageReproTests`) would stay green throughout, which is precisely
/// the hole being covered.
/// `.serialized` because three of these tests drive
/// `OverlayEyePastedImageAttachment.shared` — a singleton, because the keystroke
/// that attaches an image and the message that spends it are two files apart
/// with no object in common. Run in parallel they clear each other's attachment,
/// which does not fail them; it makes them VACUOUS, which is worse. Measured:
/// with the call site deliberately ignoring the pasted image, the send-path test
/// still passed, because a neighbouring test had removed the attachment for it.
@Suite("Test 7 — the cross-cluster hookups are actually wired", .serialized)
@MainActor
struct Test7ForeignEditWiringTests {

    // MARK: Rendering the real bar

    /// The real input bar, hosted in a real off-screen window, handed back as
    /// its view tree so the hookup views can be looked for by class.
    ///
    /// Deliberately NOT a screenshot comparison. What is in question here is
    /// whether a view was ever installed, and a view's presence in the hierarchy
    /// is the direct answer — a pixel diff would answer it only by implication
    /// and would fail for a dozen unrelated reasons besides.
    private func viewTreeOfTheRealBar(
        companionManager: CompanionManager
    ) -> [NSView] {
        let view = OverlayEyeInputBarView(
            companionManager: companionManager,
            guideSessionController: companionManager.guideSessionController,
            onDismissRequested: {},
            onTheBarShouldReleaseTheKeyboard: {},
            onTheBarShouldTakeTheKeyboardBack: {},
            onTheBarsMeasuredHeightChanged: { _ in },
            showingTheExchange: OverlayEyeExchange()
        )
        .frame(width: OverlayEyeInteractionGeometry.inputBarWidth)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(
            x: 0, y: 0,
            width: OverlayEyeInteractionGeometry.inputBarWidth,
            height: max(hostingView.fittingSize.height, 1)
        )

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFront(nil)

        // SwiftUI installs its representable-backed NSViews on a later runloop
        // turn, so a tree read synchronously after `orderFront` is read before
        // the thing being looked for could possibly be in it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        hostingView.layoutSubtreeIfNeeded()

        var everyView: [NSView] = []
        func collect(_ view: NSView) {
            everyView.append(view)
            for subview in view.subviews { collect(subview) }
        }
        collect(hostingView)

        window.orderOut(nil)
        return everyView
    }

    // MARK: The paste catcher

    @Test("the field's paste catcher is installed in the real bar's view tree")
    func theBarActuallyCarriesThePasteCatcher() {
        let companionManager = CompanionManager()
        let everyView = viewTreeOfTheRealBar(companionManager: companionManager)

        let theCatcher = everyView.first { $0 is SelectionTextFieldImagePasteCatchingView }

        #expect(
            theCatcher != nil,
            """
            The bar rendered without SelectionTextFieldImagePasteCatchingView in \
            its view tree, which means the TextField in `fieldAndSendRow` has \
            lost its `.acceptsAnImagePastedIntoTheField()` modifier. Every part \
            of the image-paste feature still exists and still passes its own \
            tests — it is simply no longer connected to the field the reader \
            types into, so cmd-V with a picture on the clipboard does nothing \
            and says nothing, which is the exact bug that was reported.
            """
        )
    }

    /// The catcher is worthless if it is not in a window: `performKeyEquivalent`
    /// is offered by the WINDOW to its view tree, so a catcher parked outside one
    /// is never asked. This pins the half that the class check alone would miss.
    @Test("the installed catcher is in a window, which is what gets offered the keystroke")
    func theCatcherIsSomewhereItCanActuallyBeOfferedTheKeystroke() {
        let companionManager = CompanionManager()
        let everyView = viewTreeOfTheRealBar(companionManager: companionManager)

        guard
            let theCatcher = everyView.first(where: { $0 is SelectionTextFieldImagePasteCatchingView })
        else {
            Issue.record("no paste catcher in the bar at all — see the previous test")
            return
        }

        #expect(
            theCatcher.window != nil,
            """
            The paste catcher exists but is not in a window. NSWindow is what \
            offers performKeyEquivalent down the view tree, so a catcher with no \
            window is never asked about cmd-V and the paste is dropped exactly \
            as if the catcher were absent.
            """
        )
    }

    // MARK: The thumbnail row

    /// The thumbnail is the only thing that tells the reader the paste WORKED,
    /// and the only way to take it back off again. Its absence is not cosmetic:
    /// a caught image that is never shown is indistinguishable, from the
    /// reader's side, from the silent drop this whole cluster is about.
    @Test("attaching an image makes the real bar grow, so the thumbnail row is really rendered")
    func theThumbnailRowIsWiredAboveTheField() throws {
        let companionManager = CompanionManager()
        let attachment = OverlayEyePastedImageAttachment.shared

        // Measured against the SAME bar with nothing attached rather than a
        // constant: the bar's natural height moves with unrelated work, and a
        // hardcoded number would rot into a false failure within a week.
        attachment.removeTheAttachment()
        let heightWithNothingAttached = heightOfTheRealBar(companionManager: companionManager)

        attachment.attach(
            OverlayEyePastedImage(
                imageData: onePNGWorthOfBytes(),
                pixelWidth: 64,
                pixelHeight: 64
            )
        )
        defer { attachment.removeTheAttachment() }

        let heightWithAnImageAttached = heightOfTheRealBar(companionManager: companionManager)

        #expect(
            heightWithAnImageAttached > heightWithNothingAttached,
            """
            Attaching an image did not make the bar any taller \
            (\(heightWithNothingAttached)pt with nothing attached, \
            \(heightWithAnImageAttached)pt with an image). \
            `OverlayEyePastedImageThumbnailRow()` is missing from the VStack in \
            `textFieldRow`, so a pasted image is caught and sent but never shown \
            — the reader gets no confirmation it worked and no way to remove it.
            """
        )
    }

    /// The other direction, and the reason the row is a bare `if let` with no
    /// wrapping modifier: with nothing attached it must be `EmptyView`, not an
    /// empty row that opens an 8pt gap in a bar every reader sees every day.
    @Test("with nothing attached the bar is exactly the bar it has always been")
    func theThumbnailRowCostsNothingWhenThereIsNoImage() {
        let companionManager = CompanionManager()
        let attachment = OverlayEyePastedImageAttachment.shared

        attachment.removeTheAttachment()
        let firstMeasurement = heightOfTheRealBar(companionManager: companionManager)

        attachment.attach(
            OverlayEyePastedImage(imageData: onePNGWorthOfBytes(), pixelWidth: 64, pixelHeight: 64)
        )
        _ = heightOfTheRealBar(companionManager: companionManager)
        attachment.removeTheAttachment()

        let heightAfterTheImageWentAway = heightOfTheRealBar(companionManager: companionManager)

        #expect(
            heightAfterTheImageWentAway == firstMeasurement,
            """
            Removing the attached image did not return the bar to its original \
            height (\(firstMeasurement)pt, then \(heightAfterTheImageWentAway)pt \
            after the image was taken back off). The thumbnail row is leaving \
            layout behind when it has nothing to draw.
            """
        )
    }

    // MARK: The third hookup — the message actually carrying the image

    /// THE LINE THAT DECIDES WHETHER A PASTED IMAGE EVER REACHES THE MODEL.
    ///
    /// `Test7PasteImageReproTests/aPastedImageIsWhatTheMessageCarries` exercises
    /// `CompanionScreenCaptureUtility.imageryForOneChatMessage` directly — the
    /// machinery. Nothing exercised the CALL SITE, so putting
    /// `captureAllScreensAsJPEG()` back in `CompanionManager` (a pasted image
    /// ignored, the screen photographed instead — the reader's exact symptom)
    /// left 72 tests green. This is the same class of hole the other two
    /// hookups in this file cover, at the one place it was left standing.
    ///
    /// It asserts by consumption rather than by inspecting a request: the send
    /// path takes the attachment with `takeTheImageForThisMessage()`, which
    /// hands it over and forgets it in one move. An attachment still sitting
    /// there after a message was sent was never asked for.
    @Test func sendingAMessageSpendsThePastedImageInsteadOfIgnoringIt() async throws {
        let companionManager = CompanionManager()
        let attachment = OverlayEyePastedImageAttachment.shared
        attachment.removeTheAttachment()
        attachment.attach(
            OverlayEyePastedImage(
                imageData: onePNGWorthOfBytes(), pixelWidth: 64, pixelHeight: 64
            )
        )
        defer { attachment.removeTheAttachment() }
        try #require(
            attachment.theImageTheReaderPasted != nil,
            "nothing was attached, so this test would prove nothing"
        )

        // An ordinary question — deliberately not an "add a feature to…" opener,
        // which Door B routes to the edit flow instead of to chat.
        companionManager.sendUserMessage("what is in this picture")

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, attachment.theImageTheReaderPasted != nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(
            attachment.theImageTheReaderPasted == nil,
            """
            the message went out without ever asking for the image the reader pasted — so \
            Iris photographed their screen and answered about that instead, which is "I cannot \
            paste images into the chat box" all over again
            """
        )
    }

    // MARK: The eye's own click path

    /// THE CLICK ITSELF, not the two halves of it called by hand.
    ///
    /// `BlueCursorView.presentTheInputBar()` is the only route a click on the
    /// eye — or the summon hotkey — takes into the bar, and it does two things
    /// in one order: it answers the attention signal that brought the reader
    /// here, then it raises the bar. Before this test both were provable only
    /// separately: the badge tests called `theReaderIsLookingAtTheEyesBar()`
    /// themselves and then rendered a bar of their own, so commenting the call
    /// out of `presentTheInputBar` left every one of them green while the badge
    /// stayed lit for the whole session — "a permanent badge is decoration",
    /// which is the failure that line exists to prevent.
    @Test func clickingTheEyeOpensTheBarAndTakesTheSignalDown() async throws {
        let companionManager = CompanionManager()
        let coordinator = companionManager.onDemandEditCoordinator

        // Something that genuinely needs the reader, raised the way the flow
        // raises it rather than by setting the published value by hand.
        let slug = "t7-click-\(UUID().uuidString.prefix(8))"
        coordinator.pickApp(slug: String(slug), name: "Repro App", stack: .nextjs)
        let signalWentUp = await waitUntilTheEye(
            of: companionManager, shows: .needsTheReader
        )
        try #require(
            signalWentUp,
            "nothing ever asked for the reader, so this test would prove nothing"
        )

        let inputBarPanelManager = OverlayEyeInputBarPanelManager()
        let overlay = BlueCursorView(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            isFirstAppearance: false,
            companionManager: companionManager,
            inputBarPanelManager: inputBarPanelManager
        )

        overlay.presentTheInputBar()
        defer { inputBarPanelManager.hideInputBar() }

        #expect(
            inputBarPanelManager.isShowingTheInputBar,
            "the click path did not put a bar on screen at all"
        )
        #expect(
            companionManager.attentionTheEyeShouldShow == .nothingToSay,
            """
            the bar the click opened is in front of the reader and the badge is still lit — \
            it will now stay lit for the rest of the session, which is a permanent badge, \
            which is decoration
            """
        )
    }

    // MARK: Helpers

    /// Polls the eye's published attention. The flow announces its phase from a
    /// `Task`, so what it decided is what a test can observe.
    private func waitUntilTheEye(
        of companionManager: CompanionManager,
        shows attention: OverlayEyeAttention,
        within seconds: Double = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if companionManager.attentionTheEyeShouldShow == attention { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return companionManager.attentionTheEyeShouldShow == attention
    }

    private func heightOfTheRealBar(companionManager: CompanionManager) -> CGFloat {
        let view = OverlayEyeInputBarView(
            companionManager: companionManager,
            guideSessionController: companionManager.guideSessionController,
            onDismissRequested: {},
            onTheBarShouldReleaseTheKeyboard: {},
            onTheBarShouldTakeTheKeyboardBack: {},
            onTheBarsMeasuredHeightChanged: { _ in },
            showingTheExchange: OverlayEyeExchange()
        )
        .frame(width: OverlayEyeInteractionGeometry.inputBarWidth)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(
            x: 0, y: 0,
            width: OverlayEyeInteractionGeometry.inputBarWidth,
            height: max(hostingView.fittingSize.height, 1)
        )
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        hostingView.layoutSubtreeIfNeeded()
        let measuredHeight = hostingView.fittingSize.height
        window.orderOut(nil)
        return measuredHeight
    }

    /// A real 1x1 PNG. Real bytes rather than `Data()` because
    /// `OverlayEyePastedImage` derives its media type by sniffing them, and a
    /// zero-byte image would exercise a path no pasted picture ever takes.
    private func onePNGWorthOfBytes() -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.systemPink.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        image.unlockFocus()
        guard
            let tiff = image.tiffRepresentation,
            let representation = NSBitmapImageRep(data: tiff),
            let png = representation.representation(using: .png, properties: [:])
        else {
            return Data()
        }
        return png
    }
}

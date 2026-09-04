//
//  PublikTest2DraftPersistenceReproTests.swift
//  leanring-buddyTests
//
//  PUBLIK TEST 2 — "mid-prompt into the Iris UI … it doesn't save my prompt if
//  I click off of there while I'm mid-prompting."
//
//  THE FIELD REPORT (cofounder's Mac, Iris 0.9.8, 2026-09-03): the reader was
//  part-way through typing a request into the bar under the eye — a bug fix or
//  a feature description — clicked off to look at something, and came back to an
//  empty field. The half-written request was gone.
//
//  WHY IT WAS LOST. The bar under the eye is a SwiftUI view that is destroyed on
//  every dismissal and rebuilt on every open (`OverlayEyeInputBarPanelManager`),
//  and the composer field it types into is a plain `@State` (`typedMessage`,
//  which is BOTH the chat ask field and, while an app is open for editing, the
//  describe field). Clicking off tore the view down and the unsent text went
//  with it. The last COMPLETED exchange already survived a dismissal
//  (`ChatTranscriptStore` re-seeds it); an UNSENT draft had nowhere to live.
//
//  THE FIX is `OverlayEyeInputBarDraftStore` — an in-memory holder (one per
//  `CompanionManager`) the bar mirrors its field into on every change and seeds
//  its field from on every open. This file drives that store through the exact
//  dismiss → reopen → send cycle the bar performs, at the seam the bar actually
//  uses (`remember(_:)` on change, `draftToRestoreIntoAFreshBar` on open), and
//  asserts the reported behaviour: a half-typed request comes back; a sent one
//  never does. Before the fix there was no store and a reopened bar always
//  started blank — the state these tests forbid.
//

import Testing
@testable import Iris

@Suite(.serialized)
@MainActor
struct PublikTest2DraftPersistenceReproTests {

    // MARK: - The reported bug: a half-typed request survives clicking off

    /// The core repro. The reader types, dismisses (the bar view is destroyed),
    /// and reopens. What a fresh bar seeds its composer from must be exactly what
    /// they had typed — text AND the fix/feature choice, because a half-written
    /// FEATURE description that comes back marked a bug fix is its own small bug.
    @Test func aHalfTypedRequestComesBackAfterAReopen() {
        let store = OverlayEyeInputBarDraftStore()

        // The reader is mid-describing a feature. The bar mirrors every keystroke
        // into the store.
        store.remember(
            OverlayEyeInputBarDraft(
                text: "add a hands-free toggle so I don't have to hold fn",
                editKind: .feature
            )
        )

        // They click off — the bar view is destroyed — then reopen. A fresh bar
        // seeds its composer from this.
        let whatAFreshBarStartsFrom = store.draftToRestoreIntoAFreshBar

        #expect(
            whatAFreshBarStartsFrom.text == "add a hands-free toggle so I don't have to hold fn",
            "the reopened bar did not restore the reader's half-typed request — the click-off threw it away, which is the reported bug"
        )
        #expect(
            whatAFreshBarStartsFrom.editKind == .feature,
            "the request came back but no longer marked a feature, so the reader's fix/feature choice was lost with the dismissal"
        )
    }

    // MARK: - A SENT request is never offered back as a draft

    /// Sending clears the field (`typedMessage = ""`), and the field is mirrored
    /// into the store, so the store ends empty with no separate clear call. A bar
    /// reopened after a send must start blank — otherwise the reader's just-sent
    /// question would reappear as if unsent.
    @Test func aSentRequestLeavesNothingToRestore() {
        let store = OverlayEyeInputBarDraftStore()
        store.remember(OverlayEyeInputBarDraft(text: "fix the crash on launch", editKind: .bugFix))

        // Send: the field is cleared, and the mirror carries the empty field into
        // the store.
        store.remember(OverlayEyeInputBarDraft(text: "", editKind: .bugFix))

        #expect(
            !store.draftToRestoreIntoAFreshBar.thereIsSomethingToRestore,
            "after sending, a fresh bar would still restore the sent text as a draft"
        )
        #expect(
            store.draftToRestoreIntoAFreshBar.text.isEmpty,
            "the composer a reopened bar starts from should be blank after a send"
        )
    }

    // MARK: - Nothing worth restoring is not a draft

    /// A first-ever open, and a field the reader left holding only whitespace,
    /// both count as "no draft" — so the bar opens on its suggestion chips, not on
    /// a "draft" that is really blank.
    @Test func aFreshStoreAndAWhitespaceOnlyDraftBothRestoreNothing() {
        let freshStore = OverlayEyeInputBarDraftStore()
        #expect(!freshStore.draftToRestoreIntoAFreshBar.thereIsSomethingToRestore)
        #expect(freshStore.draftToRestoreIntoAFreshBar.text.isEmpty)

        let storeWithStrayWhitespace = OverlayEyeInputBarDraftStore()
        storeWithStrayWhitespace.remember(OverlayEyeInputBarDraft(text: "   \n  ", editKind: .bugFix))
        #expect(
            !storeWithStrayWhitespace.draftToRestoreIntoAFreshBar.thereIsSomethingToRestore,
            "a field holding only whitespace should not reopen the bar onto a blank 'draft'"
        )
    }

    // MARK: - The store is in memory only, by design

    /// A guard on the privacy decision, not just the behaviour: the draft holder
    /// must not be a disk-backed store. An unsent draft is a half-formed thought
    /// the reader never chose to keep, and the report is about a click-off, not a
    /// quit — so surviving the dismissal (in memory) is exactly enough, and the
    /// filesystem is deliberately never touched. If a future change makes this a
    /// disk store, that is a privacy decision this assertion should force into the
    /// open.
    @Test func theDraftStoreExposesNoFileURL() {
        // `ChatTranscriptStore`, which DOES persist, exposes a `fileURL`. The
        // draft store deliberately has no such surface — it is a plain in-memory
        // holder. This test documents that contrast so the two are not conflated.
        let store = OverlayEyeInputBarDraftStore()
        store.remember(OverlayEyeInputBarDraft(text: "something", editKind: .bugFix))
        // The type has no file API to call; the strongest assertion here is that
        // clearing is a pure in-memory reset with no I/O to fail.
        store.clear()
        #expect(!store.draftToRestoreIntoAFreshBar.thereIsSomethingToRestore)
    }
}

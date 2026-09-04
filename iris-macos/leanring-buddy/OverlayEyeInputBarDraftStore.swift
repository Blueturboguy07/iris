//
//  OverlayEyeInputBarDraftStore.swift
//  leanring-buddy
//
//  THE UNSENT DRAFT, KEPT ACROSS A DISMISSAL — reported (Publik Test 2,
//  2026-09-03): "If I am mid-prompt into the Iris UI in bug [fix] or features
//  it doesn't save my prompt if I click off of there while I'm mid-prompting."
//
//  WHY THE DRAFT WAS LOST. The bar under the eye is destroyed on every
//  dismissal and rebuilt on every open (see `OverlayEyeInputBarPanelManager`),
//  and the field the reader types into — `typedMessage`, which is BOTH the chat
//  ask field and, while an app is open for editing, the describe field — is a
//  plain SwiftUI `@State`. Clicking off tore the view down and the half-written
//  request went with it. The last completed exchange already survives a
//  dismissal (`ChatTranscriptStore` re-seeds it), but a request the reader had
//  not sent yet had nowhere to live.
//
//  THIS IS DELIBERATELY IN MEMORY, NOT ON DISK. `ChatTranscriptStore` writes
//  COMPLETED exchanges to disk on purpose — they are a conversation the reader
//  chose to have. An UNSENT draft is different: it is a half-formed thought the
//  reader may erase, retype, or abandon, and writing every keystroke of it to a
//  file would be a new privacy surface for text the reader never decided to
//  keep. The report is about a click-off, not a quit, so surviving the
//  dismissal is exactly enough: the draft lives for this session and is gone at
//  quit, and it never touches the filesystem.
//
//  The store holds the draft; the bar mirrors its field into the store on every
//  change and seeds the field from the store on every open. Because sending
//  clears the field (`typedMessage = ""`), the same mirror clears the store — a
//  sent request is never offered back as a draft, with no separate clear call
//  to keep in step.
//

import Foundation

/// The unsent contents of the bar's one composer field, kept so a dismissal
/// does not throw them away. Two things travel together because they are the
/// two halves of one composed request: the words, and — while an app is open
/// for editing — whether those words describe a bug fix or a feature, so a
/// half-written feature description comes back still marked a feature.
struct OverlayEyeInputBarDraft: Equatable {

    /// What the reader had typed into the composer but not yet sent.
    var text: String = ""

    /// The fix/feature choice that was showing above the field. Only meaningful
    /// while an app is open for editing; harmless otherwise, because the ask
    /// path ignores it.
    var editKind: OnDemandEditKind = .bugFix

    /// Whether there is anything worth restoring. Whitespace-only is treated as
    /// empty, so a stray space the reader left behind never reopens the bar onto
    /// a "draft" that is really blank.
    var thereIsSomethingToRestore: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Holds the one in-flight composer draft for the life of the app process.
///
/// One per `CompanionManager` (there is exactly one), not one per display: the
/// reader can dismiss the bar on one screen and reopen it on another, and the
/// draft has to follow them rather than staying with the panel manager that
/// happened to show it.
@MainActor
final class OverlayEyeInputBarDraftStore {

    /// The current draft, or the empty draft when there is nothing to restore.
    private(set) var draft = OverlayEyeInputBarDraft()

    init(draft: OverlayEyeInputBarDraft = OverlayEyeInputBarDraft()) {
        self.draft = draft
    }

    /// Records what the composer field holds right now. Called on every change,
    /// so the store always mirrors the live field — which is what makes sending
    /// (`text` → "") also clear the store, with no second code path.
    func remember(_ draft: OverlayEyeInputBarDraft) {
        self.draft = draft
    }

    /// The draft a freshly-opened bar should start its composer from. Empty when
    /// there is nothing to restore, which is both a first-ever open and the
    /// state right after a send.
    var draftToRestoreIntoAFreshBar: OverlayEyeInputBarDraft {
        draft.thereIsSomethingToRestore ? draft : OverlayEyeInputBarDraft()
    }

    /// Throws the draft away. Not needed on the send path (the mirror handles
    /// that), but exists so a caller that wants to abandon a draft outright —
    /// without routing through the field — has one obvious way to do it.
    func clear() {
        draft = OverlayEyeInputBarDraft()
    }
}

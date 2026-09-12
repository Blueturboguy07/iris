import Foundation
@testable import IrisHarnessNative

@main struct GeneralChatModeChecks {
    @MainActor static func main() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "GeneralChatModeChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let store = OverlayEyeInputBarDraftStore()
        let images = OverlayEyePastedImageAttachment()
        try require(store.mode == .ask, "Fresh composer must be general help")
        store.switchMode(to: .edit, currentDraft: store.draft)
        images.switchComposerMode(isAsking: false)
        let edit = OverlayEyeInputBarDraft(
            text: "Keep my pending feature", editKind: .feature, editAppSlug: "nitroai"
        )
        let image = OverlayEyePastedImage(imageData: Data([1, 2, 3]), pixelWidth: 1, pixelHeight: 1)

        let attachmentModeCheck = OverlayEyePastedImageAttachment()
        let askImage = OverlayEyePastedImage(imageData: Data([4]), pixelWidth: 1, pixelHeight: 1)
        let editImage = OverlayEyePastedImage(imageData: Data([5]), pixelWidth: 1, pixelHeight: 1)
        attachmentModeCheck.attach(askImage)
        attachmentModeCheck.switchComposerMode(isAsking: false)
        attachmentModeCheck.attach(editImage)
        attachmentModeCheck.switchComposerMode(isAsking: true)
        let askSnapshot = attachmentModeCheck.takeTheImagesForThisMessage()
        attachmentModeCheck.switchComposerMode(isAsking: false)
        try require(askSnapshot == [askImage]
                        && attachmentModeCheck.theImagesTheReaderAttached == [editImage],
                    "A synchronous Ask attachment snapshot must survive an immediate Edit switch")

        store.remember(edit)
        images.attach(image)
        store.switchMode(to: .ask, currentDraft: edit)
        images.switchComposerMode(isAsking: true)
        store.clearGeneralHelp()
        images.clearGeneralHelpAttachments()
        try require(store.draft.text.isEmpty && !images.thereIsSomethingAttached,
                    "New general chat must not inherit edit text or attachments")
        store.remember(.init(text: "How do I take a screenshot?"))
        try require(store.mode == .ask && store.draftToRestoreIntoAFreshBar.text == "How do I take a screenshot?",
                    "Dismiss and reopen must retain general mode and draft")
        let restored = store.switchMode(to: .edit, currentDraft: store.draft)
        images.switchComposerMode(isAsking: false)
        try require(restored == edit && images.theImagesTheReaderAttached == [image],
                    "Returning to Edit must preserve feature draft and attachments")
        try require(store.editDraftConflicts(withAppSlug: "plantgpt"),
                    "A nonempty edit draft must conflict with a different app slug")
        try require(!store.editDraftConflicts(withAppSlug: "nitroai"),
                    "A nonempty edit draft must be permitted for its own app slug")

        let blankStore = OverlayEyeInputBarDraftStore()
        blankStore.switchMode(to: .edit, currentDraft: .init())
        blankStore.associateEditDraft(withAppSlug: "nitroai")
        try require(!blankStore.editDraftConflicts(withAppSlug: "plantgpt"),
                    "A blank edit draft must not block a different app")
        try require(blankStore.editDraftConflicts(withAppSlug: "plantgpt", hasAttachments: true),
                    "An attachment-only edit draft must block a different app")

        store.clearGeneralHelp()
        images.clearGeneralHelpAttachments()
        try require(store.draft == edit && images.theImagesTheReaderAttached == [image],
                    "Clearing general chat must not erase edit work")
        store.switchMode(to: .ask, currentDraft: store.draft)
        images.switchComposerMode(isAsking: true)
        try require(store.draft.text.isEmpty && !images.thereIsSomethingAttached,
                    "General chat clear must also clear the parked general draft")
        print("GENERAL CHAT MODE CHECKS PASS: general default, separate drafts/images, reopen, clear preserves edit")
    }
}

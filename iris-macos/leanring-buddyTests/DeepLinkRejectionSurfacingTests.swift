//
//  DeepLinkRejectionSurfacingTests.swift
//  leanring-buddyTests
//
//  ASTRO FIX ROUND (2026-09-05 live campaign): "Bare `iris://guide/<slug>`
//  (no version param) is silently rejected — no window, no error, nothing."
//
//  Confirmed live: `open -a Iris 'iris://guide/astro'` reached
//  `application(_:open:)`, `IrisDeepLinkParser.parse` correctly refused it
//  (`.missingGuideVersion` — a real link always carries `?version=`, see
//  `publik/lib/iris-guides.ts`'s `desktopHandoffUrl`), and
//  `handleIncomingDeepLink`'s `.failure` case did nothing but
//  `print(...)` — invisible to anyone not tailing `log show`. The tap landed
//  and the reader was told nothing, which is the exact silent-failure shape
//  this codebase's own comments call out elsewhere for
//  `autopilotBlockedExplanation`.
//
//  `handleIncomingDeepLink` itself lives on `CompanionAppDelegate`
//  (`NSApplicationDelegate`), which is not a unit worth standing up just to
//  reach one `switch` arm — the actual fix, and the thing worth pinning, is
//  the new user-visible signal it now calls into:
//  `CompanionManager.presentDeepLinkRejection(_:)`, whose one published
//  property (`deepLinkRejectionExplanation`) is what
//  `OverlayEyeInputBarView` renders as a banner at the top of the bar
//  regardless of what else it is showing. This suite pins that contract
//  directly, the same level `GuideSessionController`'s own transient-message
//  properties (`transientCopyConfirmationText`, `autopilotBlockedExplanation`)
//  are tested at.
//

import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

@MainActor
struct DeepLinkRejectionSurfacingTests {

    /// THE REPRO. Before this fix there was no such property at all — a
    /// rejected link had literally nothing for a view to observe, which is
    /// exactly "no window, no error, nothing".
    @Test("a rejected deep link's explanation reaches a published, observable property")
    func aRejectedLinksExplanationBecomesObservable() {
        let companionManager = CompanionManager()
        defer { companionManager.stop() }

        #expect(companionManager.deepLinkRejectionExplanation == nil)

        // Exactly `IrisDeepLinkRejection.missingGuideVersion.rejectionMessage`
        // — the real rejection a bare `iris://guide/astro` produces.
        companionManager.presentDeepLinkRejection("missing Iris guide version")

        #expect(
            companionManager.deepLinkRejectionExplanation == "missing Iris guide version",
            "the parser's rejection sentence never reached anything the bar can render"
        )
    }

    /// A second rejected link replaces the first rather than the two racing —
    /// mirrors `showTransientCopyConfirmation`'s own cancel-then-set shape.
    @Test("a second rejection replaces the first rather than the two colliding")
    func aSecondRejectionReplacesTheFirst() {
        let companionManager = CompanionManager()
        defer { companionManager.stop() }

        companionManager.presentDeepLinkRejection("missing Iris guide version")
        companionManager.presentDeepLinkRejection("invalid Iris guide slug")

        #expect(companionManager.deepLinkRejectionExplanation == "invalid Iris guide slug")
    }
}

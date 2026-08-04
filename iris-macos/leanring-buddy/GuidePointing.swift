//
//  GuidePointing.swift
//  leanring-buddy
//
//  Where the eye goes while a guide step is open.
//
//  A guide that only prints commands is worth no more than the web page it
//  duplicates. What the desktop can do that a web page cannot is *show you the
//  thing* — fly to the button and hold there until you have clicked it.
//
//  Everything here is pure: it decides what to look for and turns a found
//  rectangle into a place to point. Finding it is `GuidePointingResolver`'s
//  job, and the accessibility and model work behind that lives in
//  `WatchLoopSystemSources.swift`, which already has both.
//

import Foundation

/// What Iris decided to aim at, and how sure it is.
///
/// The provenance is not decoration. An authored descriptor matched in the
/// accessibility tree is a fact; a model's guess from a screenshot is a guess,
/// and Phase 0 measured its p95 miss at 123pt — far enough to be pointing at a
/// different control entirely. The two are allowed to look different on screen
/// and are allowed to fail differently.
nonisolated enum GuidePointProvenance: String, Equatable, Sendable {
    /// The guide named it and the accessibility tree had it. Exact.
    case authoredAndFound
    /// A command step, aimed at the window the command has to be typed into.
    /// Deterministic — no descriptor, no model call.
    case shellWindow
    /// Nobody authored a target, so the model was asked what to point at.
    case inferred
}

nonisolated struct GuidePointTarget: Equatable, Sendable {
    let descriptor: String
    /// Bundle identifier of the app the target is inside, when known.
    let inApp: String?
    let isWindow: Bool
    let provenance: GuidePointProvenance

    /// Whether a miss here is cheap. An inferred point that lands on the wrong
    /// control teaches the reader to distrust the arrow, so it is offered more
    /// tentatively — the eye hovers rather than jabbing, and the wording hedges.
    var isCertain: Bool { provenance != .inferred }
}

/// Why Iris is not pointing at anything right now. Each of these has a
/// different sentence attached, because "I cannot see it" and "you are looking
/// at the wrong app" send the reader to completely different places.
nonisolated enum GuidePointRefusal: Equatable, Sendable {
    /// The step is about something that is not on this screen at all — reading
    /// a web page, waiting for a download.
    case stepHasNothingToPointAt
    /// The target lives in an app that is not in front.
    case targetAppIsNotInFront(bundleId: String, appName: String?)
    /// Iris is not allowed to look at the screen, so it cannot find anything.
    case irisMayNotLookAtTheScreen
    /// The step is marked sensitive, so no capture happens at all — that is the
    /// promise that lets Iris walk someone through a key it never sees.
    case theStepIsSensitive
    /// Looked, and genuinely could not find it.
    case couldNotFindIt(descriptor: String)

    var userFacingMessage: String? {
        switch self {
        case .stepHasNothingToPointAt:
            return nil // Not a problem. Say nothing.
        case .targetAppIsNotInFront(_, let appName):
            return "Switch to \(appName ?? "the app") and I'll show you where."
        case .irisMayNotLookAtTheScreen:
            return "Turn on Screen Recording for Iris and I can point at it."
        case .theStepIsSensitive:
            return nil // Deliberate, and explaining it every time would be noise.
        case .couldNotFindIt:
            return "I can't find it on screen — it may be scrolled out of view."
        }
    }
}

nonisolated enum GuidePointingDecision: Equatable, Sendable {
    case pointAt(GuidePointTarget)
    case doNotPoint(GuidePointRefusal)
}

/// Decides *what* to look for, before anything looks.
///
/// This is the ladder the user chose: an authored target wins, a command step
/// falls back to the window the command belongs in, and anything else asks the
/// model. Deliberately pure and deliberately separate from the looking, because
/// the ladder is the part with the judgement in it.
nonisolated enum GuidePointingLadder {

    /// macOS shells, by the branch's declared shell. A command step is always
    /// about getting the reader into one of these windows.
    static func bundleIdentifierForShell(_ shell: IrisGuideShell) -> String {
        switch shell {
        case .powershell:
            // Only reachable if a Windows branch is somehow open on a Mac. The
            // Windows client has its own answer for this.
            return "com.microsoft.powershell"
        case .terminal:
            return "com.apple.Terminal"
        }
    }

    static func describeShell(_ shell: IrisGuideShell) -> String {
        shell == .powershell ? "the PowerShell window" : "the Terminal window"
    }

    /// What this step wants pointed at, given nothing but the step itself.
    ///
    /// Returns nil when the step has nothing on this screen to aim at, which is
    /// a legitimate and common answer — "open this link in your browser" is not
    /// improved by an arrow.
    static func target(
        for step: IrisGuideStep,
        shell: IrisGuideShell,
        modelFallbackIsAvailable: Bool
    ) -> GuidePointTarget? {
        // 1. Authored wins. Somebody looked at this step and wrote down the
        //    answer, which beats anything inferred at runtime.
        if let authored = step.point, !authored.descriptor.trimmingCharacters(in: .whitespaces).isEmpty {
            return GuidePointTarget(
                descriptor: authored.descriptor,
                inApp: authored.inApp,
                isWindow: authored.isWindow ?? false,
                provenance: .authoredAndFound
            )
        }

        // 2. A command has to be typed somewhere, and that somewhere is known
        //    without asking anyone. This covers most steps in most guides, for
        //    free and without a model call.
        if let command = step.command, !command.isEmpty {
            return GuidePointTarget(
                descriptor: describeShell(shell),
                inApp: bundleIdentifierForShell(shell),
                isWindow: true,
                provenance: .shellWindow
            )
        }

        // 3. Anything left is a step about clicking something in some app.
        //    Only worth a model call for the kinds where that is actually true.
        guard modelFallbackIsAvailable, stepKindIsWorthInferring(step.kind) else { return nil }
        return GuidePointTarget(
            descriptor: step.title,
            inApp: nil,
            isWindow: false,
            provenance: .inferred
        )
    }

    /// Which kinds are about clicking something visible.
    ///
    /// `terminal` is absent because it was already handled above, and `verify`
    /// is absent because it asks the reader to look at output rather than press
    /// anything — pointing at a window they are already reading is noise.
    static func stepKindIsWorthInferring(_ kind: IrisStepKind) -> Bool {
        switch kind {
        case .open, .permission, .web, .paste:
            return true
        case .check, .terminal, .verify:
            return false
        }
    }

    /// The final say, once the world has been consulted.
    ///
    /// Order matters and is not arbitrary: the sensitive check comes before
    /// everything, because it is a promise about what Iris never captures, and
    /// a promise that yields to a convenience is not a promise.
    static func decide(
        target: GuidePointTarget?,
        stepIsSensitive: Bool,
        irisMayLookAtTheScreen: Bool,
        frontmostBundleIdentifier: String?,
        frontmostAppName: String?
    ) -> GuidePointingDecision {
        if stepIsSensitive { return .doNotPoint(.theStepIsSensitive) }
        guard let target else { return .doNotPoint(.stepHasNothingToPointAt) }

        if let requiredApp = target.inApp, requiredApp != frontmostBundleIdentifier {
            return .doNotPoint(.targetAppIsNotInFront(bundleId: requiredApp, appName: frontmostAppName))
        }

        // The accessibility tree does not need a screenshot, so an authored
        // descriptor can still be found with screen capture switched off. A
        // model guess cannot.
        if !irisMayLookAtTheScreen && target.provenance == .inferred {
            return .doNotPoint(.irisMayNotLookAtTheScreen)
        }

        return .pointAt(target)
    }
}

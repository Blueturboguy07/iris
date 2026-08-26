//
//  OverlayEyeGuideCard.swift
//  leanring-buddy
//
//  The guide step, rendered under the eye instead of inside the settings
//  dropdown.
//
//  WHY IT MOVED. A step card in the menu bar panel is a copy of the web page
//  with extra steps: the reader looks *away* from the thing they are supposed
//  to be doing, into a dropdown, to read a command. The eye is already sitting
//  in the corner of the screen watching the pointer, it can fly to a control
//  and hold there, and it is where every other Iris answer now appears. The
//  panel goes back to being settings, which is what `iris-macos/CLAUDE.md`
//  always said it was.
//
//  Everything in this file is a pure value except the view at the bottom, so
//  the wording — which is most of the judgement — is testable without a screen.
//

import SwiftUI

/// What the bar shows about the step in one place.
///
/// Built from the controller rather than reaching into it, so the card cannot
/// accidentally start driving the guide: it renders, and it reports what was
/// pressed.
nonisolated struct OverlayEyeGuideStepPresentation: Equatable, Sendable {
    let appName: String
    let stepTitle: String
    let stepBody: String
    let command: String?
    /// "3 of 11". Nil while the guide is still loading.
    let progressLabel: String?
    /// Fraction of the branch completed, for the hairline under the title.
    let progressFraction: Double
    /// "Git responds with a version number" — how the reader knows it worked.
    let completionHint: String?
    /// What the eye is doing about pointing, when that is worth saying.
    let pointingNote: String?
    let readerCanGoBack: Bool
    let isTheLastStep: Bool

    /// What `GuideSessionController.primaryActionForTheCurrentStep` says the
    /// primary button really does right now — "Open download", "I ran it",
    /// "Check again", "Checking…".
    ///
    /// WHY THE CONTROLLER'S OWN WORD, RATHER THAN THE GUESS BELOW. The label
    /// this card worked out for itself is a second opinion about a decision the
    /// controller has already made once, and the two disagree exactly where it
    /// costs the most: inside the setup detour that repairs a missing
    /// prerequisite. There the button this card draws as "Continue" is really
    /// the step's download link, and after that the tool re-check that is the
    /// only honest way out of the detour — so a reader pressing "Continue" on
    /// "Install Node LTS" watches the step stay exactly where it was and
    /// reports, correctly, that Continue does not work (founder report). A
    /// label taken from the resolved action cannot drift from what pressing it
    /// will do, however the guide gets to that state.
    ///
    /// A `var` with a default rather than a `let` so the memberwise
    /// initializer keeps a default for it, and a surface that has not been
    /// taught to resolve the action yet still compiles and behaves as before.
    var labelForThePrimaryAction: String? = nil

    /// The primary button's words.
    ///
    /// The controller's own label wins whenever there is one. The fallback is
    /// the original local guess — a command step's primary action is Copy,
    /// because that is the thing the reader actually needs next; everything
    /// else moves the guide forward — and it is a guess: it cannot see a
    /// download link, an "I ran it" latch, or the detour's re-check, so it is
    /// only ever right for a plain step of the guide itself.
    var primaryActionLabel: String {
        if let labelForThePrimaryAction, !labelForThePrimaryAction.isEmpty {
            return labelForThePrimaryAction
        }
        if command != nil { return "Copy" }
        return isTheLastStep ? "Done" : "Continue"
    }

    /// Shown under the primary button while the watch loop is doing the
    /// checking, so the reader knows they do not have to press anything.
    var secondaryActionLabel: String? {
        command == nil ? nil : (isTheLastStep ? "Done" : "Next")
    }
}

/// How the eye explains what it is pointing at, or why it is not.
///
/// The wording separates a fact from a guess on purpose. An authored target
/// found in the accessibility tree is exact; a model's guess had a 123pt p95
/// miss in the Phase 0 measurements, which is far enough to be a different
/// control. Presenting both as "it's here" teaches people to distrust the one
/// that is actually right.
nonisolated enum OverlayEyeGuidePointingNote {
    static func note(for decision: GuidePointingDecision) -> String? {
        switch decision {
        case .pointAt(let target):
            switch target.provenance {
            case .authoredAndFound:
                return nil // The arrow says it. Words would be noise.
            case .shellWindow:
                return nil // Same: the eye is sitting on the window.
            case .inferred:
                return "I think it's here — tell me if I'm wrong."
            }
        case .doNotPoint(let refusal):
            return refusal.userFacingMessage
        }
    }
}

// MARK: - The view

/// The step card that hangs under the eye. Deliberately narrow and short: it
/// floats over whatever the reader is really doing, and a tall card is a
/// second window by another name.
struct OverlayEyeGuideCard: View {
    let presentation: OverlayEyeGuideStepPresentation
    let onPrimaryAction: () -> Void
    let onSecondaryAction: () -> Void
    let onBack: () -> Void
    let onClose: () -> Void
    /// Set while the transient "Copied" confirmation is up.
    let copyConfirmationText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Text(presentation.stepTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(presentation.stepBody)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let command = presentation.command {
                commandBlock(command)
            }

            if let pointingNote = presentation.pointingNote {
                Text(pointingNote)
                    .font(.system(size: 10.5))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let completionHint = presentation.completionHint {
                HStack(alignment: .top, spacing: 5) {
                    Text("✓")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(completionHint)
                        .font(.system(size: 10.5))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The panel behind this is deliberately clear, so every piece in the bar
        // carries its own backdrop — see the same rule on the chips and the
        // exchange card. Without one the step text is drawn straight onto
        // whatever the reader has open, which is unreadable the moment that is a
        // bright window and, worse, looks like a rendering fault rather than a
        // card.
        //
        // The panel surface is not enough here. This card floats over the
        // reader's real screen rather than over Iris's own chrome, so it uses
        // the darker translucent one that stays legible over a white browser
        // window.
        .background(
            IrisShellBackground(
                cornerRadius: DS.CornerRadius.large,
                surface: DS.Colors.readableOverAnything
            )
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(presentation.appName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            if let progressLabel = presentation.progressLabel {
                Text(progressLabel)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer(minLength: 4)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .irisIconButton()
            .help("Close the guide. Your place is kept.")
        }
        .overlay(alignment: .bottomLeading) {
            GeometryReader { proxy in
                Capsule()
                    .fill(DS.Colors.accent)
                    .frame(width: max(0, proxy.size.width * presentation.progressFraction), height: 1.5)
                    .offset(y: proxy.size.height + 4)
            }
        }
    }

    private func commandBlock(_ command: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if presentation.readerCanGoBack {
                Button("Back", action: onBack)
                    .irisTextButton()
            }

            Spacer(minLength: 0)

            if let secondaryActionLabel = presentation.secondaryActionLabel {
                Button(secondaryActionLabel, action: onSecondaryAction)
                    .irisTinyButton()
            }

            Button(copyConfirmationText ?? presentation.primaryActionLabel, action: onPrimaryAction)
                .irisPrimaryPill(isFullWidth: false, isCompact: true)
        }
    }
}

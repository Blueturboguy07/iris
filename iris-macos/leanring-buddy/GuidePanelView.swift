//
//  GuidePanelView.swift
//  leanring-buddy
//
//  The install-guide surface inside the menu bar panel: the step card, the
//  command block with its Copy button, the tool-check rows, the device-pair
//  picker, and the completion card. Reaches parity with the pill the Tauri app
//  shipped (`iris-desktop/ui/app.js`), which remains the behavioral spec.
//
//  Every decision about what to render is made by `GuideSessionController`;
//  this file only draws it. In particular the primary button's label and
//  whether it can be pressed at all come from `primaryActionForTheCurrentStep`,
//  so a link Iris is not allowed to open can never be drawn as a live button.
//

import SwiftUI

struct GuidePanelView: View {
    @ObservedObject var guideSessionController: GuideSessionController

    /// Observed separately because it is its own object with its own publishes:
    /// the indicator has to repaint the instant capture suspends, which happens
    /// without anything on the controller changing.
    @ObservedObject private var watchLoop: WatchLoop

    init(guideSessionController: GuideSessionController) {
        self.guideSessionController = guideSessionController
        self._watchLoop = ObservedObject(wrappedValue: guideSessionController.watchLoop)
    }

    /// The step card's scroll region is a fixed height so the floating panel
    /// does not jump in size between a one-line step and a five-line one.
    private let scrollableStepAreaHeight: CGFloat = 232

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            guideHeaderRow

            switch guideSessionController.loadState {
            case .noGuideIsOpen:
                EmptyView()
            case .guideIsLoading(let slug):
                loadingBody(slug: slug)
            case .guideCouldNotBeLoaded(let slug, let userFacingMessage):
                failureBody(slug: slug, userFacingMessage: userFacingMessage)
            case .guideIsOpen:
                openGuideBody
            }
        }
    }

    // MARK: - Header

    /// The pill's titlebar identity row: guide name at 12/650 with the quiet
    /// "· step" counter beside it, exactly like `.titlebar__guide` and
    /// `.titlebar__step`.
    private var guideHeaderRow: some View {
        HStack(spacing: 7) {
            Text(guideSessionController.guideBeingFollowed?.appName ?? "Guide")
                .font(.system(size: 12, weight: .bold))
                .tracking(-0.18)
                .foregroundColor(DS.Colors.ink)
                .lineLimit(1)

            if !guideSessionController.stepCounterText.isEmpty {
                Text("·")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.quiet)
                Text(guideSessionController.stepCounterText)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.quiet)
                    .monospacedDigit()
            }

            Spacer()

            Button(action: {
                guideSessionController.closeTheGuide()
            }) {
                Image(systemName: "xmark")
            }
            .irisIconButton(size: 22)
            .nativeTooltip("Close this guide")
        }
    }

    // MARK: - Loading and failure

    private func loadingBody(slug: String) -> some View {
        Text("Loading the \(slug) guide…")
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The message is whatever `GuideService` decided this particular failure
    /// means. A retired version, an unpublished guide, and a dead network each
    /// arrive here as different sentences, because they are different problems
    /// and only one of them is worth pressing "Try again" for.
    private func failureBody(slug: String, userFacingMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Iris could not load this guide.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            Text(userFacingMessage)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Button(action: {
                    Task { await guideSessionController.openLatestVersionOfGuide(slug: slug) }
                }) {
                    Text("Try again")
                }
                .irisPrimaryPill(isFullWidth: false, isCompact: true)

                Button(action: {
                    guideSessionController.closeTheGuide()
                }) {
                    Text("Close")
                }
                .irisTextButton(fontSize: 10)
            }
        }
    }

    // MARK: - An open guide

    private var openGuideBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            progressBar

            if watchLoop.isWatchingAStep {
                watchIndicatorRow
            }

            if guideSessionController.guideOffersAChoiceOfBranches {
                devicePairPicker
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let unsupportedPair = guideSessionController.unsupportedPairForTheSelectedBranch {
                        unsupportedPairExplanation(unsupportedPair)
                    } else if let setupRecoveryState = guideSessionController.setupRecoveryState {
                        setupRecoveryCard(setupRecoveryState)
                    } else if guideSessionController.readerHasFinishedTheGuide {
                        completionCard
                    } else if guideSessionController.currentStep != nil {
                        // Each step slides in from the right the way the pill's
                        // `step-in` keyframes do; the id() makes SwiftUI treat
                        // every step as a fresh card so the transition runs.
                        stepCard
                            .id(guideSessionController.currentStepIndex)
                            .transition(DS.Motion.stepTransition)
                    } else {
                        Text("Publik needs to review this platform branch.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 2)
                .animation(DS.Motion.stepIn, value: guideSessionController.currentStepIndex)
            }
            .frame(height: scrollableStepAreaHeight)

            navigationRow
        }
    }

    private var progressBar: some View {
        GeometryReader { geometryProxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(DS.Colors.accent)
                    .frame(
                        width: geometryProxy.size.width
                            * guideSessionController.fractionOfTheGuideCompleted
                    )
                    .animation(DS.Motion.contentIn, value: guideSessionController.fractionOfTheGuideCompleted)
            }
        }
        .frame(height: 3)
    }

    // MARK: - The watch indicator

    /// Shown for exactly as long as the watch loop is alive, and never
    /// otherwise. A reader must be able to tell at a glance whether Iris is
    /// looking at their screen, so this is derived from the loop's own state
    /// rather than set alongside it — the two cannot disagree.
    ///
    /// The dot is filled only while frames are actually being taken. Iris being
    /// deliberately blind — a sensitive step, a password manager in front,
    /// secure input on — is a different thing from Iris being switched off, and
    /// the reader deserves to see which one they are in.
    private var watchIndicatorRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(watchLoop.isCapturingRightNow ? DS.Colors.accent : DS.Colors.textTertiary)
                .frame(width: 6, height: 6)

            Text(watchLoop.watchIndicatorText ?? "")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            Button(action: {
                watchLoop.setReaderPausedWatching(!watchLoop.readerPausedWatching)
            }) {
                Text(watchLoop.readerPausedWatching ? "Resume" : "Pause")
            }
            .irisTinyButton()
            .nativeTooltip(
                watchLoop.readerPausedWatching
                    ? "Let Iris watch this step again."
                    : "Stop Iris looking at your screen. Takes effect immediately."
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    /// The `userStuck` hint. It appears without the reader asking for anything,
    /// which is the entire point: a reader who is stuck is, by definition, not
    /// about to press a button labelled "I am stuck".
    private func proactiveHintBanner(_ hint: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lightbulb")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.warningText)

            Text(hint)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: {
                watchLoop.dismissTheProactiveHint()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Dismiss this suggestion")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.10))
        )
    }

    // MARK: - Device pair picker

    /// One button per branch the guide ships, labeled the way the guide labels
    /// it ("Mac + iPhone", "Windows + Android"). The pairs are a flat list
    /// rather than a computer picker and a phone picker, because that is how the
    /// guide library authors them and how the Tauri panel presents them.
    /// `.platform-switch`: a soft trough of equal segments; the chosen pair
    /// is lit with a white overlay rather than an outline.
    private var devicePairPicker: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)],
            spacing: 3
        ) {
            ForEach(guideSessionController.branchesTheReaderCanChooseBetween, id: \.branchKey) { branch in
                let thisBranchIsSelected = guideSessionController.selectedBranch?.branchKey == branch.branchKey
                Button(action: {
                    Task { await guideSessionController.selectBranch(withBranchKey: branch.branchKey) }
                }) {
                    Text(branch.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(
                            thisBranchIsSelected ? DS.Colors.ink : DS.Colors.muted
                        )
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(thisBranchIsSelected ? Color.white.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
    }

    // MARK: - Unsupported pair

    /// Shown instead of steps, never alongside them. Windows plus an iPhone is
    /// a genuine dead end — Apple only signs iPhone builds on macOS — and the
    /// honest thing is to say so and list what the reader can do instead.
    ///
    /// The reason and the alternatives are rendered as real paragraphs and real
    /// bullets here. The shipped Tauri panel collapses them into one running
    /// line because its error paragraph has no `pre-wrap`; that is a rendering
    /// bug on that side, not a behavior worth reproducing.
    private func unsupportedPairExplanation(_ unsupportedPair: IrisUnsupportedPair) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(unsupportedPair.headline)
                .font(.system(size: 18, weight: .bold))
                .tracking(-0.6)
                .foregroundColor(DS.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(unsupportedPair.reason)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.muted)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)

            if !unsupportedPair.alternatives.isEmpty {
                Text("What you can do instead:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.top, 2)

                ForEach(Array(unsupportedPair.alternatives.enumerated()), id: \.offset) { _, alternative in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text(alternative)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Completion

    private var completionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(guideSessionController.completionHeadline)
                .font(.system(size: 18, weight: .bold))
                .tracking(-0.6)
                .foregroundColor(DS.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("Every step in this branch is done. Iris will stay out of your way now.")
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.muted)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: {
                guideSessionController.restartTheGuide()
            }) {
                Text("Start over")
            }
            .irisTextButton(fontSize: 10)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Step card

    @ViewBuilder
    private var stepCard: some View {
        if let step = guideSessionController.currentStep {
            VStack(alignment: .leading, spacing: 10) {
                // `.step-card h1`: 18/650 with tight tracking. The step title
                // is the loudest thing on the panel, exactly like the pill.
                Text(step.title)
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.6)
                    .foregroundColor(DS.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)

                let bodyText = guideSessionController.bodyTextForTheCurrentStep
                if !bodyText.isEmpty {
                    Text(bodyText)
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.muted)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Why the reader is not where they left off. Rendered because
                // a position that silently changes under somebody is eerie, and
                // because an explanation written and never shown is a bug this
                // codebase has now shipped three times.
                if let positionCorrection = guideSessionController.positionWasCorrectedExplanation {
                    Text(positionCorrection)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.amber)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let proactiveHint = watchLoop.proactiveHintForTheReader {
                    proactiveHintBanner(proactiveHint)
                }

                if let command = guideSessionController.commandBlockTextForTheCurrentStep {
                    commandBlock(command: command)
                }

                if !guideSessionController.toolCheckRows.isEmpty {
                    toolCheckRowsSection
                }

                if case .openLinkIsUnavailable(let linkURLString, let reason) =
                    guideSessionController.primaryActionForTheCurrentStep {
                    blockedLinkNotice(linkURLString: linkURLString, reason: reason)
                }

                if let verifierLabel = step.verifierLabel, !verifierLabel.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text(verifierLabel)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The command with its own Copy button. The confirmation is transient and
    /// says where the command is meant to go, because "Copied" alone leaves the
    /// reader to work out what to do with it.
    /// `.command-block`: a sunken near-black well with 10pt mono text and the
    /// Copy chip riding in its corner.
    private func commandBlock(command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Colors.commandText)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: {
                    guideSessionController.copyCommandToClipboard(command)
                }) {
                    Text(guideSessionController.transientCopyConfirmationText == nil ? "Copy" : "Copied")
                }
                .irisTinyButton()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(Color.black.opacity(0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .strokeBorder(DS.Colors.line, lineWidth: 1)
            )

            if let transientCopyConfirmationText = guideSessionController.transientCopyConfirmationText {
                Text(transientCopyConfirmationText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.green)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: DS.Animation.fast), value: guideSessionController.transientCopyConfirmationText)
    }

    private var toolCheckRowsSection: some View {
        toolCheckRowsList(guideSessionController.toolCheckRows)
    }

    private func toolCheckRowsList(_ toolCheckRows: [GuideToolCheckRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(toolCheckRows) { toolCheckRow in
                HStack(spacing: 6) {
                    Text(markForToolCheckState(toolCheckRow.state))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(colorForToolCheckState(toolCheckRow.state))
                        .frame(width: 12, alignment: .center)

                    Text("\(toolCheckRow.toolName) · \(toolCheckRow.detailText)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func markForToolCheckState(_ toolCheckState: GuideToolCheckState) -> String {
        switch toolCheckState {
        case .readyToCheck: return "·"
        case .checking: return "…"
        case .installedWithVersion: return "✓"
        case .notInstalled: return "×"
        case .couldNotBeChecked: return "!"
        }
    }

    private func colorForToolCheckState(_ toolCheckState: GuideToolCheckState) -> Color {
        switch toolCheckState {
        case .readyToCheck, .checking: return DS.Colors.textTertiary
        case .installedWithVersion: return DS.Colors.success
        case .notInstalled, .couldNotBeChecked: return DS.Colors.destructiveText
        }
    }

    // MARK: - Setup recovery

    /// The detour shown when the branch needs a tool this computer does not
    /// have. It deliberately does not look like a step of the guide: a tinted
    /// card, a "Setup" badge, and an explanation of what is missing and why come
    /// before anything the reader is asked to do — otherwise "Install Node"
    /// reads as step one of the install and the count that follows makes no
    /// sense against the website they came from.
    private func setupRecoveryCard(_ setupRecoveryState: GuideSetupRecoveryState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("SETUP")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.Colors.warningText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(DS.Colors.warning.opacity(0.16))
                    )
                Text("Before the guide can start")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Text(guideSessionController.headlineForTheSetupRecoveryCard)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            let explanation = guideSessionController.explanationForTheSetupRecoveryCard
            if !explanation.isEmpty {
                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            toolCheckRowsList(setupRecoveryState.prerequisiteCheckRows)

            if let messageFromTheMostRecentRecheck = setupRecoveryState.messageFromTheMostRecentRecheck {
                // Pressing "Check again" and seeing nothing change is the exact
                // moment a reader decides the app is broken, so the result of
                // every re-check is spelled out even when it is bad news.
                Text(messageFromTheMostRecentRecheck)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .overlay(DS.Colors.borderSubtle)
                .padding(.vertical, 2)

            setupRecoveryStepBody(setupRecoveryState)

            Button(action: {
                guideSessionController.skipSetupRecoveryAndContinueToTheGuide()
            }) {
                Text("Skip this and open the guide anyway")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .underline()
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Use this if you already have it installed under a name Iris cannot see.")
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.warning.opacity(0.24), lineWidth: 0.5)
        )
    }

    /// The one setup step the reader is on, with the same affordances a guide
    /// step has: the command with its Copy button, or the download link, and the
    /// line telling them what "done" will look like.
    @ViewBuilder
    private func setupRecoveryStepBody(_ setupRecoveryState: GuideSetupRecoveryState) -> some View {
        if let setupStep = setupRecoveryState.currentSetupStep {
            VStack(alignment: .leading, spacing: 8) {
                if setupRecoveryState.setupStepsToWalk.count > 1 {
                    Text("Step \(setupRecoveryState.currentSetupStepIndex + 1) of \(setupRecoveryState.setupStepsToWalk.count) to fix this")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Text(setupStep.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                let bodyText = guideSessionController.bodyTextForTheCurrentStep
                if !bodyText.isEmpty {
                    Text(bodyText)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let command = guideSessionController.commandBlockTextForTheCurrentStep {
                    commandBlock(command: command)
                }

                if case .openLinkIsUnavailable(let linkURLString, let reason) =
                    guideSessionController.primaryActionForTheCurrentStep {
                    blockedLinkNotice(linkURLString: linkURLString, reason: reason)
                }

                if let verifierLabel = setupStep.verifierLabel, !verifierLabel.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text(verifierLabel)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A step whose link host is not allowlisted. The URL is shown in full so
    /// the reader can still open it themselves after deciding they trust it —
    /// which is the whole difference between a refusal and a dead end.
    private func blockedLinkNotice(linkURLString: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(reason)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.warningText)
                .fixedSize(horizontal: false, vertical: true)

            Text(linkURLString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.10))
        )
    }

    // MARK: - Navigation

    @ViewBuilder
    private var navigationRow: some View {
        if guideSessionController.unsupportedPairForTheSelectedBranch == nil {
            VStack(alignment: .leading, spacing: 6) {
                if let primaryAction = guideSessionController.primaryActionForTheCurrentStep {
                    primaryActionButton(primaryAction)
                }

                if guideSessionController.canReturnToThePreviousStep {
                    Button(action: {
                        guideSessionController.returnToThePreviousStep()
                    }) {
                        Text("Back")
                    }
                    .irisTextButton(fontSize: 10)
                }
            }
        }
    }

    /// The one button that drives the step: the full-width ink pill from
    /// `.guide-actions .primary-action`. A blocked link renders it visibly
    /// disabled rather than pressable-but-inert: the reason is already on the
    /// card above, and a button that looks live and does nothing is the exact
    /// failure `iris-desktop 0.1.4` was released to fix.
    private func primaryActionButton(_ primaryAction: GuideStepPrimaryAction) -> some View {
        Button(action: {
            guideSessionController.performPrimaryAction()
        }) {
            Text(primaryAction.buttonLabel)
        }
        .irisPrimaryPill()
        .disabled(!primaryAction.isPressable)
        .opacity(primaryAction.isPressable ? 1.0 : 0.55)
        .nativeTooltip(
            primaryAction.isPressable
                ? nil
                : "Iris is not allowed to open this link."
        )
    }
}

// MARK: - Starting a guide without a deep link

/// The way in when nobody clicked an `iris://` link: type a slug. Deliberately
/// a text field rather than a hard-coded catalog, because a list of guides
/// baked into this app would go stale the moment publik publishes another one.
struct GuideSlugEntryView: View {
    @ObservedObject var guideSessionController: GuideSessionController
    @State private var slugInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Follow an install guide")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.muted)

            HStack(spacing: 8) {
                TextField("App name, e.g. cue", text: $slugInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(DS.Colors.surfaceRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(DS.Colors.line, lineWidth: 1)
                    )
                    .onSubmit {
                        openTheTypedGuide()
                    }

                Button(action: {
                    openTheTypedGuide()
                }) {
                    Text("Open")
                }
                .irisPrimaryPill(isFullWidth: false, isCompact: true)
                .disabled(trimmedSlugInput.isEmpty)
                .opacity(trimmedSlugInput.isEmpty ? 0.55 : 1.0)
            }
        }
    }

    /// Slugs are lowercase by rule (`IrisDeepLinkParser.isValidGuideSlug`), so
    /// somebody typing "Cue" gets the guide rather than a validation error.
    private var trimmedSlugInput: String {
        slugInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func openTheTypedGuide() {
        let slugToOpen = trimmedSlugInput
        guard !slugToOpen.isEmpty else { return }
        slugInput = ""
        Task { await guideSessionController.openLatestVersionOfGuide(slug: slugToOpen) }
    }
}

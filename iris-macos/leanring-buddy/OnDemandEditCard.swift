//
//  OnDemandEditCard.swift
//  leanring-buddy
//
//  The whole visible surface of a USER-INITIATED edit, rendered in the bar-top
//  slot at the eye where MaintainAskCard renders — but driven by
//  OnDemandEditCoordinator, NOT the maintain ask. One card that changes what it
//  holds as the flow moves through its phases: describe the change, consent to
//  start (Consent #1), watch it run, review the committed diff and keep or
//  discard it (Consent #2), and read the honest result.
//
//  Every honesty rail the coordinator enforces is reflected in the copy here and
//  nowhere contradicted:
//    - The kind (bug fix vs feature) is an EXPLICIT tap in the describe step,
//      only ever preselected from the phrasing, never silently inferred — it
//      drives the honesty label and the commit trailer.
//    - A feature result is presented as "applied and rebuilt", never "verified"
//      — the engine is structurally incapable of elevating it, and this card
//      must not claim otherwise.
//    - The diff preview is a keep/discard choice over a real committed branch,
//      and the copy is honest that, for code the reader did not write, it is
//      informational — the safety lives in the containment rails, not in the
//      reader's ability to audit an unfamiliar diff.
//    - Out-of-budget ("too large"), a blocked build-script edit, and a genuine
//      verification failure read as three distinct outcomes, so a burnt loop
//      budget never looks like a broken app.
//
//  The visual language is MaintainAskCard's: the glass shell (readable over the
//  reader's real desktop, since the bar floats over it), the ink pill and text
//  buttons, and the `.clickyResizePanelToContent` nudge so the surface it lives
//  in re-measures as the card grows and shrinks between phases.
//

import AppKit
import SwiftUI

private struct OnDemandEditPlanContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// THE WORDS OFF A FAILURE CARD, AS ONE BLOCK OF TEXT.
///
/// Test 7 (Akrit, 0.9.1 build 17), reading a refusal he did not understand:
/// "i can't copy paste text on that tab with the error" — the same complaint
/// Test 4 made. `.textSelection(.enabled)` on every line is half the answer and
/// only half, and the missing half is not a SwiftUI detail: this card lives in
/// the eye's input-bar panel, whose `canBecomeKey` is FALSE for every phase
/// except "a question is being composed" (`OverlayEyeInputBar`, by design — a
/// panel that keeps the keyboard swallows the reader's typing in their own
/// app). A window that cannot become key is never sent a key event, so ⌘C on a
/// failure card has nowhere to go no matter how selectable the text is.
///
/// A button needs no key window. So the words also come off the card the one
/// way that cannot be blocked by focus, and this is the text it copies:
/// everything the reader can see, in reading order, so what lands on the
/// clipboard is what was on screen.
enum OnDemandEditFailureText {
    static func everythingOnTheCard(title: String, lines: [String]) -> String {
        ([title] + lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .joined(separator: "\n\n")
    }

    /// Replaces the clipboard's contents with the card's words.
    static func copyToTheClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct OnDemandEditCard: View {
    @Environment(\.irisUsesUnifiedPanel) private var usesUnifiedPanel
    @ObservedObject var coordinator: OnDemandEditCoordinator

    /// A preselect for the kind picker, taken from the phrasing that opened the
    /// flow (a "fix a bug in…" chip preselects bug fix, "add a feature to…"
    /// preselects feature). It is only a starting point — the reader's explicit
    /// pick in the picker always wins. Defaulted so a preview still builds.
    var preselectedKind: OnDemandEditKind? = nil

    /// Brings the centered terminal back after the reader minimized a running
    /// edit. Defaulted to a no-op so previews and the settings-panel path (which
    /// has no takeover to reopen) build without wiring it. See
    /// `CompanionManager.reopenOnDemandEditTakeoverTerminal`.
    var onReopenTerminal: () -> Void = {}

    /// What the reader is typing into the describe field. Local because it is
    /// UI-only until they tap Continue, at which point the coordinator scrubs it
    /// and takes ownership.
    @State private var describeText: String = ""

    /// The reader's explicit fix/feature choice. Reset from `preselectedKind`
    /// each time a new app is picked, so the picker never carries a stale choice
    /// from the previous edit into a new one.
    @State private var selectedKind: OnDemandEditKind = .bugFix

    /// The reader's single-select answer to each clarification question (plan
    /// §7), keyed by the question's stable id. Local because it is UI-only until
    /// the whole batch is submitted at once, at which point the coordinator takes
    /// ownership. Cleared whenever the question set changes so a stale answer from
    /// one batch can never leak into the next.
    @State private var clarificationSelectionsByQuestionId: [String: String] = [:]
    @State private var clarificationWrittenAnswers: [String: String] = [:]

    /// The reader's answer to the model's BLOCKED question, typed into the
    /// blocked card before "Answer and retry".
    @State private var blockedQuestionAnswerText: String = ""

    /// Momentary, so the Copy button can say it worked. See
    /// `copyTheseWordsButton`.
    @State private var justCopiedTheWords: Bool = false
    @State private var recoveryFilesCouldNotBeFound = false
    @State private var stopUndoConfirmationIsShowing = false
    @State private var runningDetailsAreExpanded = false
    @State private var savedWithoutInstallationDetailsAreExpanded = false
    @State private var testCandidateDetailsAreExpanded = false
    @State private var planTechnicalDetailsAreExpanded = false
    @State private var measuredPlanContentHeight: CGFloat = 0
    @State private var verificationFailureDetailsAreExpanded = false

    var body: some View {
        Group {
            if coordinator.savedVersionUndoIsPending || coordinator.undoIsInProgress || coordinator.isCheckingInterruptedUndo {
                undoProgressCard
            } else if let undoFailure = coordinator.undoFailureMessage {
                undoRecoveryCard(message: undoFailure, canRetry: coordinator.canRetryUndo || coordinator.canResumeInterruptedUndo)
            } else if let interruptedRecovery = coordinator.interruptedUndoRecoveryMessage {
                undoRecoveryCard(message: interruptedRecovery, canRetry: coordinator.canResumeInterruptedUndo)
            } else if coordinator.phase == .done, let stoppedRecovery = coordinator.stoppedUndoRecoveryMessage {
                stoppedUndoCard(message: stoppedRecovery)
            } else {
                switch coordinator.phase {
            case .pickApp:
                // Nothing is pending — the card contributes nothing to the bar.
                EmptyView()
            case .describe:
                describeCard
            case .clarifying:
                clarifyingCard
            case .presentingPlan:
                planCard
            case .awaitingStartConsent:
                startConsentCard
            case .running:
                // The run is watched in the terminal takeover; the bar's body is
                // suppressed while that covers the screen. This compact line is
                // only the fallback for the instant before/after the takeover.
                runningCard
            case .previewDiff:
                if coordinator.isUnverifiedTestCandidate {
                    unverifiedTestCandidateCard
                } else {
                    previewCard
                }
            case .committing:
                committingCard
            case .awaitingManifestConsent:
                manifestConsentCard
            case .awaitingMachineCommandConsent:
                machineCommandConsentCard
            case .delivering:
                deliveringCard
            case .awaitingSymptomConfirmation:
                symptomConfirmationCard
            case .awaitingRelaunchConsent:
                relaunchConsentCard
            case .relaunching:
                relaunchingCard
            case .awaitingForceQuitConsent:
                forceQuitConsentCard
            case .done:
                doneCard
            case .failed(let reason):
                terminalMessageCard(reason: reason, isRefusal: false)
            case .notEligible(let reason):
                terminalMessageCard(reason: reason, isRefusal: true)
            case .blockedByModel(let explanation):
                blockedByModelCard(explanation: explanation)
                }
            }
        }
        // The bar this lives in re-measures its own height, but the settings
        // panel does not measure unless nudged — the same nudge MaintainAskCard
        // uses, so the card is never clipped as it changes phase.
        .onChange(of: coordinator.phase) { _, _ in
            runningDetailsAreExpanded = false
            savedWithoutInstallationDetailsAreExpanded = false
            planTechnicalDetailsAreExpanded = false
            measuredPlanContentHeight = 0
            verificationFailureDetailsAreExpanded = false
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
        .onChange(of: coordinator.isRecheckingSavedChanges) { _, _ in
            planTechnicalDetailsAreExpanded = false
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
        .onChange(of: coordinator.isPreparingSavedChangeRecheck) { _, _ in
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
        .onChange(of: coordinator.isCheckingInterruptedUndo) { _, _ in
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
        // A brand-new pick starts from a clean field and the phrasing's
        // preselect — never the previous edit's leftovers.
        .onChange(of: coordinator.activeAppSlug) { _, _ in
            describeText = ""
            selectedKind = preselectedKind ?? .bugFix
            clarificationSelectionsByQuestionId = [:]
            clarificationWrittenAnswers = [:]
            recoveryFilesCouldNotBeFound = false
        }
        // The clarification batch is recomputed per request; whenever the set of
        // questions changes (a new batch, or the batch clearing as the flow
        // leaves `.clarifying`), drop any prior selections so an answer from one
        // batch can never carry into another.
        .onChange(of: coordinator.clarificationQuestions) { _, _ in
            clarificationSelectionsByQuestionId = [:]
            clarificationWrittenAnswers = [:]
        }
        // A retry (after "still broken", or after answering a BLOCKED question)
        // re-enters describe with the field prefilled — consumed once so a
        // later fresh pick starts clean.
        .onChange(of: coordinator.describePrefillText) { _, prefill in
            guard let prefill else { return }
            describeText = prefill
            coordinator.consumeDescribePrefill()
        }
        .onAppear {
            selectedKind = preselectedKind ?? .bugFix
        }
        .alert("Stop this Undo?", isPresented: $stopUndoConfirmationIsShowing) {
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("Stop this Undo", role: .destructive) {
                coordinator.stopUndoAndKeepRecoveryInformation()
            }
        } message: {
            Text("Iris will leave the app and its working files as they are now. This does not confirm which version is installed. Recovery details will stay saved, and the affected app will remain protected from further edits.")
        }
        .animation(DS.Motion.contentIn, value: coordinator.phase)
    }

    private var appName: String { coordinator.activeAppName ?? "this app" }

    private var runningStatusText: String {
        coordinator.statusLine ?? (coordinator.isRecheckingSavedChanges
            ? "Checking the saved change…"
            : "Working on your change…")
    }

    private var changeNeedsDeliveryFollowup: Bool {
        coordinator.deliveryProgress.codeSaved
            && (!coordinator.deliveryProgress.installedCopyReplaced
                || !coordinator.deliveryProgress.relaunched)
    }

    private var undoProgressCard: some View {
        card {
            header(icon: "arrow.uturn.backward", title: "Restoring the previous version")
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(coordinator.statusLine ?? "Checking each recovery step…")
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func undoRecoveryCard(message: String, canRetry: Bool = true) -> some View {
        card {
            header(icon: "exclamationmark.triangle", title: canRetry ? "Undo needs attention" : "Undo was interrupted")
            Text(message)
                .font(DS.Typography.body)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(canRetry
                 ? "Retry the unfinished steps, or stop this Undo and leave the app as it is."
                 : "Iris has not restarted Undo. You can stop this Undo and keep the recovery details. History and Settings remain available.")
                .font(DS.Typography.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !canRetry {
                DisclosureGroup("Review recovery details") {
                    Text(coordinator.undoRecoveryPaths.joined(separator: "\n"))
                        .font(DS.Typography.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .font(DS.Typography.caption)
                .pointerCursor()
            }
            if recoveryFilesCouldNotBeFound {
                Text("The saved locations could not be found. Copy these details so someone can help you recover the app.")
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Show recovery files") {
                    let existingLocations = coordinator.undoRecoveryPaths
                        .filter { FileManager.default.fileExists(atPath: $0) }
                        .map { URL(fileURLWithPath: $0) }
                    recoveryFilesCouldNotBeFound = existingLocations.isEmpty
                    if !existingLocations.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(existingLocations)
                    }
                }
                .irisTinyButton()
                .help("Shows the saved app and project locations in Finder without changing them.")
                Spacer(minLength: 0)
                if canRetry {
                    Button("Retry Undo") {
                        recoveryFilesCouldNotBeFound = false
                        if coordinator.interruptedUndoRequiresReview {
                            coordinator.resumeInterruptedUndo()
                        } else {
                            coordinator.undoDeliveredChange()
                        }
                    }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
                }
            }
            copyTheseWordsButton(
                title: canRetry ? "Undo needs attention" : "Undo was interrupted",
                lines: [message] + coordinator.undoRecoveryPaths
            )
            if coordinator.canStopUndo {
                Button("Stop this Undo…") {
                    stopUndoConfirmationIsShowing = true
                }
                .irisTinyButton()
                .help("Keep the app as it is and save recovery details without claiming restoration succeeded.")
            }
        }
    }

    private func stoppedUndoCard(message: String) -> some View {
        card {
            header(icon: "pause.circle", title: "Undo stopped")
            Text(message)
                .font(DS.Typography.body)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Find these details later in Settings under Saved recovery details.")
                .font(DS.Typography.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Show recovery files") {
                    let locations = coordinator.stoppedUndoRecoveryPaths
                        .filter { FileManager.default.fileExists(atPath: $0) }
                        .map { URL(fileURLWithPath: $0) }
                    recoveryFilesCouldNotBeFound = locations.isEmpty
                    if !locations.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(locations) }
                }
                .irisTinyButton()
                Spacer(minLength: 0)
                Button("Browse apps") {
                    UserDefaults.standard.set("Apps", forKey: "irisSettingsSection")
                    NotificationCenter.default.post(name: .clickyShowPanel, object: nil)
                }
                .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
            if recoveryFilesCouldNotBeFound {
                Text("The saved locations could not be found. Copy the details below for help.")
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.amber)
            }
            copyTheseWordsButton(title: "Undo stopped; restoration unconfirmed", lines: [message] + coordinator.stoppedUndoRecoveryPaths)
        }
    }

    // MARK: - Describe

    private var describeCard: some View {
        card {
            header(
                icon: coordinator.isRecheckingSavedChanges ? "checkmark.circle" : "wand.and.stars",
                title: coordinator.isRecheckingSavedChanges ? "Recheck saved changes" : "Edit \(appName)"
            )

            Text(coordinator.isRecheckingSavedChanges
                 ? "Confirm what the saved change should do. Iris will recheck it without rewriting the code."
                 : "Iris changes a working copy, then updates and reopens the installed app when supported. Successful fixes may be sent to its developers for review; feature updates may be recorded in publik.")
                .font(DS.Typography.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !coordinator.isRecheckingSavedChanges {
                savedChangeRecheckAction

                // The explicit fix/feature pick. It is a real choice, not a
                // convenience: it decides the honesty label and the commit trailer.
                HStack(spacing: 8) {
                    kindPill(.bugFix, label: "Bug fix")
                    kindPill(.feature, label: "Feature")
                }
            }

            TextField(
                coordinator.isRecheckingSavedChanges
                    ? "What should the saved change do?"
                    : "What should change?",
                text: $describeText,
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.ink)
                .lineLimit(1...5)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.surfaceRaised)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .strokeBorder(DS.Colors.line, lineWidth: 1)
                        )
                )

            // "Others also wanted…" prefills, only when the pool actually
            // returned some (it is k>=5-gated server-side, never one person's
            // wish echoed back). A saved-change recheck is deliberately driven
            // by the reader's fresh description, not by historical suggestions.
            if !coordinator.isRecheckingSavedChanges && !coordinator.suggestedRequests.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Others also wanted")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                    ForEach(coordinator.suggestedRequests.prefix(5), id: \.self) { suggestion in
                        Button(action: { describeText = suggestion }) {
                            Text(suggestion).lineLimit(1)
                        }
                        .irisTinyButton()
                    }
                }
            }

            // A validation reason (empty, or too large up front) lands in the
            // status line while the flow stays in describe, so it reads here.
            if let statusLine = coordinator.statusLine {
                Text(statusLine)
                    .font(.system(size: 10.5))
                    .foregroundColor(DS.Colors.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The request probe (the two model-derived §7 triggers) runs
            // between Continue and clarify-or-plan; the flow stays here in
            // describe, so this row is what tells the reader Iris is working
            // and not ignoring the tap.
            if coordinator.isAssessingRequest {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Sizing up the request…")
                        .font(.system(size: 10.5))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }

            HStack(spacing: 8) {
                Button("Cancel") { coordinator.cancel() }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button(coordinator.isRecheckingSavedChanges ? "Continue to recheck" : "Continue") {
                    coordinator.describeRequest(describeText, kind: selectedKind)
                }
                .irisPrimaryPill(isFullWidth: false, isCompact: true)
                .disabled(
                    describeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || coordinator.isAssessingRequest
                        || coordinator.isPreparingSavedChangeRecheck
                )
            }
        }
    }

    /// A held failed edit can be checked again from a fresh, reader-owned
    /// description. This stays in the existing card rather than opening a
    /// second recovery surface; the coordinator owns the saved-source guards.
    @ViewBuilder
    private var savedChangeRecheckAction: some View {
        if coordinator.canRecheckSavedChanges || coordinator.isPreparingSavedChangeRecheck {
            VStack(alignment: .leading, spacing: 4) {
                Button(coordinator.isPreparingSavedChangeRecheck
                       ? "Preparing recheck…"
                       : "Recheck saved changes") {
                    coordinator.prepareSavedChangeRecheck()
                }
                .irisPrimaryPill(isFullWidth: true, isCompact: true)
                .disabled(coordinator.isPreparingSavedChangeRecheck)
                .help("Review the saved source with a fresh description without asking Iris to rewrite it.")

                if !coordinator.isRecheckingSavedChanges {
                    Text("Use a fresh description to confirm what the saved change should do before Iris checks it.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One of the two kind choices, drawn as a selectable pill. The selected one
    /// carries the accent so the current choice is unmistakable before the
    /// reader commits to Continue.
    private func kindPill(_ kind: OnDemandEditKind, label: String) -> some View {
        let isSelected = selectedKind == kind
        return Button(action: { selectedKind = kind }) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(isSelected ? DS.Colors.accent : DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(isSelected ? DS.Colors.accent.opacity(0.14) : DS.Colors.surfaceRaised)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .strokeBorder(
                                    isSelected ? DS.Colors.accent.opacity(0.5) : DS.Colors.line,
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Clarify (plan §7)

    /// The batched clarification questions (plan §7), rendered as a compact,
    /// tappable set — a couple of decisive questions answered in ONE round before
    /// any edit, never a chat interrogation. Each question is single-select; the
    /// whole batch submits at once so the coordinator gets the reader's answers
    /// together (including a "Stop…" option, which the coordinator treats as an
    /// explicit abort back to the describe step — nothing here has been touched).
    private var clarifyingCard: some View {
        card {
            if let proposal = coordinator.pendingHarnessScopeReconciliation {
                scopeReconciliationContent(proposal)
            } else {
                clarificationQuestionContent
            }
        }
    }

    @ViewBuilder
    private var clarificationQuestionContent: some View {
            header(icon: "questionmark.circle", title: coordinator.clarificationQuestions.count == 1
                   ? "A quick question" : "A couple of questions")

            Text(coordinator.statusLine ?? "Before Iris starts, help it get this right.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(coordinator.clarificationQuestions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.prompt)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Options can be full sentences (a build-command escape hatch,
                    // a rollout posture), so each is a wrapping full-width row, not
                    // an inline pill that would clip.
                    ForEach(question.options, id: \.self) { option in
                        clarificationOptionRow(question: question, option: option)
                            .disabled(coordinator.isAssessingRequest)
                    }
                    if coordinator.allowsWrittenClarification {
                        TextField("Or describe what you mean", text: Binding(
                            get: { clarificationWrittenAnswers[question.id] ?? "" },
                            set: { clarificationWrittenAnswers[question.id] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .accessibilityLabel("Your answer to " + question.prompt)
                            .disabled(coordinator.isAssessingRequest)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Cancel") { coordinator.cancel() }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button(coordinator.isAssessingRequest ? "Updating plan…" : "Continue") {
                    coordinator.submitClarificationAnswers(currentClarificationAnswers)
                }
                .irisPrimaryPill(isFullWidth: false, isCompact: true)
                // Only enabled once EVERY question has an answer — a half-answered
                // batch would leave the plan reasoning about a choice never made.
                .disabled(!everyClarificationQuestionIsAnswered || coordinator.isAssessingRequest)
            }
    }

    @ViewBuilder
    private func scopeReconciliationContent(_ proposal: HarnessScopeReconciliation) -> some View {
        HStack {
            header(icon: "arrow.triangle.2.circlepath", title: "Update the plan?")
            Spacer(minLength: 0)
            Button("Cancel") { coordinator.cancel() }.irisTextButton()
        }
        Text("Your answer changes what Iris will build. Nothing has been edited yet.")
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(proposal.changes.enumerated()), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 3) {
                        if let previous = change.previousStatement {
                            Text("Before: " + previous)
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        Text(change.proposedStatement.map { "Now: " + $0 } ?? "Remove this requirement")
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(proposal.nonGoalChanges.enumerated()), id: \.offset) { _, change in
                    Text((change.kind == .removed ? "Remove limit: " : "New limit: ") + change.statement)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
        HStack(spacing: 8) {
            Button("Keep earlier plan") {
                coordinator.resolveHarnessScopeReconciliation(id: proposal.id, approve: false)
            }
            .irisTextButton()
            Spacer(minLength: 0)
            Button("Use updated plan") {
                coordinator.resolveHarnessScopeReconciliation(id: proposal.id, approve: true)
            }
            .irisPrimaryPill(isFullWidth: false, isCompact: true)
        }
    }

    /// True only when the reader has selected an option for every question in the
    /// current batch, so "Continue" cannot submit a partial set of answers.
    private var everyClarificationQuestionIsAnswered: Bool {
        coordinator.clarificationQuestions.allSatisfy { question in
            !(currentClarificationAnswers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var currentClarificationAnswers: [String: String] {
        var answers = clarificationSelectionsByQuestionId
        if coordinator.allowsWrittenClarification {
            for (id, answer) in clarificationWrittenAnswers where !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                answers[id] = answer
            }
        }
        return answers
    }

    /// One tappable answer to a clarification question, drawn as a wrapping
    /// full-width row with a radio mark. The selected one carries the accent so
    /// the current choice is unmistakable before the reader taps Continue.
    private func clarificationOptionRow(
        question: ClarificationQuestion, option: String
    ) -> some View {
        let isSelected = clarificationSelectionsByQuestionId[question.id] == option
            && (clarificationWrittenAnswers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: {
            clarificationSelectionsByQuestionId[question.id] = option
            clarificationWrittenAnswers[question.id] = nil
        }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? DS.Colors.accent : DS.Colors.textTertiary)
                Text(option)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isSelected ? DS.Colors.accent.opacity(0.12) : DS.Colors.surfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .strokeBorder(
                                isSelected ? DS.Colors.accent.opacity(0.5) : DS.Colors.line,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Plan (plan §7 — "ask once, then commit")

    /// The short pre-edit PLAN (plan §7): the files Iris expects to touch, the
    /// approach, the resolved build/test recipe in reader-facing words, any still-
    /// open questions, and the honesty rung it expects to reach — all shown BEFORE
    /// the reader approves. Approving is Consent #1: `confirmPlanAndStart()` routes
    /// through the SAME live eligibility re-check the start tap always did, so the
    /// plan is informational and never bypasses that binding gate.
    private var planCard: some View {
        card {
            header(
                icon: coordinator.isRecheckingSavedChanges ? "checkmark.circle" : "list.bullet.rectangle",
                title: coordinator.isRecheckingSavedChanges ? "Recheck plan" : "Iris's plan"
            )

            if let plan = coordinator.presentedPlan {
                // Keep consent controls outside the scroll area so a long plan
                // never pushes Start editing below the visible card.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        if coordinator.isRecheckingSavedChanges {
                            Text("Iris will check the saved source against this description without rewriting the code.")
                                .font(.system(size: 11.5))
                                .foregroundColor(DS.Colors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !coordinator.selectedHarnessDecisions.isEmpty {
                            planSection(title: "Your choices") {
                                ForEach(coordinator.selectedHarnessDecisions) { decision in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(decision.question)
                                            .font(.system(size: 10.5))
                                            .foregroundColor(DS.Colors.textSecondary)
                                        Text(decision.answer)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundColor(DS.Colors.textPrimary)
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if coordinator.isRecheckingSavedChanges {
                            planSection(title: "Desired outcome") {
                                Text(plan.approachSummary)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(DS.Colors.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else if coordinator.selectedHarnessDecisions.isEmpty {
                            Text(plan.approachSummary)
                                .font(.system(size: 11.5))
                                .foregroundColor(DS.Colors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            DisclosureGroup("Approach details") {
                                Text(plan.approachSummary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 10.5))
                            .foregroundColor(DS.Colors.textSecondary)
                            .pointerCursor()
                        }

                        if !coordinator.proposedHarnessDefaults.isEmpty {
                            DisclosureGroup("Defaults Iris is proposing") {
                                ForEach(Array(coordinator.proposedHarnessDefaults.enumerated()), id: \.offset) { _, value in
                                    Text(value).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .font(.system(size: 10.5))
                            .foregroundColor(DS.Colors.textSecondary)
                        }

                        DisclosureGroup(isExpanded: $planTechnicalDetailsAreExpanded) {
                            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                                // The file estimate is a courtesy for the reader's judgment, not a
                                // cage (the diff-scope gate is the hard cap downstream). Only shown
                                // when the plan actually carries one; an empty estimate stays
                                // silent rather than rendering an empty heading.
                                if !plan.filesToTouch.isEmpty {
                                    planSection(title: "Files Iris expects to touch") {
                                        ForEach(plan.filesToTouch, id: \.self) { path in
                                            Text(path)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(DS.Colors.commandText)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }

                                // The derived recipe in plain words: informed consent to what
                                // will later run un-jailed during verification.
                                planSection(
                                    title: coordinator.isRecheckingSavedChanges
                                        ? "How Iris will recheck it"
                                        : "How Iris will build and check it"
                                ) {
                                    Text(plan.resolvedRecipeSummary)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(DS.Colors.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                // The §9 honesty rung it expects to reach, stated up front so the
                                // reader knows the verification bar BEFORE approving the edit.
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "checklist")
                                        .accessibilityHidden(true)
                                        .font(.system(size: 10))
                                        .foregroundColor(DS.Colors.accent)
                                    Text(coordinator.isRecheckingSavedChanges
                                         ? "Acceptance criteria: \(plan.expectedRung)"
                                         : "Planned checks, not run yet: \(plan.expectedRung)")
                                        .font(.system(size: 10.5))
                                        .foregroundColor(DS.Colors.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.top, DS.Spacing.xs)
                        } label: {
                            Label("Technical details", systemImage: "info.circle")
                                .font(.system(size: 10.5))
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        .help("Shows the files, build and check details for this plan.")
                        .accessibilityHint("Expands to show the files, build and check details for this plan.")
                        .pointerCursor()
                        .onChange(of: planTechnicalDetailsAreExpanded) { _, _ in
                            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
                        }

                        // Normally empty, the batch was already answered in `.clarifying`.
                        // Render it when present so a leftover open question is never hidden
                        // behind the consent tap.
                        if !plan.openQuestions.isEmpty {
                            planSection(title: "Still open") {
                                ForEach(plan.openQuestions) { question in
                                    Text(question.prompt)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(DS.Colors.amber)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { planContentGeometry in
                            Color.clear.preference(
                                key: OnDemandEditPlanContentHeightPreferenceKey.self,
                                value: planContentGeometry.size.height
                            )
                        }
                    )
                }
                .frame(height: heightThePlanContentShouldBe)
                .onPreferenceChange(OnDemandEditPlanContentHeightPreferenceKey.self) { measuredHeight in
                    measuredPlanContentHeight = measuredHeight
                }
            }

            HStack(spacing: 8) {
                Button("Cancel") { coordinator.cancel() }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button(coordinator.isRecheckingSavedChanges ? "Start recheck" : "Start editing") {
                    coordinator.confirmPlanAndStart()
                }
                .disabled(coordinator.isPreparingSavedChangeRecheck)
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
    }

    /// The plan's content gets its natural height while it is short, but the
    /// reader-facing controls remain outside a capped viewport for long plans.
    /// A small floor prevents the first self-sizing pass from collapsing the
    /// ScrollView before its content preference has been delivered.
    private var heightThePlanContentShouldBe: CGFloat {
        min(
            max(measuredPlanContentHeight, 44),
            OverlayEyeInteractionGeometry.tallestTheAnswerAreaMayGrow
        )
    }

    /// A titled subsection of the plan card — a quiet caption over its content,
    /// matching the "Others also wanted" grouping in the describe card.
    private func planSection<Content: View>(
        title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            content()
        }
    }

    // MARK: - Start consent (Consent #1)

    private var startConsentCard: some View {
        card {
            header(
                icon: coordinator.isRecheckingSavedChanges ? "checkmark.circle" : "wand.and.stars",
                title: coordinator.isRecheckingSavedChanges ? "Recheck saved changes" : "Edit \(appName)"
            )

            Text(coordinator.statusLine ?? (coordinator.isRecheckingSavedChanges
                ? "Ready to recheck the saved change in \(appName)?"
                : "Ready to make this change to \(appName)?"))
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Cancel") { coordinator.cancel() }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button(coordinator.isRecheckingSavedChanges ? "Start recheck" : "Start editing") {
                    coordinator.confirmStartAndRun()
                }
                .disabled(coordinator.isPreparingSavedChangeRecheck)
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
    }

    // MARK: - Running

    private var runningCard: some View {
        card {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                header(
                    icon: coordinator.isRecheckingSavedChanges ? "checkmark.circle" : "wand.and.stars",
                    title: coordinator.isRecheckingSavedChanges ? "Rechecking \(appName)" : "Editing \(appName)"
                )

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .scaleEffect(0.62)
                        .frame(width: 13, height: 13)
                        .accessibilityHidden(true)

                    // The live line can contain a real command or build step.
                    // Keep the card short while exposing the complete value to
                    // VoiceOver and the native help affordance.
                    Text(runningStatusText)
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(runningStatusText)
                        .accessibilityLabel("Current activity")
                        .accessibilityValue(runningStatusText)
                }

                if coordinator.currentModelRoute != nil {
                    DisclosureGroup(isExpanded: $runningDetailsAreExpanded) {
                        modelRouteRow
                            .padding(.top, DS.Spacing.xs)
                    } label: {
                        Label("Details", systemImage: "info.circle")
                            .font(DS.Typography.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .help("Shows the model route Iris reported for this edit.")
                    .accessibilityHint("Expands to show the model route Iris reported for this edit.")
                    .pointerCursor()
                    .onChange(of: runningDetailsAreExpanded) { _, _ in
                        NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
                    }
                }

                // Stop lands at the next safe boundary and then restores the
                // source. Show terminal reopens the real takeover after it was
                // minimized.
                HStack(spacing: 8) {
                    Button {
                        coordinator.stopRunningEdit()
                    } label: {
                        Label(
                            coordinator.readerAskedToStopTheRun ? "Stopping…" : "Stop",
                            systemImage: "stop.fill"
                        )
                    }
                    .irisTextButton(isDanger: true)
                    .disabled(coordinator.readerAskedToStopTheRun)
                    .nativeTooltip("Stops the edit at the next safe point and puts the app's source back exactly as it was.")

                    if !coordinator.readerAskedToStopTheRun {
                        Button {
                            onReopenTerminal()
                        } label: {
                            Label("Show terminal", systemImage: "rectangle.on.rectangle")
                        }
                        .irisTextButton()
                        .help("Reopens the terminal you minimized so you can watch the rest of the edit.")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Preview + apply (Consent #2)

    private var unverifiedTestCandidateCard: some View {
        card {
            header(icon: "testtube.2", title: "Ready for a manual test")
            Text("The change builds and passed code review, but Iris could not find automated tests it can run for this app. Its behavior is not verified.")
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Try it in the separate test app. Iris will keep its previous version so you can Undo. Your normal app stays unchanged.")
                .font(.system(size: 10.5))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let diff = coordinator.proposedDiffText, !diff.isEmpty {
                DisclosureGroup("Code details", isExpanded: $testCandidateDetailsAreExpanded) {
                    ScrollView {
                        Text(diff)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
                .font(.system(size: 10.5))
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()
            }
            HStack(spacing: 8) {
                Button("Not now") { coordinator.dismissUnverifiedTestCandidate() }
                    .irisTextButton()
                    .help("Keep the source change saved without replacing the installed test app.")
                Spacer(minLength: 0)
                Button("Try this test build") { coordinator.tryUnverifiedTestCandidate() }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
    }

    private var previewCard: some View {
        card {
            header(icon: "text.magnifyingglass", title: "Review the change")

            Text(coordinator.statusLine ?? "Here's the change on a branch. Keep it?")
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let honestNote = honestPreviewNote {
                Text(honestNote)
                    .font(.system(size: 10.5))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The earned §9 verification RUNG + its evidence log — the honest
            // "what was actually observed" alongside the diff. Deliberately a rung
            // label + a row of observed facts, NEVER a confidence number: a number
            // invites treating a guess as a measurement, and the ladder caps the
            // rung at the first missing signal so nothing is ever claimed above
            // its evidence.
            if let earnedVerification = earnedVerificationForLastResult {
                verificationEvidenceBlock(
                    earnedRung: earnedVerification.rung,
                    evidenceLogLines: earnedVerification.evidenceLogLines
                )
            }

            if let diffText = coordinator.proposedDiffText, !diffText.isEmpty {
                ScrollView(.vertical) {
                    Text(diffText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DS.Colors.commandText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .strokeBorder(DS.Colors.line, lineWidth: 1)
                        )
                )
            }

            HStack(spacing: 8) {
                Button("Discard") { coordinator.discardChange() }
                    .irisTextButton(isDanger: true)
                Spacer(minLength: 0)
                Button("Keep it") { coordinator.keepChange() }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
    }

    /// The one honest sentence about what "kept" will and will not mean, derived
    /// from the engine's own result. A feature is never "verified"; a stack with
    /// no suite is said plainly rather than counted as a silent green.
    private var honestPreviewNote: String? {
        guard case .appliedAndRebuilt(_, _, let kind, let suitePassed, _)? = coordinator.lastResult else {
            return nil
        }
        let subject = kind == .feature ? "This feature" : "This fix"
        switch suitePassed {
        case .some(true):
            return "\(subject) builds and the app's tests stay green. Iris applied and rebuilt it — it can't automatically prove it does what you asked, so try the relaunched app to confirm."
        case .some(false):
            return "\(subject) was applied, but the suite didn't pass."
        case .none:
            return "\(subject) builds. This app has no test suite for Iris to run, so it's applied and rebuilt — not verified. Try the relaunched app to confirm it does what you asked."
        }
    }

    /// The earned §9 verification rung and its evidence-log rows, taken
    /// VERBATIM from `VerificationHarness` via the coordinator.
    ///
    /// This used to rebuild the ladder here from the result enum, opening with
    /// `collectedEvidence.compileClean = true` and the evidence row "the app
    /// built". The harness deliberately requires `outcome.build == .passed`
    /// before it will call a build clean, because a stack with no build command
    /// leaves that stage `.notRun` — absent, not green. Dropping that guard
    /// made this card assert L1 and
    /// print "Build: the app built" for a change nothing had ever compiled —
    /// a reader-facing claim of evidence that did not exist. It also ignored
    /// `symptomVerifiedByRepro`, so a genuinely three-leg-verified fix was
    /// still shown as L1/L2.
    ///
    /// Nothing is derived here now. If the harness did not earn it, it is not
    /// shown.
    private var earnedVerificationForLastResult: (rung: VerificationRung, evidenceLogLines: [String])? {
        guard case .appliedAndRebuilt? = coordinator.lastResult,
              let earned = coordinator.earnedVerification else {
            return nil
        }
        return (earned.rung, earned.evidenceLog)
    }

    /// The rung label over its evidence log, in a quiet raised block beside the
    /// diff. The rung reads as a fact ("L2 — builds, existing tests green") and
    /// each evidence row is one observed line; an unearned signal still shows its
    /// row ("no evidence collected") so a partial run can never read as a
    /// complete one.
    private func verificationEvidenceBlock(
        earnedRung: VerificationRung, evidenceLogLines: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.accent)
                Text(earnedRung.humanReadableLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(evidenceLogLines, id: \.self) { evidenceLine in
                    Text(evidenceLine)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .strokeBorder(DS.Colors.line, lineWidth: 1)
                )
        )
    }

    // MARK: - Manifest consent (the one per-run permission the model can ask for)

    /// The model declared a dependency / plist key / entitlement it is not
    /// allowed to write; Iris's own code applies it after this tap, then the
    /// un-jailed build runs WITH it — which is exactly why it is asked.
    private var manifestConsentCard: some View {
        card {
            header(icon: "shippingbox", title: "Iris needs a permission")

            Text(coordinator.pendingManifestChangeSummary ?? "Iris wants to add a dependency or build setting.")
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Iris will apply this itself (the model never edits build files) and then build with it. A dependency's own build scripts run during that build.")
                .font(.system(size: 10.5))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Decline") { coordinator.declineManifestChange() }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button("Allow") { coordinator.approveManifestChange() }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
    }

    // MARK: - Machine-state command consent (broadened scope, Sep 1 2026)

    /// Iris found the cause on the Mac itself, not in the app, and wants to run
    /// one command to fix it. The command is shown verbatim and selectable —
    /// consent to a command you cannot read is not consent — and the run
    /// happens only on Allow, outside the jail, still past the risk gate.
    private var machineCommandConsentCard: some View {
        card {
            header(icon: "gearshape.2", title: "Iris wants to fix this on your Mac")

            Text(coordinator.pendingMachineCommandReason.isEmpty
                ? "The cause is a setting on this Mac, not the app's code."
                : coordinator.pendingMachineCommandReason)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let command = coordinator.pendingMachineCommand {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.surfaceRaised)
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .strokeBorder(DS.Colors.line, lineWidth: 1)
                            )
                    )
            }

            Text("Iris runs this on your Mac, not inside the app's folder. It never edited your source. Nothing has run yet.")
                .font(.system(size: 10.5))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Not now") { coordinator.declinePendingMachineCommand() }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button("Run it") { coordinator.approvePendingMachineCommand() }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
    }

    // MARK: - Automatic delivery (rebuild + relaunch, no taps)

    private var deliveringCard: some View {
        card {
            header(icon: "arrow.triangle.2.circlepath", title: "Putting the fix into \(appName)")
            verificationReceiptRows
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.62)
                    .frame(width: 13, height: 13)
                Text(coordinator.statusLine ?? "Rebuilding and relaunching…")
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Symptom re-check (the only end-to-end truth signal)

    /// After the rebuilt app relaunches: the reader's OWN complaint, what Iris
    /// observed when it looked again, and the verdict — the one question that
    /// matters. Undo is always one tap away.
    private var symptomConfirmationCard: some View {
        card {
            header(icon: "questionmark.circle", title: "Ready for your test")

            verificationReceiptRows

            if let complaint = coordinator.activeRequestText {
                DisclosureGroup {
                    Text(complaint)
                        .font(DS.Typography.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text("Your request: \(complaint)")
                        .font(DS.Typography.caption)
                        .lineLimit(2)
                }
                    .foregroundColor(DS.Colors.textPrimary)
            }

            HStack(spacing: 6) {
                if coordinator.symptomRecheckSummary == nil {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.62)
                        .frame(width: 13, height: 13)
                }
                Text(coordinator.symptomRecheckSummary ?? "\(appName) relaunched. Iris is looking again; behavior is not confirmed yet.")
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Still broken") { coordinator.recordSymptomVerdict(.stillBroken) }
                    .irisTextButton(isDanger: true)
                Button("Can't tell yet") { coordinator.recordSymptomVerdict(.cannotTell) }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button("Fixed") { coordinator.recordSymptomVerdict(.fixed) }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }

            if (coordinator.classifiedKind == .feature
                && coordinator.pushFeatureChangelogToPublik != nil)
                || (coordinator.classifiedKind != .feature
                    && coordinator.openPullRequestForTheKeptEdit != nil) {
                Text(coordinator.classifiedKind == .feature
                    ? "Confirming this feature can publish an update note in publik."
                    : "Confirming this fix can send it to the app's developers for review.")
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Undo this change") { coordinator.undoDeliveredChange() }
                    .irisTinyButton()
                    .help("Attempts to restore the previous installed version of \(appName) and discard this change.")
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Blocked by the model (honest refusal + question hand-back)

    /// The model declared, after investigating, that it could not make the
    /// change under its constraints — its sentence verbatim, and if it asked
    /// something, a field to answer and retry. Nothing was changed.
    private func blockedByModelCard(explanation: String) -> some View {
        card {
            header(icon: "hand.raised", title: "Iris stopped on purpose")

            Text(explanation)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let question = coordinator.blockedQuestionForUser {
                Text("Iris needs to know: \(question)")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.amber)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Your answer", text: $blockedQuestionAnswerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(DS.Colors.ink)
                    .lineLimit(1...4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.surfaceRaised)
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .strokeBorder(DS.Colors.line, lineWidth: 1)
                            )
                    )
            }

            Text("Nothing was changed.")
                .font(.system(size: 10.5))
                .foregroundColor(DS.Colors.textSecondary)
                .textSelection(.enabled)

            // A whole class of block is not "this code cannot be changed" but
            // "the binary on disk is stale or was built outside the signed .app
            // workflow" — which no source edit fixes and a rebuild fixes
            // completely. Iris already derives that exact build command for this
            // app's stack and already runs it on the success path, so handing
            // the reader a command to paste was the one thing it should not do.
            if coordinator.irisCanRebuildTheBlockedApp {
                Button("Rebuild \(appName) for me") {
                    coordinator.rebuildAndRelaunchTheBlockedApp()
                }
                .irisPrimaryPill(isFullWidth: true, isCompact: true)
                .padding(.top, 2)

                Text("Runs the build this project declares, from its clone, then relaunches it.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                // Copy sits leftmost on BOTH terminal cards, so a reader who
                // has found it once knows where it is the next time.
                copyTheseWordsButton(
                    title: "Iris stopped on purpose",
                    lines: [
                        explanation,
                        coordinator.blockedQuestionForUser.map { "Iris needs to know: \($0)" } ?? "",
                        "Nothing was changed.",
                    ]
                )
                Button("Done") { coordinator.cancel() }
                    .irisTextButton()
                Spacer(minLength: 0)
                if coordinator.blockedQuestionForUser != nil {
                    Button("Answer and retry") {
                        coordinator.retryAfterAnsweringBlockedQuestion(blockedQuestionAnswerText)
                        blockedQuestionAnswerText = ""
                    }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
                    .disabled(blockedQuestionAnswerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("Try again") { coordinator.retryAfterAnsweringBlockedQuestion("") }
                        .irisPrimaryPill(isFullWidth: false, isCompact: true)
                }
            }
        }
    }

    // MARK: - Relaunch consent (Consent #3, DESTRUCTIVE)

    private var relaunchConsentCard: some View {
        card {
            header(icon: "arrow.triangle.2.circlepath", title: "Relaunch \(appName)?")

            Text(coordinator.relaunchConsentPrompt)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                // Declining is safe — the change stays on the branch. The
                // primary action is destructive, so the decline sits on the left
                // as the calm default and the quit-and-relaunch carries the
                // danger styling.
                Button("Not now") { coordinator.skipRelaunch() }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button("Quit & relaunch") { coordinator.confirmRelaunch() }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
                    .help("Quits \(appName) — unsaved work is lost — and opens your freshly built copy.")
            }
        }
    }

    // MARK: - Relaunching (packaging + terminate + launch)

    private var relaunchingCard: some View {
        card {
            header(icon: "arrow.triangle.2.circlepath", title: "Relaunching \(appName)")
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.62)
                    .frame(width: 13, height: 13)
                Text(coordinator.statusLine ?? "Building a runnable copy…")
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Force-quit consent (Consent #3b)

    private var forceQuitConsentCard: some View {
        card {
            header(icon: "exclamationmark.triangle", title: "\(appName) won't quit")

            Text(coordinator.forceQuitConsentPrompt)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Keep it running") { coordinator.skipForceQuitAndKeepRunningApp() }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button("Force quit") { coordinator.confirmForceQuitAndRelaunch() }
                    .irisTextButton(isDanger: true)
            }
        }
    }

    // MARK: - Committing

    private var committingCard: some View {
        card {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.62)
                    .frame(width: 13, height: 13)
                Text("Saving…")
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    // MARK: - Done

    @ViewBuilder
    private var doneCard: some View {
        if coordinator.previousVersionWasRestored {
            previousVersionRestoredCard
        } else if changeNeedsDeliveryFollowup {
            savedWithoutInstallationCard
        } else {
            normalDoneCard
        }
    }

    /// A restored receipt is a different outcome from the forward delivery
    /// summary. In particular, the old delivery progress still records that an
    /// edited package was once built and installed; rendering that state here
    /// would tell the reader to relaunch the very version Undo just replaced.
    /// Keep the recovery claims explicit and separate from behavior/document
    /// claims: Undo confirms app/source restoration only.
    private var previousVersionRestoredCard: some View {
        card {
            header(icon: "checkmark.circle", title: "Previous version restored")

            Text("The previous version of \(appName) is open again. Undo restored the app, not your documents.")
                .font(DS.Typography.body)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Technical details") {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    receiptRow("Source checkout", value: "Recorded base restored")
                    receiptRow("Base commit", value: "Restored")
                    receiptRow("Edit branch", value: "Kept as recovery history")
                    receiptRow("Behavior", value: "Not checked by Undo")
                }
                .padding(.top, DS.Spacing.xs)
            }
            .font(DS.Typography.caption)
            .foregroundColor(DS.Colors.textSecondary)
            .pointerCursor()

            HStack {
                Spacer(minLength: 0)
                Button("Done") { coordinator.cancel() }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
    }

    private var savedWithoutInstallationCard: some View {
        card {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                header(
                    icon: "exclamationmark.triangle",
                    title: coordinator.deliveryProgress.installedCopyReplaced
                        ? "Saved, but not running"
                        : "Saved, but not installed"
                )

                Text(coordinator.deliveryProgress.installedCopyReplaced
                     ? "The installed copy was replaced, but Iris did not confirm that the edited build is running."
                     : "Your installed \(appName) is still the previous version. The change is saved on a branch, but that copy was not replaced.")
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(coordinator.canRetrySavedDelivery
                     ? "Retry update rebuilds your saved change. It does not ask the model to edit it again."
                     : coordinator.deliveryProgress.installedCopyReplaced
                     ? "Next: relaunch \(appName) yourself to pick up the saved change, or use More to back up or share the branch."
                     : "Next: rebuild \(appName) with its own project tooling, or use More to back up or share the saved branch.")
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup(isExpanded: $savedWithoutInstallationDetailsAreExpanded) {
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        if let statusLine = coordinator.statusLine {
                            Text(statusLine)
                                .font(DS.Typography.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        verificationReceiptRows
                    }
                    .padding(.top, DS.Spacing.xs)
                } label: {
                    Label("Technical details", systemImage: "info.circle")
                        .font(DS.Typography.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .help("Shows the reported model route, branch status, and verification receipt.")
                .accessibilityHint("Expands to show the reported model route, branch status, and verification receipt.")
                .pointerCursor()
                .onChange(of: savedWithoutInstallationDetailsAreExpanded) { _, _ in
                    NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
                }

                pullRequestRow
                changelogRow

                if coordinator.isAwaitingPublishConsent {
                    publishConsentRow
                } else {
                    HStack(spacing: 8) {
                        if coordinator.canRetrySavedDelivery {
                            Button("Retry update") { coordinator.retrySavedDelivery() }
                                .irisTinyButton()
                                .help("Rebuilds and applies the exact saved source without another model edit.")
                        }
                        if coordinator.proposedDiffText != nil {
                            Button("Back up") { coordinator.requestForkBackup() }
                                .irisTinyButton()
                                .help("Pushes the saved branch to your own fork. Never to anyone else's repository.")

                            Menu {
                                if coordinator.classifiedKind == .feature {
                                    if coordinator.changelogState.allowsAnAttempt {
                                        Button("Add to publik changelog") {
                                            coordinator.recordFeatureChangelogToPublik()
                                        }
                                    }
                                } else if coordinator.pullRequestState.allowsAnAttempt {
                                    Button("Open a pull request") {
                                        coordinator.openPullRequestForTheKeptEdit(because: .readerTappedTheButton)
                                    }
                                }
                                Button("Share to publik") { coordinator.requestPublishToPublik() }
                            } label: {
                                Label("More", systemImage: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .font(DS.Typography.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .help("More ways to share the saved branch.")
                        }

                        if coordinator.deliveredChangeCanBeUndone {
                            Button("Undo") { coordinator.undoDeliveredChange() }
                                .irisTinyButton()
                                .help("Restores the previous app version and checks the result. Keeps the edit history for recovery.")
                        }
                        Spacer(minLength: 0)
                        Button("Done") { coordinator.cancel() }
                            .irisPrimaryPill(isFullWidth: false, isCompact: true)
                    }
                }
            }
        }
    }

    private var normalDoneCard: some View {
        card {
            header(icon: "doc.text", title: "Edit summary")

            verificationReceiptRows

            Text(coordinator.statusLine ?? "Your change is on a branch.")
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            pullRequestRow
            changelogRow

            // The PUBLIC publish confirm (D6): a separate, every-time consent,
            // never bundled with the fork backup. It only appears once the
            // reader taps "Share to publik", and it says plainly that this posts
            // to a public listing.
            if coordinator.isAwaitingPublishConsent {
                publishConsentRow
            } else {
                doneActionsRow
            }
        }
    }

    /// Where the pull request stands. Founder ruling, Sep 3 2026: once the edit
    /// works, Iris opens one on its own; this row is how the reader finds it —
    /// and how they learn what to set up when Iris could not.
    @ViewBuilder
    private var pullRequestRow: some View {
        switch coordinator.pullRequestState {
        case .notAttempted:
            EmptyView()
        case .opening:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Opening a pull request…")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        case .opened(let url):
            pullRequestLink(caption: "Pull request opened", url: url)
        case .alreadyOpen(let url):
            pullRequestLink(caption: "A pull request for this branch is already open", url: url)
        case .pushedButNoPullRequest(let detail):
            Text("Pushed the branch, but no pull request: \(detail)")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.amber)
                .fixedSize(horizontal: false, vertical: true)
        case .notSetUp(let reason), .failed(let reason):
            Text("Couldn't open a pull request: \(reason)")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pullRequestLink(caption: String, url: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 10, weight: .semibold))
            if let destination = URL(string: url) {
                Link("\(caption) ↗", destination: destination)
                    .font(.system(size: 11, weight: .medium))
                    .pointerCursor()
                    .help(url)
            } else {
                Text("\(caption): \(url)")
                    .font(.system(size: 11))
            }
        }
        .foregroundColor(DS.Colors.green)
    }

    /// Where the feature changelog stands. Founder ruling (Sep 3 2026): a
    /// working feature is changelogged to publik rather than PR'd.
    @ViewBuilder
    private var changelogRow: some View {
        switch coordinator.changelogState {
        case .notAttempted:
            EmptyView()
        case .pushing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Recording this change to publik's changelog…")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        case .pushed:
            HStack(spacing: 4) {
                Image(systemName: "text.badge.checkmark")
                    .font(.system(size: 10, weight: .semibold))
                Text("Added to publik's changelog")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(DS.Colors.green)
        case .notSetUp(let reason), .failed(let reason):
            Text("Couldn't record this change to publik: \(reason)")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The normal done actions: open the pull request when Iris did not on its
    /// own, back up to the reader's own fork (fork-only, low-stakes), optionally
    /// share to publik's public listing (which opens the separate consent
    /// above), and finish.
    private var doneActionsRow: some View {
        HStack(spacing: 8) {
            // Only offered when a change was actually kept (a discarded edit
            // leaves nothing to back up — `proposedDiffText` is cleared on
            // discard, kept on keep). Fork-only by construction in the
            // coordinator: never a push to a third party's main.
            if coordinator.proposedDiffText != nil {
                // A bug fix opens a PR; a feature is changelogged to publik. The
                // two are mutually exclusive per the founder ruling, so at most
                // one of these buttons ever shows.
                if coordinator.classifiedKind == .feature {
                    if coordinator.changelogState.allowsAnAttempt {
                        Button("Add to publik changelog") {
                            coordinator.recordFeatureChangelogToPublik()
                        }
                        .irisTinyButton()
                        .help("Records this change to publik's changelog and marks the request implemented. Never opens a pull request.")
                    }
                } else if coordinator.pullRequestState.allowsAnAttempt {
                    Button("Open a pull request") {
                        coordinator.openPullRequestForTheKeptEdit(because: .readerTappedTheButton)
                    }
                    .irisTinyButton()
                    .help("Pushes the branch and opens a pull request on the app's repo — never a merge.")
                }
                Button("Back up to my fork") { coordinator.requestForkBackup() }
                    .irisTinyButton()
                    .help("Pushes the branch to your own fork on GitHub. Never to anyone else's repo.")
                Button("Share to publik") { coordinator.requestPublishToPublik() }
                    .irisTinyButton()
                    .help("Posts to publik's public listing that this app got this change. A separate, public step — asked every time.")
            }
            if coordinator.deliveredChangeCanBeUndone {
                Button("Undo") { coordinator.undoDeliveredChange() }
                    .irisTinyButton()
                    .help("Restores the previous app version and checks the result. Keeps the edit history for recovery.")
            }
            Spacer(minLength: 0)
            if coordinator.offersRetryWithMemory {
                // "Still broken" → the next run opens with this attempt's
                // record marked as NOT having cured the complaint.
                Button("Try again with what Iris learned") { coordinator.retryAfterStillBroken() }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            } else {
                Button("Done") { coordinator.cancel() }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
    }

    /// The explicit every-time confirm for a public write. Distinct copy and a
    /// distinct pair of buttons so publishing to a public surface can never be a
    /// remembered or accidental tap.
    private var publishConsentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This posts to publik's public listing that \(appName) got this change — visible to everyone. Post it?")
                .font(.system(size: 10.5))
                .foregroundColor(DS.Colors.amber)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Cancel") { coordinator.cancelPublishToPublik() }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button("Post to publik") { coordinator.confirmPublishToPublik() }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
    }

    // MARK: - Terminal message (failed / not eligible)

    private func terminalMessageCard(reason: String, isRefusal: Bool) -> some View {
        // The missing-model-key refusal and a mid-run credential rejection are
        // the two terminal states a reader can clear in a tap, so they get a
        // key icon and a button straight into settings. Every other refusal or
        // failure (provenance, sandbox, no rebuild recipe, a genuinely failed
        // edit) stays a plain honest dead-end, because a settings tap would
        // not fix it. The coordinator decides — it sets the flag only for
        // those two cases.
        let offersModelKeySetup = coordinator.refusalOffersModelKeySetup
        let wasRateLimited = !isRefusal && coordinator.failureWasRateLimit
        // The dirty-clone refusal arrives through `.failed` — it is decided
        // inside the run, after the eligibility gate — but it is a REFUSAL, and
        // heading it "That didn't work" tells a reader something went wrong
        // when in fact Iris declined to start. It also carries the one terminal
        // state with a real way out, so it gets its own icon, title and action.
        // (An `if` chain rather than a fourth nested ternary: four of them
        // stacked is a puzzle, not a decision.)
        let dirtyCloneRefusal = coordinator.dirtyCloneRefusal
        let headerIcon: String
        let headerTitle: String
        if dirtyCloneRefusal != nil {
            headerIcon = "tray.full"
            headerTitle = "Your clone has changes Iris won't touch"
        } else if wasRateLimited {
            headerIcon = "clock.arrow.circlepath"
            headerTitle = "Rate-limited — try again shortly"
        } else if offersModelKeySetup {
            headerIcon = "key.fill"
            headerTitle = isRefusal
                ? "Connect a model to edit apps"
                : "Your model credential stopped working"
        } else {
            headerIcon = isRefusal ? "hand.raised" : "exclamationmark.triangle"
            headerTitle = isRefusal ? "Iris can't edit this" : "That didn't work"
        }
        return card {
            header(icon: headerIcon, title: headerTitle)

            // `.textSelection(.enabled)` on every reader-facing line here, and
            // on every one in the blocked card below, because the reader of
            // Test 7 hit exactly this card and said "i can't copy paste text on
            // that tab with the error" — the same complaint Test 4 already
            // made. A failure message you cannot copy cannot be pasted into a
            // search, a bug report, or a message to somebody who can help, so
            // the one moment a reader most needs the words is the one moment
            // they could not have them. Selection is HALF the answer — the
            // other half is the Copy button in the row below, because this card
            // lives in a panel that refuses key status and ⌘C is a key event.
            // See `OnDemandEditFailureText`.
            Text(reason)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !isRefusal, let verificationFailureDetail {
                DisclosureGroup(isExpanded: $verificationFailureDetailsAreExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Verification stage: \(verificationFailureDetail.stage)")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)

                        if let output = verificationFailureDetail.output {
                            Text(output)
                                .font(.system(size: 10.5))
                                .foregroundColor(DS.Colors.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("No additional verification output was captured.")
                                .font(.system(size: 10.5))
                                .foregroundColor(DS.Colors.textSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, DS.Spacing.xs)
                } label: {
                    Label("Why it stopped", systemImage: "info.circle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .help("Shows the scrubbed verification stage and bounded output recorded for this failed run.")
                .accessibilityHint("Expands to show scrubbed verification evidence from the failed run, not a new instruction.")
                .pointerCursor()
                .onChange(of: verificationFailureDetailsAreExpanded) { _, _ in
                    NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
                }
            }

            // A held failed edit has a non-destructive next step: give Iris a
            // fresh, reader-owned description and recheck the saved source. Put
            // it before the generic stash-and-retry action so the recovery path
            // is the first choice, while retaining set-aside for every other
            // dirty-clone case.
            savedChangeRecheckAction

            if dirtyCloneRefusal != nil {
                setAsideAndContinueAction
            }

            HStack(spacing: 8) {
                copyTheseWordsButton(
                    title: headerTitle,
                    lines: [reason]
                )
                Spacer(minLength: 0)
                Button("Done") { coordinator.cancel() }
                    .irisTextButton()
                if wasRateLimited {
                    Button("Try again") { coordinator.retryAfterRateLimit() }
                        .irisPrimaryPill(isFullWidth: false, isCompact: true)
                } else if offersModelKeySetup {
                    Button("Open settings") { openSettingsToConnectAModel() }
                        .irisPrimaryPill(isFullWidth: false, isCompact: true)
                }
            }
        }
    }

    /// The verification receipt carries only a scrubbed, bounded stage and
    /// output from a check that actually ran. Keep it collapsed by default so
    /// the failure card stays compact, and never turn a missing receipt into a
    /// guessed diagnosis.
    private var verificationFailureDetail: (stage: String, output: String?)? {
        coordinator.verificationReceipt?.readerFacingFailureDetail
    }

    /// The one tap out of the dirty-clone dead end.
    ///
    /// The caption is not decoration. The reader is being asked to let Iris
    /// write to their own repository over changes they may not recognise, so
    /// the card has to say where the work goes and how to get it back — "set
    /// aside" is only an honest phrase if `git stash pop` is on screen next to
    /// it. Nothing here runs on its own; the button is the whole consent.
    @ViewBuilder
    private var setAsideAndContinueAction: some View {
        if coordinator.isSettingAsideDirtyChanges {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.62)
                    .frame(width: 13, height: 13)
                Text("Setting them aside…")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .textSelection(.enabled)
            }
        } else {
            Button("Set aside and continue") {
                coordinator.setAsideDirtyChangesAndRetry()
            }
            .irisPrimaryPill(isFullWidth: true, isCompact: true)
            .padding(.top, 2)
            .disabled(coordinator.isPreparingSavedChangeRecheck)
            .help("Runs git stash in that clone, then retries your edit. Nothing is deleted.")

            Text("Sets the changes aside in git stash — nothing is deleted, and `git stash pop` in that clone puts them all back — then Iris retries your edit.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Opens Iris's settings panel — where a model is connected, by key or by CLI
    /// login — and clears this refusal, so the reader lands where the fix is
    /// rather than being told to go find it. `cancel()` returns the flow to the
    /// app picker, so re-tapping the edit chip after connecting a model re-runs
    /// eligibility cleanly.
    /// "Copy" — the words off this card, on the clipboard, in one tap.
    ///
    /// It is a BUTTON and not just selectable text for the reason spelled out
    /// on `OnDemandEditFailureText`: the bar's panel deliberately refuses key
    /// status once a question has been sent, and ⌘C is a key event. Selection
    /// still earns its place (a reader who has clicked back into the field has
    /// a key window, and partial copies want a drag) — this is the half that
    /// works when the window cannot take the keystroke at all.
    ///
    /// It confirms itself for a moment, because a copy that says nothing is
    /// indistinguishable from a button that did nothing — and this card's whole
    /// problem is a reader unable to tell what happened.
    @ViewBuilder
    private func copyTheseWordsButton(title: String, lines: [String]) -> some View {
        Button(justCopiedTheWords ? "Copied" : "Copy") {
            OnDemandEditFailureText.copyToTheClipboard(
                OnDemandEditFailureText.everythingOnTheCard(title: title, lines: lines)
            )
            justCopiedTheWords = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                justCopiedTheWords = false
            }
        }
        .irisTinyButton()
        .help("Copies this whole message to the clipboard.")
    }

    private func openSettingsToConnectAModel() {
        NotificationCenter.default.post(name: .clickyShowPanel, object: nil)
        coordinator.cancel()
    }

    // MARK: - Shared chrome

    @ViewBuilder
    private var modelRouteRow: some View {
        if let route = coordinator.currentModelRoute {
            Text(route)
                .font(DS.Typography.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var verificationReceiptRows: some View {
        if coordinator.deliveryProgress.codeSaved, coordinator.hasCommittedChange {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                modelRouteRow
                receiptRow("Code", value: "Saved on a branch")
                receiptRow("Build check", value: coordinator.verificationReceipt.map {
                    EditVerificationReceipt.label(for: $0.buildPassed)
                } ?? "Not reported")
                receiptRow("Tests", value: coordinator.verificationReceipt.map {
                    $0.testSummary
                } ?? "Not reported")
                receiptRow("App package", value: coordinator.deliveryProgress.freshAppBuilt ? "Built" : "Not built yet")
                receiptRow("Installed copy", value: coordinator.deliveryProgress.installedCopyReplaced ? "Replaced" : "Not replaced")
                receiptRow("Relaunch", value: coordinator.deliveryProgress.relaunched ? "Succeeded" : "Not completed")
                receiptRow("Behavior", value: coordinator.deliveryProgress.behavior)
            }
            .padding(DS.Spacing.md)
            .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.CornerRadius.medium))
        }
    }

    private func receiptRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
            Text(title).foregroundColor(DS.Colors.textSecondary)
            Spacer(minLength: DS.Spacing.sm)
            Text(value)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .font(DS.Typography.caption)
    }

    private func header(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.accent)
            // Selectable like the body beneath it: a reader copying a failure
            // out of this card almost always wants the heading with it, and a
            // selection that stops dead at the first line is the same "i can't
            // copy paste text on that tab" complaint in a smaller form.
            Text(title)
                .font(DS.Typography.heading)
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
        }
    }

    /// The glass card every phase wears, matching MaintainAskCard's placement in
    /// the bar. The shell is the read-over-anything surface because this floats
    /// over the reader's real desktop, which may be a bright window.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            content()
        }
        .padding(usesUnifiedPanel ? DS.Spacing.md : DS.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            IrisShellBackground(
                cornerRadius: DS.CornerRadius.large,
                surface: DS.Colors.readableOverAnything
            )
        )
        .padding(.horizontal, usesUnifiedPanel ? 0 : 12)
        .padding(.top, usesUnifiedPanel ? 0 : 10)
        .onAppear {
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
        .onDisappear {
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
    }
}

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

import SwiftUI

struct OnDemandEditCard: View {
    @ObservedObject var coordinator: OnDemandEditCoordinator

    /// A preselect for the kind picker, taken from the phrasing that opened the
    /// flow (a "fix a bug in…" chip preselects bug fix, "add a feature to…"
    /// preselects feature). It is only a starting point — the reader's explicit
    /// pick in the picker always wins. Defaulted so a preview still builds.
    var preselectedKind: OnDemandEditKind? = nil

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

    /// The reader's answer to the model's BLOCKED question, typed into the
    /// blocked card before "Answer and retry".
    @State private var blockedQuestionAnswerText: String = ""

    var body: some View {
        Group {
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
                previewCard
            case .committing:
                committingCard
            case .awaitingManifestConsent:
                manifestConsentCard
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
        // The bar this lives in re-measures its own height, but the settings
        // panel does not measure unless nudged — the same nudge MaintainAskCard
        // uses, so the card is never clipped as it changes phase.
        .onChange(of: coordinator.phase) { _, _ in
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
        // A brand-new pick starts from a clean field and the phrasing's
        // preselect — never the previous edit's leftovers.
        .onChange(of: coordinator.activeAppSlug) { _, _ in
            describeText = ""
            selectedKind = preselectedKind ?? .bugFix
            clarificationSelectionsByQuestionId = [:]
        }
        // The clarification batch is recomputed per request; whenever the set of
        // questions changes (a new batch, or the batch clearing as the flow
        // leaves `.clarifying`), drop any prior selections so an answer from one
        // batch can never carry into another.
        .onChange(of: coordinator.clarificationQuestions) { _, _ in
            clarificationSelectionsByQuestionId = [:]
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
        .animation(DS.Motion.contentIn, value: coordinator.phase)
    }

    private var appName: String { coordinator.activeAppName ?? "this app" }

    // MARK: - Describe

    private var describeCard: some View {
        card {
            header(icon: "wand.and.stars", title: "Edit \(appName)")

            Text("Tell Iris what to change. It edits your local source on a new branch, under your own model key — nothing is pushed or relaunched.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // The explicit fix/feature pick. It is a real choice, not a
            // convenience: it decides the honesty label and the commit trailer.
            HStack(spacing: 8) {
                kindPill(.bugFix, label: "Bug fix")
                kindPill(.feature, label: "Feature")
            }

            TextField("What should change?", text: $describeText, axis: .vertical)
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
            // wish echoed back).
            if !coordinator.suggestedRequests.isEmpty {
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
                Button("Continue") {
                    coordinator.describeRequest(describeText, kind: selectedKind)
                }
                .irisPrimaryPill(isFullWidth: false, isCompact: true)
                .disabled(
                    describeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || coordinator.isAssessingRequest
                )
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
            header(icon: "questionmark.circle", title: "A couple of questions")

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
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Cancel") { coordinator.cancel() }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button("Continue") {
                    coordinator.submitClarificationAnswers(clarificationSelectionsByQuestionId)
                }
                .irisPrimaryPill(isFullWidth: false, isCompact: true)
                // Only enabled once EVERY question has an answer — a half-answered
                // batch would leave the plan reasoning about a choice never made.
                .disabled(!everyClarificationQuestionIsAnswered)
            }
        }
    }

    /// True only when the reader has selected an option for every question in the
    /// current batch, so "Continue" cannot submit a partial set of answers.
    private var everyClarificationQuestionIsAnswered: Bool {
        coordinator.clarificationQuestions.allSatisfy { question in
            clarificationSelectionsByQuestionId[question.id] != nil
        }
    }

    /// One tappable answer to a clarification question, drawn as a wrapping
    /// full-width row with a radio mark. The selected one carries the accent so
    /// the current choice is unmistakable before the reader taps Continue.
    private func clarificationOptionRow(
        question: ClarificationQuestion, option: String
    ) -> some View {
        let isSelected = clarificationSelectionsByQuestionId[question.id] == option
        return Button(action: {
            clarificationSelectionsByQuestionId[question.id] = option
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
            header(icon: "list.bullet.rectangle", title: "Iris's plan")

            if let plan = coordinator.presentedPlan {
                Text(plan.approachSummary)
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                // The file estimate is a courtesy for the reader's judgment, not a
                // cage (the diff-scope gate is the hard cap downstream). Only shown
                // when the plan actually carries one — an empty estimate stays
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

                // The derived recipe in plain words — informed consent to what
                // will later run un-jailed during verification.
                planSection(title: "How Iris will build and check it") {
                    Text(plan.resolvedRecipeSummary)
                        .font(.system(size: 10.5))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Normally empty — the batch was already answered in `.clarifying`
                // — but rendered when present so a leftover open question is never
                // hidden behind the consent tap.
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

                // The §9 honesty rung it expects to reach, stated up front so the
                // reader knows the verification bar BEFORE approving the edit.
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.accent)
                    Text("Expected verification: \(plan.expectedRung)")
                        .font(.system(size: 10.5))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button("Cancel") { coordinator.cancel() }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button("Start editing") { coordinator.confirmPlanAndStart() }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
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
            header(icon: "wand.and.stars", title: "Edit \(appName)")

            Text(coordinator.statusLine ?? "Iris will edit the local source on a new branch, using your own model key. Continue?")
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Cancel") { coordinator.cancel() }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button("Start editing") { coordinator.confirmStartAndRun() }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
    }

    // MARK: - Running

    private var runningCard: some View {
        card {
            header(icon: "wand.and.stars", title: "Editing \(appName)")
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.62)
                    .frame(width: 13, height: 13)
                // The status line is live now — the coordinator updates it with
                // each real step the engine takes (the command being run, a
                // rate-limit wait, the verification build), so this card shows
                // what Iris is doing RIGHT NOW, not one frozen sentence.
                Text(coordinator.statusLine ?? "Working on it under your model key…")
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The reader can always stop a running edit. The stop lands at the
            // next safe boundary: Iris finishes the step in flight, reverts
            // everything it made, and ends with "nothing was changed" — so the
            // button flips to a disabled "Stopping…" the moment it's tapped.
            HStack(spacing: 8) {
                Button(coordinator.readerAskedToStopTheRun ? "Stopping…" : "Stop") {
                    coordinator.stopRunningEdit()
                }
                .irisTextButton(isDanger: true)
                .disabled(coordinator.readerAskedToStopTheRun)
                .help("Stops the edit at the next safe point and puts the app's source back exactly as it was.")
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Preview + apply (Consent #2)

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

    /// The earned §9 verification rung and its evidence-log lines, DERIVED from
    /// the engine's own result — never a self-rated confidence number. This first
    /// slice's result carries only the compile/build fact and the existing-suite
    /// outcome, so the ladder can honestly earn at most L2 (builds + existing
    /// tests green); the ladder's own "stop at the first missing signal" rule
    /// guarantees no rung is ever reported above the evidence actually collected.
    /// Nil unless the last result is an applied-and-rebuilt change, so this only
    /// surfaces where there is a real committed change to describe.
    private var earnedVerificationForLastResult: (rung: VerificationRung, evidenceLogLines: [String])? {
        guard case .appliedAndRebuilt(_, _, _, let suitePassed, _)? = coordinator.lastResult else {
            return nil
        }
        // "Applied and rebuilt" means the change compiled/built clean — L1 is
        // earned. The existing-suite result (green, red, or absent) decides
        // whether L2 is earned on top; nothing higher is derivable here.
        var collectedEvidence = VerificationEvidence()
        collectedEvidence.compileClean = true
        collectedEvidence.compileCleanEvidence = "the app built"
        switch suitePassed {
        case .some(true):
            collectedEvidence.existingSuiteGreen = true
            collectedEvidence.existingSuiteGreenEvidence = "existing tests stayed green"
        case .some(false):
            // Reachable only defensively — the engine blocks a red suite before
            // committing — but stated honestly rather than as "no evidence".
            collectedEvidence.existingSuiteGreenEvidence = "existing suite did not pass"
        case .none:
            collectedEvidence.existingSuiteGreenEvidence = "no test suite to run"
        }
        let earnedRung = FeatureEditVerificationLadder.highestEarnedRung(from: collectedEvidence)
        return (earnedRung, collectedEvidence.evidenceLogLines())
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

    // MARK: - Automatic delivery (rebuild + relaunch, no taps)

    private var deliveringCard: some View {
        card {
            header(icon: "arrow.triangle.2.circlepath", title: "Putting the fix into \(appName)")
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
            header(icon: "checkmark.circle", title: "Is it fixed?")

            if let complaint = coordinator.activeRequestText {
                Text("You said: “\(complaint)”")
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                if coordinator.symptomRecheckSummary == nil {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.62)
                        .frame(width: 13, height: 13)
                }
                Text(coordinator.symptomRecheckSummary ?? "\(appName) is running with the change — Iris is looking again…")
                    .font(.system(size: 10.5))
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

            HStack(spacing: 8) {
                Button("Undo this change") { coordinator.undoDeliveredChange() }
                    .irisTinyButton()
                    .help("Brings back the installed \(appName) and drops the branch — nothing of the change remains.")
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
                .fixedSize(horizontal: false, vertical: true)

            if let question = coordinator.blockedQuestionForUser {
                Text("Iris needs to know: \(question)")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.amber)
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

            HStack(spacing: 8) {
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

    private var doneCard: some View {
        card {
            header(icon: "checkmark.circle", title: "Done")

            Text(coordinator.statusLine ?? "Your change is on a branch.")
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

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

    /// The normal done actions: back up to the reader's own fork (fork-only,
    /// low-stakes), optionally share to publik's public listing (which opens the
    /// separate consent above), and finish.
    private var doneActionsRow: some View {
        HStack(spacing: 8) {
            // Only offered when a change was actually kept (a discarded edit
            // leaves nothing to back up — `proposedDiffText` is cleared on
            // discard, kept on keep). Fork-only by construction in the
            // coordinator: never a push to a third party's main.
            if coordinator.proposedDiffText != nil {
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
                    .help("Brings back the installed app and drops the branch.")
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
        return card {
            header(
                icon: wasRateLimited
                    ? "clock.arrow.circlepath"
                    : (offersModelKeySetup
                        ? "key.fill"
                        : (isRefusal ? "hand.raised" : "exclamationmark.triangle")),
                title: wasRateLimited
                    ? "Rate-limited — try again shortly"
                    : (offersModelKeySetup
                        ? (isRefusal ? "Connect a model to edit apps" : "Your model credential stopped working")
                        : (isRefusal ? "Iris can't edit this" : "That didn't work"))
            )

            Text(reason)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
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

    /// Opens Iris's settings panel — where a model is connected, by key or by CLI
    /// login — and clears this refusal, so the reader lands where the fix is
    /// rather than being told to go find it. `cancel()` returns the flow to the
    /// app picker, so re-tapping the edit chip after connecting a model re-runs
    /// eligibility cleanly.
    private func openSettingsToConnectAModel() {
        NotificationCenter.default.post(name: .clickyShowPanel, object: nil)
        coordinator.cancel()
    }

    // MARK: - Shared chrome

    private func header(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.accent)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
        }
    }

    /// The glass card every phase wears, matching MaintainAskCard's placement in
    /// the bar. The shell is the read-over-anything surface because this floats
    /// over the reader's real desktop, which may be a bright window.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            IrisShellBackground(
                cornerRadius: DS.CornerRadius.large,
                surface: DS.Colors.readableOverAnything
            )
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .onAppear {
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
        .onDisappear {
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
    }
}

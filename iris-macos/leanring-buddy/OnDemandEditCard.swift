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

    var body: some View {
        Group {
            switch coordinator.phase {
            case .pickApp:
                // Nothing is pending — the card contributes nothing to the bar.
                EmptyView()
            case .describe:
                describeCard
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

            HStack(spacing: 8) {
                Button("Cancel") { coordinator.cancel() }
                    .irisTextButton()
                Spacer(minLength: 0)
                Button("Continue") {
                    coordinator.describeRequest(describeText, kind: selectedKind)
                }
                .irisPrimaryPill(isFullWidth: false, isCompact: true)
                .disabled(describeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                Text(coordinator.statusLine ?? "Working on it under your model key…")
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        guard case .appliedAndRebuilt(_, _, let kind, let suitePassed)? = coordinator.lastResult else {
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
            Spacer(minLength: 0)
            Button("Done") { coordinator.cancel() }
                .irisPrimaryPill(isFullWidth: false, isCompact: true)
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
        card {
            header(
                icon: isRefusal ? "hand.raised" : "exclamationmark.triangle",
                title: isRefusal ? "Iris can't edit this" : "That didn't work"
            )

            Text(reason)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer(minLength: 0)
                Button("Done") { coordinator.cancel() }
                    .irisTextButton()
            }
        }
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

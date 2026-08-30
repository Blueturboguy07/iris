//
//  GuideAutopilotTerminalView.swift
//  leanring-buddy
//
//  The terminal Iris runs the install in, shown under the guide card while
//  autopilot is on. It renders `GuideAutopilotRunner`'s transcript — a list of
//  pure values — and, when a risky command is waiting, the confirm row.
//
//  It is dressed as a real macOS Terminal window on purpose: a title bar with
//  the three traffic lights, a solid dark body, a `%` prompt in front of every
//  command, and a block cursor that blinks while a command is actually running.
//  Iris can finish an install in a blink; a reader watching a blank flash does
//  not believe anything happened. So each command is typed out and its result
//  is held on screen for a moment (`GuideAutopilotPacing`) — the shell is never
//  slowed, only the way it is shown. A complex install then reads as a sequence
//  of deliberate steps rather than an instant that is hard to trust.
//
//  Three signals still set a fix apart from a guide command at a glance: an
//  amber prompt and rule (guide commands get the accent), a small "Iris's fix"
//  label above it, and an indent. Iris's own sentences render in the prose
//  font, never monospace, so the reader can always tell Iris from the machine.
//

import SwiftUI

// Generic over the presenter (`AutopilotTerminalPresenting`) rather than tied to
// the concrete `GuideAutopilotRunner`, so the exact same terminal — the traffic
// lights, the typed-out commands, the exit lines, the scroll-to-tail — renders a
// guide install AND a user-initiated on-demand edit (`OnDemandEditRunner`). The
// guide-shaped rows (`surfaceRow`, `confirmRow`) only ever appear on states the
// edit runner never enters, so nothing guide-specific leaks into an edit run.
//
// The Terminal.app palette + the auto-follow anchor live in this non-generic
// namespace rather than as `static let`s on the view: `GuideAutopilotTerminalView`
// is generic over its runner, and Swift forbids `static` STORED properties on a
// generic type ("static stored properties not supported in generic types").
private enum GuideAutopilotTerminalTheme {
    /// The auto-follow target: an invisible row after the last transcript
    /// entry, so "scroll to the end" survives rows changing height as the
    /// typewriter reveals them.
    static let transcriptBottomAnchor = "transcript-bottom-anchor"

    // The Terminal.app palette, so this reads as the app the reader already
    // trusts rather than as one more piece of Iris's chrome.
    static let windowBackground = Color(red: 0.086, green: 0.086, blue: 0.098)
    static let titleBarBackground = Color(red: 0.145, green: 0.145, blue: 0.161)
    static let trafficRed = Color(red: 1.0, green: 0.373, blue: 0.341)
    static let trafficYellow = Color(red: 0.996, green: 0.737, blue: 0.180)
    static let trafficGreen = Color(red: 0.157, green: 0.784, blue: 0.251)
    static let cursor = Color.white.opacity(0.82)
}

struct GuideAutopilotTerminalView<Runner: AutopilotTerminalPresenting>: View {
    @ObservedObject var runner: Runner
    let onApproveRiskyCommand: () -> Void
    let onSkipRiskyCommand: () -> Void
    /// The reader tapped "Try again" on a step Iris surfaced.
    let onRetrySurfacedStep: () -> Void
    /// The reader tapped "Continue" to move past a step Iris surfaced.
    let onContinuePastSurfacedStep: () -> Void
    /// The red traffic light — the escape hatch. It closes the takeover in
    /// every state, killing whatever is still running on the way out. Added
    /// after an install wedged on a hung `pnpm install` with no way out short
    /// of shutting the Mac down; made unconditional after a reader reported
    /// that it closed nothing at a manual gate ("you can't close out of it").
    let onEscapeHatch: () -> Void
    /// nil = the transcript area fills whatever its container gives it (the
    /// takeover window, a fixed frame). A value = that fixed height, for the
    /// under-the-card pane whose container grows to fit and would otherwise
    /// let a long install run past every clip with nothing scrollable.
    let fixedTranscriptHeight: CGFloat?

    @State private var escapeHatchIsHovered = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if let fixedTranscriptHeight {
                transcriptBody.frame(height: fixedTranscriptHeight)
            } else {
                transcriptBody
            }
        }
        .background(GuideAutopilotTerminalTheme.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Window chrome

    private var titleBar: some View {
        ZStack {
            HStack(spacing: 7) {
                escapeHatchTrafficLight
                Circle().fill(GuideAutopilotTerminalTheme.trafficYellow).frame(width: 11, height: 11)
                Circle().fill(GuideAutopilotTerminalTheme.trafficGreen).frame(width: 11, height: 11)
                Spacer(minLength: 0)
            }
            Text("iris — install")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Color.white.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(GuideAutopilotTerminalTheme.titleBarBackground)
    }

    /// The red traffic light is a real button, and shows the × on hover the
    /// way the genuine article does. The yellow and green stay decoration.
    private var escapeHatchTrafficLight: some View {
        Button(action: onEscapeHatch) {
            ZStack {
                Circle().fill(GuideAutopilotTerminalTheme.trafficRed).frame(width: 11, height: 11)
                Image(systemName: "xmark")
                    .font(.system(size: 6, weight: .heavy))
                    .foregroundColor(Color.black.opacity(0.55))
                    .opacity(escapeHatchIsHovered ? 1 : 0)
            }
            // A hit target a little bigger than the 11pt dot, so stopping a
            // runaway install is not a precision exercise.
            .frame(width: 15, height: 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in escapeHatchIsHovered = hovering }
        .pointerCursor()
        .nativeTooltip("Close — stops the install, keeps your place in the guide")
    }

    /// The transcript scrolls and follows its own tail. It used to be a plain
    /// stack in a fixed window, which is how an install longer than the window
    /// "froze": the shell kept working, the transcript kept growing, and every
    /// new row — exit lines, fixes, the Your-turn buttons — rendered below the
    /// clip where nothing could reach it.
    private var transcriptBody: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    // Index-based identity: the transcript is append-only, so a row's
                    // position is a stable id. (Value identity is not — two identical
                    // output lines would collide — and an unstable id would restart the
                    // typewriter on every redraw.)
                    ForEach(runner.transcript.indices, id: \.self) { index in
                        row(for: runner.transcript[index])
                    }

                    // A live prompt with a blinking cursor while the shell is busy — the
                    // signal that Iris is doing something right now, through the pacing
                    // hold as well as the real work.
                    if runner.isExecutingACommand {
                        runningCursorLine
                    }

                    // Iris could not finish this step; the reader takes it from here.
                    if case .surfacedToReader = runner.state {
                        surfaceRow
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(GuideAutopilotTerminalTheme.transcriptBottomAnchor)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            }
            .onChange(of: runner.transcript.count) {
                scrollProxy.scrollTo(GuideAutopilotTerminalTheme.transcriptBottomAnchor, anchor: .bottom)
            }
            .onChange(of: runner.state) {
                // The surface and confirm rows appear on state alone, and they
                // carry the buttons — they must never land out of view.
                scrollProxy.scrollTo(GuideAutopilotTerminalTheme.transcriptBottomAnchor, anchor: .bottom)
            }
            .onChange(of: runner.isExecutingACommand) {
                scrollProxy.scrollTo(GuideAutopilotTerminalTheme.transcriptBottomAnchor, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func row(for entry: GuideAutopilotTranscriptEntry) -> some View {
        switch entry {
        case .stepHeading(let title, let number, let total):
            Text("\(title.uppercased())  ·  \(number) of \(total)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.32))
                .padding(.top, 3)

        case .commandFromTheGuide(let text):
            commandRow(
                text, prompt: DS.Colors.accent, indented: false, label: nil, searchedTheWeb: false,
                friendlyLabel: GuideAutopilotFriendlyLabel.label(for: text)
            )

        case .commandFromAFix(let text, let attempt, let searchedTheWeb, let whatItDoes):
            commandRow(
                text, prompt: DS.Colors.amber, indented: true,
                label: "↻ Iris's fix · attempt \(attempt)", searchedTheWeb: searchedTheWeb,
                // A fix already carries the model's own plain-English "what it
                // does"; fall back to the command heuristic only if it is blank.
                friendlyLabel: whatItDoes.isEmpty ? GuideAutopilotFriendlyLabel.label(for: text) : whatItDoes
            )

        case .output(let line):
            Text(line.isEmpty ? " " : line)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.72))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .exitStatus(let code, let duration):
            HStack {
                Spacer(minLength: 0)
                Text("\(code == 0 ? "✓" : "✗")  \(code == 0 ? "done" : "exit \(code)")  ·  \(formatted(duration))")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(code == 0 ? DS.Colors.green : DS.Colors.red)
            }

        case .awaitingConfirmation(let request):
            confirmRow(request)

        case .explanation(let text):
            // Iris talking, in prose — not the machine.
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
        }
    }

    // MARK: - Command rows

    private func commandRow(
        _ text: String, prompt: Color, indented: Bool, label: String?, searchedTheWeb: Bool,
        friendlyLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.amber)
                    if searchedTheWeb {
                        Text("searched the web")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.4))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
            }
            // The plain-English line the reader actually reads — what this step
            // is doing, in words. The real command follows, de-emphasised, so
            // the terminal still reads as technical work rather than a toy.
            Text(friendlyLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top, spacing: 7) {
                Text("%")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(prompt)
                TypewriterCommandText(fullText: text)
            }
            .opacity(0.55)
        }
        .padding(.leading, indented ? 12 : 0)
    }

    private var runningCursorLine: some View {
        HStack(spacing: 7) {
            // A real spinner while the shell is busy — the clearest "Iris is
            // working right now" signal for a reader who does not read output.
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
                .tint(Color.white.opacity(0.75))
            Text("Working…")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Color.white.opacity(0.6))
            BlinkingBlockCursor(color: GuideAutopilotTerminalTheme.cursor)
            Spacer(minLength: 0)
        }
    }

    // MARK: - The reader's turn (a surfaced step)

    private var surfaceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.amber)
                Text("Your turn")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.amber)
            }
            // The specific diagnosis is already in the transcript above, as
            // Iris's own sentence. This is the standing offer to keep going.
            Text("Do this one step and Iris will carry on with the rest — or continue past it.")
                .font(.system(size: 10.5))
                .foregroundColor(Color.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button("Continue past it", action: onContinuePastSurfacedStep)
                    .irisTextButton()
                Spacer(minLength: 0)
                Button("Try again", action: onRetrySurfacedStep)
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.amber.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .strokeBorder(DS.Colors.amber.opacity(0.4), lineWidth: 1)
                )
        )
        .padding(.top, 2)
    }

    // MARK: - The confirm row (a risky command)

    private func confirmRow(_ request: GuideAutopilotApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            highlightedCommand(request.commandText, tripping: request.trippingSubstring)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.amber.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .strokeBorder(DS.Colors.amber.opacity(0.5), lineWidth: 1)
                        )
                )

            Text(request.reason)
                .font(.system(size: 10.5))
                .foregroundColor(Color.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Skip", action: onSkipRiskyCommand)
                    .irisTextButton()
                Button(request.isFromAFix ? "Run the fix" : "Run it", action: onApproveRiskyCommand)
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
    }

    /// The command with the tripping substring drawn in the caution colour, so
    /// the reader can see exactly what made Iris pause.
    private func highlightedCommand(_ command: String, tripping: String) -> Text {
        guard !tripping.isEmpty, let range = command.range(of: tripping) else {
            return Text(command).font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)
        }
        let before = String(command[command.startIndex..<range.lowerBound])
        let match = String(command[range])
        let after = String(command[range.upperBound...])
        let mono = Font.system(size: 11, design: .monospaced)
        return Text(before).font(mono).foregroundColor(DS.Colors.textPrimary)
            + Text(match).font(mono.weight(.bold)).foregroundColor(DS.Colors.amber)
            + Text(after).font(mono).foregroundColor(DS.Colors.textPrimary)
    }

    private func formatted(_ duration: TimeInterval) -> String {
        duration < 1 ? String(format: "%.0fms", duration * 1000)
            : String(format: "%.1fs", duration)
    }
}

// MARK: - Typewriter + cursor

/// Reveals a command one character at a time, the way it looks when someone
/// types it into a real Terminal. Purely cosmetic: the command has already run
/// by the time this animates, and if the animation is ever cancelled the full
/// text snaps in, so nothing depends on it completing.
private struct TypewriterCommandText: View {
    let fullText: String
    @State private var revealedCharacterCount: Int = 0

    var body: some View {
        Text(String(fullText.prefix(revealedCharacterCount)))
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(DS.Colors.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: fullText) {
                revealedCharacterCount = 0
                let totalCharacters = fullText.count
                guard totalCharacters > 0 else { return }
                // Cap the number of sleeps so a very long command still finishes
                // in well under a second: reveal in at most ~64 chunks.
                let maximumSteps = 64
                let charactersPerStep = max(1, totalCharacters / maximumSteps)
                var shown = 0
                while shown < totalCharacters {
                    shown = min(totalCharacters, shown + charactersPerStep)
                    revealedCharacterCount = shown
                    do {
                        try await Task.sleep(nanoseconds: 15_000_000) // ~15ms/chunk
                    } catch {
                        revealedCharacterCount = totalCharacters
                        return
                    }
                }
                revealedCharacterCount = totalCharacters
            }
    }
}

/// A block cursor that blinks at roughly the macOS Terminal rate.
private struct BlinkingBlockCursor: View {
    let color: Color
    @State private var isVisible: Bool = true

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 7, height: 13)
            .opacity(isVisible ? 1 : 0)
            .task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 530_000_000)
                    } catch {
                        return
                    }
                    isVisible.toggle()
                }
            }
    }
}

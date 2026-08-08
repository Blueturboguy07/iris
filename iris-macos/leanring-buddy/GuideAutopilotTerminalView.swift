//
//  GuideAutopilotTerminalView.swift
//  leanring-buddy
//
//  The terminal Iris runs the install in, shown under the guide card while
//  autopilot is on. It renders `GuideAutopilotRunner`'s transcript — a list of
//  pure values — and, when a risky command is waiting, the confirm row.
//
//  Three signals set a fix apart from a guide command at a glance: an amber
//  left rule (guide commands get the accent rule), a small "Iris's fix" label
//  above it, and an indent. On a small translucent card one signal is not
//  enough. Iris's own sentences render in the prose font, never monospace, so
//  the reader can always tell Iris apart from the machine.
//

import SwiftUI

struct GuideAutopilotTerminalView: View {
    @ObservedObject var runner: GuideAutopilotRunner
    let onApproveRiskyCommand: () -> Void
    let onSkipRiskyCommand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(runner.transcript) { entry in
                row(for: entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(Color.black.opacity(0.34))
        )
    }

    @ViewBuilder
    private func row(for entry: GuideAutopilotTranscriptEntry) -> some View {
        switch entry {
        case .stepHeading(let title, let number, let total):
            Text("\(title.uppercased())  ·  \(number) of \(total)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.top, 2)

        case .commandFromTheGuide(let text):
            commandRow(text, rule: DS.Colors.accent, indented: false, label: nil, searchedTheWeb: false)

        case .commandFromAFix(let text, let attempt, let searchedTheWeb, _):
            commandRow(
                text, rule: DS.Colors.amber, indented: true,
                label: "↻ Iris's fix · attempt \(attempt)", searchedTheWeb: searchedTheWeb
            )

        case .output(let line):
            Text(line)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary.opacity(0.85))
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
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
        }
    }

    private func commandRow(
        _ text: String, rule: Color, indented: Bool, label: String?, searchedTheWeb: Bool
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
                            .foregroundColor(DS.Colors.textTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
            }
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(rule)
                    .frame(width: 2)
                Text(text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, indented ? 10 : 0)
    }

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
                .foregroundColor(DS.Colors.textSecondary)
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

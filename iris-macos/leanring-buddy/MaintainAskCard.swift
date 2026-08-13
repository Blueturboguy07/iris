//
//  MaintainAskCard.swift
//  leanring-buddy
//
//  Maintain mode's entire visible surface: one card, one sentence of
//  evidence, three answers. It renders nothing when there is nothing to ask
//  — which is almost always, by design. The rate limits live in the
//  coordinator; this file only draws what survived them.
//
//  The three answers are deliberate and none is a dismissal-x: "that was me"
//  is a labeled negative the pool learns from, and "don't ask about this
//  app" is a real, permanent setting — not a snooze. A question a user
//  cannot decisively end is a nag.
//

import SwiftUI

struct MaintainAskCard: View {
    @ObservedObject var coordinator: MaintainIncidentCoordinator

    var body: some View {
        pendingAskCard
        fixStatusCard
    }

    /// After a "yes": what the fix attempt is doing, did, or couldn't do —
    /// plus the guidance steps when the known fix is instructions.
    @ViewBuilder
    private var fixStatusCard: some View {
        if coordinator.pendingAsk == nil, let statusLine = coordinator.fixStatusLine {
            VStack(alignment: .leading, spacing: 8) {
                Text(statusLine)
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !coordinator.fixGuidanceSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(coordinator.fixGuidanceSteps.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)")
                                .font(.system(size: 10.5))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack {
                    Spacer(minLength: 0)
                    Button("Done") { coordinator.clearFixStatus() }
                        .irisTextButton()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
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

    @ViewBuilder
    private var pendingAskCard: some View {
        if let ask = coordinator.pendingAsk {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "bandage.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.amber)
                    Text("Something wrong with \(ask.appName)?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                }

                Text(ask.evidenceSentence)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // A cache hit means someone else already fixed this exact
                // break — say so before the user even answers, because "a
                // fix exists" changes what "yes" means.
                if !coordinator.recipesForPendingAsk.isEmpty {
                    Text("A known fix exists for this.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.green)
                }

                HStack(spacing: 8) {
                    Button("Yes, something's broken") {
                        coordinator.answerPendingAsk(.somethingIsBroken)
                    }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)

                    Button("No, that was me") {
                        coordinator.answerPendingAsk(.thatWasMe)
                    }
                    .irisTextButton()

                    Spacer(minLength: 0)

                    Button("Don't ask") {
                        coordinator.answerPendingAsk(.neverAskAboutThisApp)
                    }
                    .irisTextButton()
                    .nativeTooltip("Never ask about \(ask.appName) again — reversible in settings.")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.amber.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .strokeBorder(DS.Colors.amber.opacity(0.35), lineWidth: 1)
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
}

//
//  PublikAPINudgeCard.swift
//  leanring-buddy
//
//  The inline card `PublikAPINudgeCoordinator` puts up — in the settings
//  panel for a provider or model pick, and in the eye's bar for the first
//  question in an app or a measured cost. Not a modal, not in front of
//  anything: it sits in the flow of the panel it is in, the question the
//  reader asked goes out regardless, and "Not now" quiets every nudge for 7
//  days (`PublikAPINudgePolicy.quietPeriodAfterDismissal`).
//

import SwiftUI

struct PublikAPINudgeCard: View {
    let nudge: PublikAPINudge
    /// The one action. In the settings panel that is switching to publik API;
    /// in the eye's bar it opens the comparison in settings.
    let primaryActionTitle: String
    let onPrimaryAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(nudge.headline)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(nudge.detail)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(primaryActionTitle, action: onPrimaryAction)
                    .irisTinyButton()
                Button("Not now", action: onDismiss)
                    .irisTextButton(fontSize: 10)
                    .help("Hides suggestions like this for 7 days.")
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(DS.Colors.line, lineWidth: 1)
        )
    }
}

/// Where the eye's bar shows the nudge. Its own view so the bar observes the
/// coordinator without growing another stored property. It shows all three
/// decision points: (b) and (c) happen here, and (a) can too — the bar has its
/// own model picker, and a nudge raised by a pick made there must land where
/// the reader is looking, not in a settings panel that may be closed.
struct EyeBarPublikAPINudgeSlot: View {
    @ObservedObject var nudgeCoordinator: PublikAPINudgeCoordinator

    init(companionManager: CompanionManager) {
        _nudgeCoordinator = ObservedObject(wrappedValue: companionManager.publikAPINudgeCoordinator)
    }

    var body: some View {
        if let nudge = nudgeCoordinator.visibleNudge {
            PublikAPINudgeCard(
                nudge: nudge,
                primaryActionTitle: "Compare",
                onPrimaryAction: {
                    nudgeCoordinator.readerActedOnTheNudge()
                    Self.openTheComparisonInSettings()
                },
                onDismiss: { nudgeCoordinator.dismiss() }
            )
        }
    }

    /// The comparison lives under "How Iris answers" on the Connections page.
    static func openTheComparisonInSettings() {
        UserDefaults.standard.set(SettingsPanelRouting.Page.connections.rawValue, forKey: "irisSettingsSection")
        NotificationCenter.default.post(name: .clickyShowPanel, object: nil)
    }
}

//
//  UsageSharingControls.swift
//  leanring-buddy
//
//  The two places the anonymous usage switch lives: the first-open card at
//  the top of the settings panel, and the row in General settings. Both drive
//  `UsageSharingController`, which writes consent.json and tells the monitor.
//
//  The card is ordinary content in the panel's scroll, like the setup helper
//  — never a modal, never in front of anything the reader is doing. Its
//  switch starts ON (founder: "default toggled on"); counting starts once the
//  card has been on screen, and it stays at the top of settings until the
//  reader presses Continue or Turn off.
//

import Combine
import SwiftUI

/// The switch's state for SwiftUI, and the one place a change to it is made.
@MainActor
final class UsageSharingController: ObservableObject {

    /// The disclosure the card shows. Kept word for word from the founder's
    /// brief; the privacy policy's "Anonymous usage counts" item says the
    /// same thing at length.
    static let disclosureSentence =
        "Iris shares anonymous usage counts (which catalog apps you open and which AI tier you pick) to improve recommendations. No content, no identity."

    @Published private(set) var sharingState: UsageSharingState
    @Published private(set) var readerHasAnsweredTheDisclosure: Bool

    private let consentStore: PublikConsentStore
    private let usageMonitor: UsageMonitor

    init(consentStore: PublikConsentStore, usageMonitor: UsageMonitor) {
        self.consentStore = consentStore
        self.usageMonitor = usageMonitor
        self.sharingState = consentStore.usageSharingState
        self.readerHasAnsweredTheDisclosure = consentStore.readerHasAnsweredTheUsageDisclosure
    }

    var isSharing: Bool { sharingState == .sharing }

    /// Whether the first-open card belongs on screen.
    var shouldShowTheDisclosureCard: Bool { !readerHasAnsweredTheDisclosure }

    /// Whether Iris should open its settings panel at launch so the card is
    /// seen at first open. Only until it has been shown once.
    var disclosureHasNeverBeenShown: Bool { !consentStore.usageDisclosureHasBeenShown }

    /// The card is on screen: from now on the default (ON) is in force.
    func disclosureCardAppeared() {
        consentStore.recordThatTheUsageDisclosureWasShown()
        refresh()
    }

    /// Continue, with the card's switch as the reader left it.
    func readerPressedContinue(withSharingOn sharingOn: Bool) {
        setSharing(sharingOn)
    }

    func readerPressedTurnOff() {
        setSharing(false)
    }

    /// The settings row, or either button above.
    func setSharing(_ sharingOn: Bool) {
        let wasSharing = consentStore.isUsageSharingOn
        consentStore.recordUsageSharingChoice(isOn: sharingOn)
        if wasSharing && !sharingOn {
            usageMonitor.sharingWasTurnedOff()
        }
        refresh()
    }

    private func refresh() {
        sharingState = consentStore.usageSharingState
        readerHasAnsweredTheDisclosure = consentStore.readerHasAnsweredTheUsageDisclosure
    }
}

/// The first-open card.
struct UsageSharingDisclosureCard: View {
    @ObservedObject var controller: UsageSharingController
    /// The card's own switch. Starts ON; the reader's last word is what
    /// Continue records.
    @State private var switchIsOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.accent)
                Text("Anonymous usage counts")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.ink)
            }

            Text(UsageSharingController.disclosureSentence)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $switchIsOn) {
                Text("Share anonymous usage counts")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .pointerCursor()

            HStack(spacing: 8) {
                Button("Continue") {
                    controller.readerPressedContinue(withSharingOn: switchIsOn)
                }
                .irisTinyButton()

                Button("Turn off") {
                    switchIsOn = false
                    controller.readerPressedTurnOff()
                }
                .irisTextButton(fontSize: 10)

                Spacer()

                Button("What is sent") {
                    _ = ExternalLinkPolicy.openExternalURLIfAllowed("https://publikhq.com/privacy#iris")
                }
                .irisTextButton(fontSize: 10)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(DS.Colors.line, lineWidth: 1)
        )
        .onAppear {
            controller.disclosureCardAppeared()
        }
    }
}

/// The switch in General settings.
struct UsageSharingSettingsRow: View {
    @ObservedObject var controller: UsageSharingController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { controller.isSharing },
                set: { controller.setSharing($0) }
            )) {
                Text("Anonymous usage counts")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.muted)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .pointerCursor()

            Text(controller.isSharing
                 ? "On. Which catalog apps you open and which AI tier you pick, counted by the hour. No content, no identity. Turning it off also deletes what was sent."
                 : "Off. Iris counts nothing.")
                .font(.system(size: 9))
                .foregroundColor(DS.Colors.muted.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

extension AssistantProviderPreference {
    /// The same choice in the usage monitor's vocabulary. Raw values match.
    var usageProvider: UsageProvider {
        switch self {
        case .publikAPI: return .publikAPI
        case .anthropicKey: return .anthropicKey
        case .codex: return .codex
        }
    }
}

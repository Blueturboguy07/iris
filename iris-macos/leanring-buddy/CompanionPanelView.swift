//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel: Iris's settings.
//  Permissions, the model picker, the guide, the installed publik apps, the
//  account rows and quit. Designed to feel like Loom's recording panel — dark,
//  rounded, minimal, and special.
//
//  THIS IS NOT WHERE YOU TALK TO IRIS. Asking a question and reading the answer
//  both happen in the bar under the eye (`OverlayEyeInputBar.swift`). This panel
//  used to carry a second copy of that conversation — its own "Ask Iris" field
//  and its own response area — which meant one exchange spread over two windows
//  and a bar at the eye that threw the reader in here the moment they used it.
//  The exchange belongs at the eye; the settings belong here; the gear beside
//  the bar is the way from one to the other.
//

import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    /// Observed separately from the companion manager so the account rows
    /// redraw the instant a sign-in finishes, rather than on the next thing
    /// that happens to change assistant state.
    @ObservedObject var accountService: AccountService
    /// Observed separately for the same reason as the account service: the panel
    /// has to redraw the moment a guide arrives over an `iris://` link, which
    /// happens without the assistant state changing at all.
    @ObservedObject var guideSessionController: GuideSessionController
    /// Observed separately for the same reason again: the inventory finishes
    /// scanning on its own schedule, and the app list has to appear when it
    /// does rather than on the next unrelated state change.
    @ObservedObject var appInventoryService: AppInventoryService

    /// Where the pointer is inside the panel, so the eye can glance toward it.
    /// Zero (looking straight ahead) whenever the pointer is elsewhere.
    @State private var eyeLook: CGSize = .zero

    /// Mirrors the persisted "Let Iris take control" grant so the settings row
    /// re-renders when the reader toggles it here. Seeded from the real grant
    /// when the panel appears; the row's button is the revoke the consent alert
    /// promises exists.
    @State private var autopilotAutonomyGranted = AutopilotAutonomyGrant.shared.isGranted

    /// The BYO key while the user is typing it. Cleared the moment it is saved
    /// and never repopulated — a saved key is never echoed back into the UI.
    @State private var anthropicAPIKeyInput: String = ""
    @State private var isShowingEmailAndPasswordSignIn: Bool = false
    @State private var emailAddressInput: String = ""
    @State private var passwordInput: String = ""

    /// The interactive `claude setup-token` capture, shown in a sheet. Its own
    /// object so its published phase drives the sheet without the panel owning
    /// any of the pty details.
    @StateObject private var claudeCodeSetupSession = ClaudeCodeSetupTokenSession()
    /// Whether the inline `claude setup-token` terminal is showing.
    @State private var isShowingClaudeCodeSetup = false
    /// What the reader types into the inline setup terminal, forwarded to the CLI.
    @State private var claudeCodeSetupInput: String = ""
    /// The one-line result of the last "Import from Claude Code" attempt.
    @State private var claudeCodeImportMessage: String?

    /// The interactive `codex login` session — the OpenAI-side sibling of the
    /// Claude one above. Same pty machinery, different success oracle (the CLI's
    /// credential file rather than a token scraped from the output).
    @StateObject private var codexSignInSession = CodexCLISignInSession()
    /// Whether the inline `codex login` terminal is showing.
    @State private var isShowingCodexSignIn = false
    /// What the reader types into the inline Codex terminal.
    @State private var codexSignInInput: String = ""

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _accountService = ObservedObject(wrappedValue: companionManager.accountService)
        _guideSessionController = ObservedObject(wrappedValue: companionManager.guideSessionController)
        _appInventoryService = ObservedObject(wrappedValue: companionManager.appInventoryService)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.line)

            // The maintain-mode ask used to render here, in the settings
            // dropdown. It moved to the eye's bar (OverlayEyeInputBar) — the
            // eye is the interface, and a crash ask has to surface itself
            // where the reader is looking, not wait to be found in settings.

            // The guide used to take over this panel. It does not any more: a
            // step card in a menu bar dropdown makes the reader look away from
            // the thing they are being told to do, which is the one thing the
            // desktop app should be better at than the web page. The guide now
            // renders under the eye — `OverlayEyeGuideCard` — where the eye can
            // also fly to the control the step is about.
            //
            // This panel is settings. That is what `iris-macos/CLAUDE.md` has
            // always said it is.
            // Scrolls, with the header and footer pinned either side of it.
            //
            // This body was laid out straight into the panel with no scroll
            // view, so once the account, keys, permissions, apps and install
            // sections together grew taller than the dropdown, everything past
            // the bottom edge was simply unreachable — no scrollbar, no
            // indication anything was there. A reader reported it as the
            // settings being cut off, which is exactly what it was. The Quit
            // button lives in the footer, so that at least stayed reachable.
            ScrollView(.vertical) {
                Group {
                    settingsAndAccountContent
                        .transition(DS.Motion.contentTransition)
                }
                .animation(DS.Motion.contentIn, value: guideSessionController.loadState.isShowingSomethingAboutAGuide)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
            // A ScrollView needs a bound or it grows to fit its content and
            // scrolls nothing. This caps the panel below the shortest laptop
            // display's usable height.
            .frame(maxHeight: 520)

            Divider()
                .background(DS.Colors.line)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 320)
        .background(panelBackground)
        // The eye follows the pointer around the panel, the way the pill's
        // `--look-x/--look-y` did. Straight ahead when the pointer leaves.
        .onContinuousHover { hoverPhase in
            switch hoverPhase {
            case .active(let pointerLocation):
                let eyeCenter = CGPoint(x: 26.5, y: 22)
                let deltaX = pointerLocation.x - eyeCenter.x
                let deltaY = pointerLocation.y - eyeCenter.y
                let distance = max(1, (deltaX * deltaX + deltaY * deltaY).squareRoot())
                eyeLook = CGSize(width: deltaX / distance * 2, height: deltaY / distance * 2)
            case .ended:
                eyeLook = .zero
            }
        }
        // The floating panel measures its content only when it is shown, so
        // swapping the chat view for a guide — or moving between steps of
        // different lengths — has to ask for a re-fit, or the new content
        // renders inside a panel still shaped for the old content.
        .onChange(of: guideSessionController.loadState) { _, _ in
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
        .onChange(of: guideSessionController.currentStepIndex) { _, _ in
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
        // The inventory finishes scanning after the panel has already been
        // measured, so the rows it adds need the same re-fit a guide does.
        .onChange(of: appInventoryService.installedEntriesForDisplay.count) { _, _ in
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
    }

    /// Everything the panel shows when no guide is open: the model picker, the
    /// account rows, the installed apps and the permissions flow. No chat box —
    /// see the note at the top of this file.
    @ViewBuilder
    private var settingsAndAccountContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                modelPickerRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 10)

                autopilotAutonomyRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 14)

                GuideSlugEntryView(guideSessionController: guideSessionController)
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 14)

                AppInventorySectionView(
                    appInventoryService: appInventoryService,
                    appLinkService: companionManager.appLinkService,
                    onEditApp: { installedEntry in
                        companionManager.requestOnDemandEdit(forEntry: installedEntry)
                    }
                )
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 14)

                accountSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Header

    /// The 44pt titlebar from the pill: the eye, the wordmark, a quiet
    /// "· status" the way the pill writes its step counter, and one icon button.
    private var panelHeader: some View {
        HStack(spacing: 8) {
            IrisEyeView(mood: eyeMood, look: eyeLook, progress: eyeProgressRing)

            Text("Iris")
                .font(.system(size: 12, weight: .bold))
                .tracking(-0.2)
                .foregroundColor(DS.Colors.ink)

            Text("·")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.quiet)
            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.quiet)
                .lineLimit(1)

            Spacer()

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
            }
            .irisIconButton(size: 26)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 44)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Press Control+Option anytime to open Iris.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Iris.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all three below to keep using Iris.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Iris.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A companion that lives in your menu bar and helps you learn stuff as you use your computer.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. Iris only takes a screenshot when you ask it a question, so you can grant these permissions in peace.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Button(action: {
                companionManager.triggerOnboarding()
            }) {
                Text("Start")
            }
            .irisPrimaryPill()
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(DS.Colors.quiet)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                    }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                    }
                    .irisTinyButton()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        // Once the user has been sent to System Settings, this row can no
        // longer tell whether they granted it — macOS answers the permission
        // check once per launch. Rather than leave them toggling a switch and
        // watching nothing happen, offer the restart that actually applies it.
        let awaitingRestart = !isGranted
            && WindowPositionManager.hasRequestedScreenRecordingDuringCurrentLaunch
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you ask a question"
                         : awaitingRestart
                            ? "Granted it? macOS applies this on restart"
                            : "Only takes a screenshot when you ask a question")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if awaitingRestart {
                        WindowPositionManager.relaunchToApplyPermissions()
                    } else {
                        // Triggers the native macOS screen recording prompt on first
                        // attempt (auto-adds app to the list), then opens System Settings
                        // on subsequent attempts.
                        WindowPositionManager.requestScreenRecordingPermission()
                    }
                }) {
                    Text(awaitingRestart ? "Restart Iris" : "Grant")
                }
                .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                }
                .irisPrimaryPill(isFullWidth: false, isCompact: true)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Model Picker

    /// The `.platform-switch` control from the pill: a soft trough holding
    /// equal-width segments, the chosen one lit with a white overlay.
    /// The revoke for the one-time "Let Iris take control of your Mac?" grant.
    /// Mirrors `modelPickerRow`'s shape. Turning it on here is the same grant
    /// the install alert sets; turning it off makes the next install ask again.
    private var autopilotAutonomyRow: some View {
        // Two named buttons, not one button labelled with its own state.
        //
        // It used to be a single control reading "On" or "Off", which is the
        // classic ambiguity: does "On" mean it IS on, or that tapping turns it
        // on? At 9pt with only a faint background difference between the two
        // states there was nothing to disambiguate it, and a reader reported
        // exactly that. Each mode is now its own button, named for what it
        // does rather than for the state it is in, and the selected one is
        // filled — so what is true and what tapping would do are different
        // things on screen.
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Installs")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.muted)
                Text(autopilotAutonomyGranted
                     ? "Iris runs installs itself. It never runs anything that could erase your disk."
                     : "Iris asks before each step it wants to run.")
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.muted.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Only offered once there is something to undo — a "reset" for a
            // panel nobody has moved is a control that does nothing.
            if MenuBarPanelPlacement.shared.readerHasPlacedItThemselves {
                Button("Put this panel back under the menu bar") {
                    MenuBarPanelPlacement.shared.forget()
                    NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9))
                .foregroundColor(DS.Colors.muted.opacity(0.8))
            }

            HStack(spacing: 6) {
                autonomyModeButton(
                    title: "Ask me each step",
                    isSelected: !autopilotAutonomyGranted,
                    action: {
                        AutopilotAutonomyGrant.shared.revoke()
                        autopilotAutonomyGranted = false
                    }
                )
                autonomyModeButton(
                    title: "Run installs for me",
                    isSelected: autopilotAutonomyGranted,
                    action: {
                        AutopilotAutonomyGrant.shared.grant()
                        autopilotAutonomyGranted = true
                    }
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func autonomyModeButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? DS.Colors.ink : DS.Colors.muted)
                .padding(.horizontal, 10)
                .frame(minHeight: 24)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isSelected ? Color.white.opacity(0.22) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(title)
    }

    /// Reported twice now, in the same words both times: "it says connected to
    /// Codex, but in models I can only choose Sonnet or Opus." The reading is
    /// correct and the UI earned it — a row labelled just "Model", sitting
    /// under "Connected via Codex", says that Codex ought to be one of these.
    /// It cannot be: Codex serves EDITING and Anthropic serves CHAT, and these
    /// two buttons have only ever been the chat model. 0.5.0 hid this toggle
    /// while an app was open, which fixed the composer and left the settings
    /// panel — where the "Connected via Codex" line actually lives — saying the
    /// same confusing thing. Naming the row and stating who serves the other
    /// half is the fix.
    private var modelPickerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Chat model")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.muted)

                Spacer()

                HStack(spacing: 3) {
                    modelOptionButton(label: "Sonnet", modelID: "claude-sonnet-4-6")
                    modelOptionButton(label: "Opus", modelID: "claude-opus-4-6")
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
            }
            Text(whoServesWhichHalf)
                .font(.system(size: 9.5))
                .foregroundColor(DS.Colors.quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    /// One sentence saying which provider answers questions and which one edits
    /// apps, because they are genuinely different and can be connected at once.
    private var whoServesWhichHalf: String {
        let editProvider = MaintainModelProviderResolver.firstAvailable()?.displayName
        guard let editProvider else {
            return "Answers only. No provider is connected for editing apps yet."
        }
        return "Answers only — editing apps runs on \(editProvider)."
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.ink : DS.Colors.muted)
                .padding(.horizontal, 10)
                .frame(minHeight: 22)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Account

    /// Sign-in, sign-out, and the bring-your-own-key field.
    ///
    /// The shape of this section is the whole assistant-funding model made
    /// visible: signed in, Iris pays for the model; signed out with a key
    /// stored, the user does; neither, and the assistant cannot answer at all —
    /// which is stated here rather than being discovered as an error message
    /// after typing a question.
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACCOUNT")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(DS.Colors.quiet)
                .frame(maxWidth: .infinity, alignment: .leading)

            if accountService.signedInAccount != nil {
                signedInAccountRow
            } else {
                signedOutAccountRows
            }
        }
    }

    // MARK: Signed in

    @ViewBuilder
    private var signedInAccountRow: some View {
        if let signedInAccount = accountService.signedInAccount {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)

                    Text(signedInAccount.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button(action: {
                        accountService.signOut()
                    }) {
                        Text("Sign out")
                    }
                    .irisTinyButton()
                }

                Text("Answers are on publik while you're signed in.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                    .background(DS.Colors.borderSubtle)

                // Chat is funded while signed in, but editing an app runs on the
                // reader's OWN model — so the credential options must be reachable
                // here too, not only when signed out. This is where the on-demand
                // edit refusal's "Open settings" button lands a signed-in reader.
                Text("To edit apps, connect your own model")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                bringYourOwnCredentialSection
            }
        }
    }

    // MARK: Signed out

    private var signedOutAccountRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                signInProviderButton(provider: .google)
                signInProviderButton(provider: .github)
            }

            Button(action: {
                isShowingEmailAndPasswordSignIn.toggle()
            }) {
                Text(isShowingEmailAndPasswordSignIn
                     ? "Use a provider instead"
                     : "Sign in with an email and password")
            }
            .irisTextButton(fontSize: 10)

            if isShowingEmailAndPasswordSignIn {
                emailAndPasswordSignInFields
            }

            if let signInFailureMessage = accountService.signInFailureMessage {
                Text(signInFailureMessage)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            bringYourOwnCredentialSection
        }
    }

    private func signInProviderButton(provider: AccountSignInProvider) -> some View {
        Button(action: {
            Task {
                await accountService.signIn(withProvider: provider)
            }
        }) {
            Text("Sign in with \(provider.displayName)")
        }
        .irisPrimaryPill()
        .disabled(accountService.isSignInInProgress)
        .opacity(accountService.isSignInInProgress ? 0.55 : 1.0)
    }

    private var emailAndPasswordSignInFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("you@example.com", text: $emailAddressInput)
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

            HStack(spacing: 8) {
                SecureField("Password", text: $passwordInput)
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
                        submitEmailAndPasswordSignIn()
                    }

                Button(action: {
                    submitEmailAndPasswordSignIn()
                }) {
                    Text("Sign in")
                }
                .irisPrimaryPill(isFullWidth: false, isCompact: true)
                .disabled(accountService.isSignInInProgress)
            }
        }
    }

    private func submitEmailAndPasswordSignIn() {
        let trimmedEmailAddress = emailAddressInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmailAddress.isEmpty, !passwordInput.isEmpty else { return }
        let passwordToSubmit = passwordInput
        // Dropped from view state before the request even starts — the panel
        // has no reason to keep holding a password while the network works.
        passwordInput = ""
        Task {
            await accountService.signIn(withEmailAddress: trimmedEmailAddress, password: passwordToSubmit)
        }
    }

    // MARK: Bring your own key

    @ViewBuilder
    private var bringYourOwnKeyRows: some View {
        if accountService.hasStoredAnthropicAPIKey {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)

                Text("Using your Anthropic key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Button(action: {
                    accountService.forgetAnthropicAPIKey()
                }) {
                    Text("Remove")
                }
                .irisTextButton(fontSize: 10, isDanger: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Or use your own Anthropic key")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                HStack(spacing: 8) {
                    // Secure, because this is a credential and because a key
                    // pasted in plain text on a screen Iris can screenshot is
                    // exactly the thing this app should not photograph.
                    SecureField("sk-ant-…", text: $anthropicAPIKeyInput)
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
                            submitAnthropicAPIKey()
                        }

                    Button(action: {
                        submitAnthropicAPIKey()
                    }) {
                        Text(accountService.isValidatingAnthropicAPIKey ? "Checking…" : "Save")
                    }
                    .irisPrimaryPill(isFullWidth: false, isCompact: true)
                    .disabled(accountService.isValidatingAnthropicAPIKey
                              || anthropicAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let anthropicAPIKeyFailureMessage = accountService.anthropicAPIKeyFailureMessage {
                    Text(anthropicAPIKeyFailureMessage)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Stored in your Keychain and sent only to api.anthropic.com — never to publik.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The pasted-key rows and the Claude Code CLI-login rows, shown together.
    /// Rendered in BOTH the signed-out account section (a chat fallback) and the
    /// signed-in one (where it is the only way to power app editing, since chat
    /// is funded but editing runs on the reader's own model).
    private var bringYourOwnCredentialSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            bringYourOwnKeyRows
            claudeCodeLoginRows
            if isShowingClaudeCodeSetup {
                claudeCodeSetupInlineView
            }
            codexLoginRows
            if isShowingCodexSignIn {
                codexSignInInlineView
            }
        }
        .onAppear { accountService.refreshCodexLoginState() }
    }

    // MARK: Claude Code CLI login

    @ViewBuilder
    private var claudeCodeLoginRows: some View {
        if accountService.hasConnectedClaudeCodeLogin {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)

                Text("Connected via Claude Code")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Button(action: {
                    accountService.disconnectClaudeCodeLogin()
                    claudeCodeImportMessage = nil
                }) {
                    Text("Disconnect")
                }
                .irisTextButton(fontSize: 10, isDanger: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Or sign in with a CLI")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                HStack(spacing: 8) {
                    Button(action: { startClaudeCodeSetup() }) {
                        Text("Sign in with Claude Code")
                    }
                    .irisTinyButton()

                    Button(action: { importExistingClaudeCodeLogin() }) {
                        Text("Import login")
                    }
                    .irisTinyButton()
                }

                if let claudeCodeImportMessage {
                    Text(claudeCodeImportMessage)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Uses your Claude Code login (via `claude setup-token`), sent only to api.anthropic.com. A Claude subscription token can be rate-limited for third-party use — a pasted API key is the most reliable option.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The inline `claude setup-token` terminal — shown in the panel rather than a
    /// sheet, because the menu-bar panel is a non-activating NSPanel where a
    /// SwiftUI sheet does not reliably present.
    private var claudeCodeSetupInlineView: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch claudeCodeSetupSession.phase {
            case .claudeNotFound:
                Text("Claude Code isn't installed where Iris can find it. Install it, run `claude login`, or paste an API key above.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            case .running:
                Text("Complete the sign-in Claude Code opened in your browser. Iris captures the token automatically.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .captured:
                Text("Connected! Iris will use your Claude Code login.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.success)
            case .finishedWithoutToken:
                Text("That finished without a token. Try again, or paste an API key above.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let reason):
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }

            if !claudeCodeSetupSession.visibleTranscript.isEmpty {
                ScrollView {
                    Text(claudeCodeSetupSession.visibleTranscript)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 130)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.surfaceRaised)
                )
            }

            if claudeCodeSetupSession.isRunning {
                HStack(spacing: 8) {
                    TextField("Type here if the CLI asks for input…", text: $claudeCodeSetupInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(DS.Colors.surfaceRaised)
                        )
                        .onSubmit { sendClaudeCodeSetupInput() }

                    Button(action: { sendClaudeCodeSetupInput() }) {
                        Text("Send")
                    }
                    .irisTinyButton()
                }
            }

            HStack {
                Spacer()
                Button(action: { endClaudeCodeSetup() }) {
                    Text(claudeCodeSetupSession.phase == .captured ? "Done" : "Cancel")
                }
                .irisTextButton(fontSize: 10)
            }
        }
        .onChange(of: claudeCodeSetupSession.phase) { _, newPhase in
            // A capture connects the credential the instant it lands.
            if newPhase == .captured {
                accountService.refreshClaudeCodeLoginState()
            }
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
    }

    // MARK: Codex CLI login

    @ViewBuilder
    private var codexLoginRows: some View {
        if accountService.hasConnectedCodexLogin {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)

                Text(accountService.codexLoginState == .signedInWithAPIKey
                     ? "Connected via Codex (API key)"
                     : "Connected via Codex")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Button(action: { accountService.disconnectCodexLogin() }) {
                    Text("Disconnect")
                }
                .irisTextButton(fontSize: 10, isDanger: true)
            }
        } else if accountService.codexLoginState == .codexNotInstalled {
            // Deliberately does NOT lead with "Iris can't find it". The first
            // reader to hit this had the ChatGPT app installed, read the old
            // wording as a claim about where Iris was looking, and never
            // reached the install line — which was fair, because Iris really
            // was looking in the wrong places. Now that bundled Codex is found,
            // the honest remaining case is "the tool genuinely isn't here".
            Text("Iris couldn't find the Codex command-line tool on this Mac. If you have the ChatGPT app, updating it to a recent version includes Codex. Otherwise install it with `npm i -g @openai/codex`.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: { startCodexSignIn() }) {
                    Text("Sign in with Codex")
                }
                .irisTinyButton()

                Text("Uses your ChatGPT account through the Codex CLI, which keeps the credential itself — Iris never stores it. Powers app editing, not chat. A ChatGPT subscription used by a third-party app is a gray area and can be rate-limited; a pasted key is the unambiguous option.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The inline `codex login` terminal. Inline for the same reason the Claude
    /// one is: the menu-bar panel is a non-activating NSPanel where a SwiftUI
    /// sheet does not reliably present.
    private var codexSignInInlineView: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch codexSignInSession.phase {
            case .codexNotFound:
                Text("Iris couldn't find the `codex` command. Install it with `npm i -g @openai/codex` and try again.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            case .running:
                Text("Complete the sign-in Codex opened in your browser. Iris is watching for it to land.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .connected:
                Text("Connected! Iris will use your Codex login for app editing.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.success)
            case .finishedWithoutLogin:
                Text("That finished without signing in. Try again, or paste an API key above.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let reason):
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }

            if !codexSignInSession.visibleTranscript.isEmpty {
                ScrollView {
                    Text(codexSignInSession.visibleTranscript)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 130)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.surfaceRaised)
                )
            }

            if codexSignInSession.isRunning {
                HStack(spacing: 8) {
                    TextField("Type here if the CLI asks for input…", text: $codexSignInInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(DS.Colors.surfaceRaised)
                        )
                        .onSubmit { sendCodexSignInInput() }

                    Button(action: { sendCodexSignInInput() }) {
                        Text("Send")
                    }
                    .irisTinyButton()
                }
            }

            HStack {
                Spacer()
                Button(action: { endCodexSignIn() }) {
                    Text(codexSignInSession.isRunning ? "Cancel" : "Done")
                }
                .irisTextButton(fontSize: 10)
            }
        }
        .onChange(of: codexSignInSession.phase) { _, _ in
            accountService.refreshCodexLoginState()
            NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
        }
    }

    private func startCodexSignIn() {
        isShowingCodexSignIn = true
        codexSignInSession.start()
        NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
    }

    private func sendCodexSignInInput() {
        let trimmed = codexSignInInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            codexSignInSession.sendReturn()
            return
        }
        codexSignInSession.sendLine(trimmed)
        codexSignInInput = ""
    }

    private func endCodexSignIn() {
        codexSignInSession.cancel()
        isShowingCodexSignIn = false
        codexSignInInput = ""
        accountService.refreshCodexLoginState()
        NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
    }

    private func startClaudeCodeSetup() {
        claudeCodeImportMessage = nil
        isShowingClaudeCodeSetup = true
        claudeCodeSetupSession.start()
        NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
    }

    private func sendClaudeCodeSetupInput() {
        let trimmed = claudeCodeSetupInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            claudeCodeSetupSession.sendReturn()
            return
        }
        claudeCodeSetupSession.sendLine(trimmed)
        claudeCodeSetupInput = ""
    }

    private func endClaudeCodeSetup() {
        claudeCodeSetupSession.cancel()
        isShowingClaudeCodeSetup = false
        claudeCodeSetupInput = ""
        NotificationCenter.default.post(name: .clickyResizePanelToContent, object: nil)
    }

    private func importExistingClaudeCodeLogin() {
        let outcome = accountService.importClaudeCodeLogin()
        switch outcome {
        case .imported:
            claudeCodeImportMessage = "Connected using your Claude Code login."
        case .noClaudeCodeLoginFound:
            claudeCodeImportMessage = "No Claude Code login found. Run `claude login`, or use Sign in with Claude Code."
        case .couldNotReadKeychain:
            claudeCodeImportMessage = "Iris couldn't read the Claude Code login — you may have denied the Keychain prompt."
        case .loginHadNoUsableToken:
            claudeCodeImportMessage = "That Claude Code login has no token Iris can use — try Sign in with Claude Code."
        }
    }

    /// Validates the pasted key against Anthropic before storing it, so a typo
    /// is caught here instead of at the bottom of the next screenshot request.
    private func submitAnthropicAPIKey() {
        let candidateAPIKey = anthropicAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateAPIKey.isEmpty else { return }
        Task {
            let wasSaved = await accountService.validateAndSaveAnthropicAPIKey(candidateAPIKey)
            if wasSaved {
                // Never repopulated afterwards: once saved, the key exists only
                // in the Keychain and in the request that uses it.
                anthropicAPIKeyInput = ""
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "power")
                        .font(.system(size: 9, weight: .medium))
                    Text("Quit Iris")
                }
            }
            .irisTextButton(fontSize: 10)

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button(action: {
                    companionManager.replayOnboarding()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 9, weight: .medium))
                        Text("Watch Onboarding Again")
                    }
                }
                .irisTextButton(fontSize: 10)
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        IrisShellBackground()
    }

    /// The eye reports what Iris is doing the way the pill's moods did:
    /// thinking while a question is in flight, watching while pointing,
    /// green-and-done only ever from the guide side.
    private var eyeMood: IrisEyeView.Mood {
        switch companionManager.assistantState {
        case .capturing, .thinking:
            return .thinking
        case .pointing:
            return .watching
        case .idle:
            return .idle
        }
    }

    /// While a guide is open, the eye's halo becomes the guide's progress
    /// ring — the same job `.iris-eye__progress` does in the pill.
    private var eyeProgressRing: Double? {
        guard guideSessionController.loadState.isShowingSomethingAboutAGuide else { return nil }
        return guideSessionController.fractionOfTheGuideCompleted
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.assistantState {
        case .idle:
            return "Active"
        case .capturing:
            return "Capturing"
        case .thinking:
            return "Thinking"
        case .pointing:
            return "Pointing"
        }
    }

}

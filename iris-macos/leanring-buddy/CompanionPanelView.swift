//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the assistant
//  status, a text input for asking questions, and quick settings. Designed to
//  feel like Loom's recording panel — dark, rounded, minimal, and special.
//

import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    /// Observed separately from the companion manager so the account rows
    /// redraw the instant a sign-in finishes, rather than on the next thing
    /// that happens to change assistant state.
    @ObservedObject var accountService: AccountService

    @State private var messageInput: String = ""

    /// The BYO key while the user is typing it. Cleared the moment it is saved
    /// and never repopulated — a saved key is never echoed back into the UI.
    @State private var anthropicAPIKeyInput: String = ""
    @State private var isShowingEmailAndPasswordSignIn: Bool = false
    @State private var emailAddressInput: String = ""
    @State private var passwordInput: String = ""

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        _accountService = ObservedObject(wrappedValue: companionManager.accountService)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                askSection
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 12)

                modelPickerRow
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

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Iris")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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

    // MARK: - Ask Iris (text input + response)

    /// The text input wired to the same pipeline that previously received the
    /// final dictation transcript, plus the latest assistant response.
    private var askSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Ask Iris anything…", text: $messageInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                    .onSubmit {
                        submitCurrentMessage()
                    }

                Button(action: {
                    submitCurrentMessage()
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                         ? DS.Colors.textTertiary
                                         : DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(messageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            responseArea
        }
    }

    /// Fixed-height response area so the panel doesn't resize while visible.
    private var responseArea: some View {
        ScrollView {
            Text(responseAreaText)
                .font(.system(size: 12))
                .foregroundColor(responseAreaIsPlaceholder ? DS.Colors.textTertiary : DS.Colors.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(height: 140)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private var responseAreaText: String {
        switch companionManager.assistantState {
        case .capturing:
            return "Capturing your screen…"
        case .thinking:
            return "Thinking…"
        case .idle, .pointing:
            if let latestAssistantResponseText = companionManager.latestAssistantResponseText {
                return latestAssistantResponseText
            }
            // Said before the user types rather than after: with no account and
            // no key there is nothing behind the text field, and finding that
            // out by asking a question and getting an error is a worse way to
            // learn it.
            guard accountService.activeTierDescription != nil else {
                return AssistantTransportError.noCredentialsAvailable.userFacingMessage
            }
            return "Iris sees your screen when you ask, and answers here."
        }
    }

    private var responseAreaIsPlaceholder: Bool {
        switch companionManager.assistantState {
        case .capturing, .thinking:
            return true
        case .idle, .pointing:
            return companionManager.latestAssistantResponseText == nil
        }
    }

    private func submitCurrentMessage() {
        let trimmedMessage = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }
        companionManager.sendUserMessage(trimmedMessage)
        messageInput = ""
    }

    // MARK: - Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Button(action: {
                companionManager.triggerOnboarding()
            }) {
                Text("Start")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
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
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                modelOptionButton(label: "Sonnet", modelID: "claude-sonnet-4-6")
                modelOptionButton(label: "Opus", modelID: "claude-opus-4-6")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
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
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
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
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                Text("Answers are on publik while you're signed in.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)
            }
            .buttonStyle(.plain)
            .pointerCursor()

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

            bringYourOwnKeyRows
        }
    }

    private func signInProviderButton(provider: AccountSignInProvider) -> some View {
        Button(action: {
            Task {
                await accountService.signIn(withProvider: provider)
            }
        }) {
            Text("Sign in with \(provider.displayName)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: !accountService.isSignInInProgress)
        .disabled(accountService.isSignInInProgress)
        .opacity(accountService.isSignInInProgress ? 0.5 : 1.0)
    }

    private var emailAndPasswordSignInFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("you@example.com", text: $emailAddressInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )

            HStack(spacing: 8) {
                SecureField("Password", text: $passwordInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .onSubmit {
                        submitEmailAndPasswordSignIn()
                    }

                Button(action: {
                    submitEmailAndPasswordSignIn()
                }) {
                    Text("Sign in")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor(isEnabled: !accountService.isSignInInProgress)
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.destructiveText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
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
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )
                        .onSubmit {
                            submitAnthropicAPIKey()
                        }

                    Button(action: {
                        submitAnthropicAPIKey()
                    }) {
                        Text(accountService.isValidatingAnthropicAPIKey ? "Checking…" : "Save")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor(isEnabled: !accountService.isValidatingAnthropicAPIKey)
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
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Iris")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button(action: {
                    companionManager.replayOnboarding()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("Watch Onboarding Again")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.assistantState {
        case .idle:
            return DS.Colors.success
        case .capturing, .thinking, .pointing:
            return DS.Colors.blue400
        }
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

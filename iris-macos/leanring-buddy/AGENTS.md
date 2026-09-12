# AGENTS.md - leanring-buddy (Main App Target)

## Usability test branch additions

- Account follow-up: installed 25.16 retains the 25.15 UI/drag fixes and adds session reliability. `AccountSessionStorage` injects a Keychain-only production boundary; missing and denied reads differ. Failed saves retain the rotated token in memory and show a persistence warning. Temporary refresh failures never delete credentials; only allowlisted invalid-session responses do. Single-flight and generation guards protect concurrent refresh/sign-in/sign-out. Background checks remain non-interactive. Run `swift test --package-path iris-macos/tools/account-session-tests` for 13 offline production-service tests. Actual Mac launch recorded Keychain read denial (-25293); one explicit saved-account approval and authenticated restart acceptance remain pending. Do not treat offline fixtures as live login acceptance.
- Latest user decision supersedes the implementation approval below: 25.13 was rejected. Installed 25.15 restores the compact dark UI and existing eye while retaining app icons, readable text, request-specific loading and prior engine safeguards. No unified shell, extra header controls or adaptive palette. No more redesigns or prototypes without direction.
- Eye dragging uses the fixed overlay coordinate space and `OverlayEyeDragSession` immutable initial home/pointer anchors. Release and its watchdog share an animation-free final update before saving once. The pointer timer runs in common modes. Seven drag regression tests cover offsets, repeated samples, reversals, edge recovery, latest release position, persistence and tiny screens. Total isolated checks: 134 usability plus six inert chat-action tests. Native same-screen landing, edge return, close and restart position passed; cross-display dragging and frame latency are not measured.

- September 5 implementation approval supersedes the UI hold: the user explicitly requests native implementation, no additional standalone prototypes, and preservation of the current eye. Candidate 25.13 integrates the unified shell, adaptive panel palette, task shortcuts, pending-chat loading bar and dedicated History view. Preserve fixed eye colors separately from adaptive panel tokens. Build and native acceptance must still be verified before reporting installation.
- `IrisChatLoadingBar.swift` is installed in 25.15 for an actual pending request. `CompanionManager.chatResponseIsPending` is response-ID guarded; unrelated guide pointing must not animate chat. Reduce Motion uses a static treatment. Live response animation and VoiceOver remain unverified.
- `CodexEditModelSelection.swift` reads public model-cache metadata only and validates a persisted model identifier. `CodexEditModelPicker.swift` controls the next project edit, not general help or guide repair.
- `MaintainModelProviding.requestedModelDescription` and the engine's `modelRouteSelected` event report a requested route, never an inferred resolved model. Preserve `--ignore-user-config`, `--ephemeral` and the read-only sandbox.
- `EditVerificationReceipt.swift` separates passed, failed and skipped checks from delivery milestones. `verificationCompleted` carries real stage results to the coordinator. Features still do not become verified fixes.
- The per-edit run log now stays open through delivery and the symptom verdict. Flow reset closes it. Do not close it at the code-save milestone and silently lose later events.
- This branch does not add approval prompts or change automatic delivery and verification acceptance policy. Stronger complex-feature gating is research only on a separate branch.
- Routine credential operations are non-interactive. `KeychainReadPolicy` serializes synchronous Keychain access and temporarily disables legacy login-Keychain interaction, restoring the prior process-local flag afterward. `LAContext` alone does not suppress legacy Keychain prompts. Only an explicit reconnect or Claude login import enables UI; never enable it from provider availability checks or token refresh. Failed saves must not delete existing credentials.
- See `../../docs/testing/usability-branch.md` for acceptance status. Run the isolated model/receipt/Keychain suite with `swift test --package-path iris-macos/tools/usability-tests` from the repository root. Full UI/build validation is separate and must follow the existing no-terminal-xcodebuild rule.

## Source Files

### Usability regression batch (build 25.3 candidate)

- `ChatTranscriptStore` persists a conversation boundary in the bounded archive. New chat preserves history but never warms up the next conversation from an earlier one. Request IDs and cancellation checks reject stale replies and late command approvals.
- Clear history is a separate, Cancel-default confirmed action. It clears the local chat archive and live chat, not edit logs or projects. Failed persistence must remain visible. History answers can expand and support selection; keep the archive's concrete 220-point scroll height so the floating panel does not collapse it.
- Settings routes and Quick tour replay reveal the top of the destination. The tour is optional and replayable, ends at Browse apps, and must not claim that an unproduced onboarding video is available.
- Apps presents installed choices and discovery before the optional guide-name form. Catalog links explain that they open a browser, not that Iris can never install apps through its separate guide workflow.
- Installed build 25.9 checks installed-copy restoration, relaunch and clean source restoration before claiming success. It retains the edit branch, refuses dirty or moved source, preserves session recovery information and resumes incomplete steps on retry. Pending recovery blocks new edits and new publish actions. Do not promise cancellation of already-dispatched publishing.
- Installed 25.11 adds Stop this Undo with Cancel-default confirmation. It archives exact bounded recovery bytes before clearing the active marker, changes no app/source/backup files, and never claims restoration. Valid archives protect only affected Iris edit/replay/delivery paths; unrelated apps remain editable. Unknown/corrupt targets remain broadly blocked and visibly disclosed. Saved recovery details remain accessible in General settings. Native compile and 133 isolated tests passed. Native dummy-fixture acceptance passed for Cancel/Return, explicit Stop, archive bytes, Apps routing, Settings/Finder access and restart persistence. Test-only profile metadata was removed recoverably, and real history remained unchanged. Actual installed-app restoration remains unverified. Do not install superseded candidates.
- A pending marker suppresses legacy automatic file recovery at launch/quit; archived records suppress it for protected targets. Checked queue removal must succeed before the active marker is cleared or Undo claims completion. Late changelog/publish/fork completions are rejected after Undo/Stop invalidates their identity, without claiming cancellation of already-sent requests. The composer must not silently consume another edit while showing a stopped recovery result.
- `CatalogMacCompatibility.swift` accepts only published Mac desktop or local-web routes for starter recommendations. Unknown support is not unsupported; explicit searches label it. Directory enrichment is bounded to four requests at a time and eight seconds total, cached per session.
- `GuideAutopilotAvailability.swift` explains manual-only guides without enabling commands that do not exist. Existing execution consent, autonomy preference and risk floors are unchanged.
- `GuidePointingFreshness.swift` validates screen indices, screenshot bounds and stale window/display geometry. It does not prove model semantic accuracy or unchanged scroll/tab content.
- `AssistantRequestDiagnostics.swift` logs only categorical route, numeric HTTP status and allowlisted error class. Never persist arbitrary provider messages or bodies as diagnostics.
- Settings are grouped into General, Connections and Apps in one reusable 376-point-minimum panel. Both the standard Settings command and scene route to it. The composer exposes one context-aware model control with inline details. History remains reachable during guide and edit takeovers.
- `SettingsPanelRouting.swift` and `SettingsPanelSceneRedirect.swift` prevent duplicate settings surfaces. Drag placement is saved after settling; programmatic layout changes do not become user preferences.
- `ComposerConnectionPresentation.swift` describes the actual request context from cached availability metadata. Codex powers edits, not screen help. Never initiate authentication from rendering a label.
- `CatalogAppIconView.swift` uses an installed bundle's real icon or a verified public app asset. `CatalogAppIconLoader.swift` bounds HTTPS downloads, concurrency and session caching, with an initial fallback. Never substitute another product's mark.
- Run both isolated suites: `swift test --package-path iris-macos/tools/usability-tests` and `swift test --package-path iris-macos/tools/chat-action-tests`. The second suite uses inert shell/clipboard boundaries. GUI build, installed identity and actual user behavior remain separate acceptance gates.

### FloatingSessionButton.swift
- `FloatingSessionButtonManager` — `@MainActor` class managing the `NSPanel` lifecycle
  - `showFloatingButton()` — Creates/shows the panel in top-right of primary screen
  - `hideFloatingButton()` — Hides panel (keeps it alive for quick re-show)
  - `destroyFloatingButton()` — Removes panel permanently (session ended)
  - `onFloatingButtonClicked` — Callback closure, set by ContentView to bring main window to front
  - `floatingButtonPanel` — Exposed `NSPanel` reference for screenshot exclusion
- `FloatingButtonView` — Private SwiftUI view with gradient circle, scale+glow hover animation, pointer cursor

### ContentView.swift
- Receives `FloatingSessionButtonManager` via `@EnvironmentObject`
- `isMainWindowCurrentlyFocused` — Tracks main window focus state
- `configureFloatingButtonManager()` — Wires up the click callback
- `startObservingMainWindowFocusChanges()` — Sets up `NSWindow` notification observers
- `updateFloatingButtonVisibility()` — Core logic: show if running + not focused, hide otherwise
- `bringMainWindowToFront()` — Activates app and orders main window front

### ScreenshotManager.swift
- `floatingButtonWindowToExcludeFromCaptures` — `NSWindow?` reference set by ContentView
- `captureScreen()` — Matches the floating window to an `SCWindow` and excludes it from capture filter

### leanring_buddyApp.swift
- Owns `FloatingSessionButtonManager` as `@StateObject`
- Injects it into ContentView via `.environmentObject()`

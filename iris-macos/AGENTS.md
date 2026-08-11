# Iris - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

Iris — the desktop assistant for publik. A text-first fork of Clicky by Farza (see NOTICE / LICENSE.upstream). macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon — or pressing the global summon hotkey (ctrl+option) — toggles a custom floating panel with a text input. The typed message + a screenshot of the user's screen(s) go to Claude; the response is shown as text in the panel. An eye overlay — Iris's eye, the same one the website draws — rides beside the pointer, watches it, and can fly to and point at UI elements Claude references on any connected monitor.

Voice features (AssemblyAI/OpenAI/Apple Speech transcription, ElevenLabs TTS) and PostHog analytics were removed in the fork.

Nothing sensitive ships in the app binary. The assistant reaches a model by exactly one of two routes: publik's funded endpoint (a Supabase-authenticated passthrough, where publik holds the Anthropic key) or the user's own Anthropic key stored in their Keychain. See "Assistant transports" below.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude with SSE streaming, over one of two transports (funded via publik, or the user's own Anthropic key)
- **Identity**: Supabase PKCE OAuth in the system browser (`ASWebAuthenticationSession`) or email+password; no Supabase SDK, no SPM dependencies
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Text Input**: The input bar under the eye, wired to `CompanionManager.sendUserMessage` — the same pipeline that previously received the final dictation transcript. The whole exchange happens in that bar; the menu bar panel is settings only. System-wide summon hotkey via listen-only CGEvent tap toggles the settings panel.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the eye along a bezier arc to the target. The eye looks at the element for the whole flight and while it points, then looks back at the mouse on the way home.
- **Install Guides**: `iris://guide/<slug>?version=&branch=&step=` links from publikhq.com open a step-by-step install guide inside the panel. `GuideSessionController` owns the open guide; `GuidePanelView` draws it. Reaches parity with the guide pill the Tauri app (`iris-desktop/`) shipped.
- **App Awareness**: `AppInventoryService` knows which publik catalog apps are installed on this Mac, which version each is, whether a newer release exists, and which one is frontmost. It reads the catalog from `GET {publik}/api/iris/apps`, and reports an app publik has no `macBundleId` for as `unknown` rather than as "not installed" — see below.
- **Concurrency**: `@MainActor` isolation, async/await throughout

### Assistant transports

`docs/iris-assistant-protocol.md` in the publik repo is the authoritative contract. There are exactly two routes, and they speak the identical wire format (the Anthropic Messages API, streaming SSE), so one SSE parser serves both:

| Tier | Endpoint | Auth | Model |
|------|----------|------|-------|
| Funded | `POST {publik}/api/assistant/chat` | `Authorization: Bearer <supabase access token>` | pinned server-side; the client's `model` is ignored and therefore not sent |
| BYO | `POST https://api.anthropic.com/v1/messages` | the user's own `x-api-key`, stored in the Keychain | the client's choice |

**THE BYO KEY IS NEVER SENT TO ANY PUBLIK HOST.** `AssistantTransport.swift` enforces this structurally (the only function that writes an `x-api-key` header takes no URL — the destination is a constant), by assertion (`validatedRequest`), and by test (`AssistantTransportTests`). Do not add a code path that accepts both a key and a destination.

The funded tier's error codes map to fixed user-visible states: `sign_in_required` (401) → prompt re-sign-in, `rate_limited` / `daily_budget_exhausted` (429 + `Retry-After`) → quota message, `assistant_unconfigured` (503) → outage, anything else → generic failure. A raw server body is never shown to the user.

The `worker/` directory is dead — a leftover from the upstream Clicky fork, kept only as a wire-format reference. The app no longer calls it.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the eye companion. It's non-activating, joins all Spaces, and never steals focus. The eye's position, mood, gaze and pointing animations all render in this overlay via SwiftUI through `NSHostingView`. The pointer is read with `NSEvent.mouseLocation` rather than an event tap, deliberately: that needs no Accessibility grant, so the eye keeps tracking on a machine where permissions are only partly granted.

**The Eye Is The Interface**: The eye is 64pt and clicking it opens the input bar under it, while the eye itself becomes a gear that opens the settings panel. The bar carries the *whole* exchange — it does not hand off to the menu bar panel, which is what it used to do. `OverlayEyeExchange` is the four-state machine it runs on: `composingTheFirstQuestion` (empty field, suggestion chips) → `waitingForIrisToAnswer` (the question echoed above a working line whose wording follows `assistantState`, so the bar and the spinning eye always agree) → `showingTheAnswer` (the answer, or the failure sentence, in the same slot, wrapped and scrolling past `tallestTheAnswerAreaMayGrow`) → `composingAFollowUp` (the answer stays up while the next question is typed). Dismissal — Escape, the ×, a click outside, or the eye leaving this screen — destroys the view, which is what makes "dismissing clears the exchange" true without anything having to remember it.

Three rules make that safe on a window that covers the whole screen:

- **Click-through is gated, not hit-tested.** The overlay stays `ignoresMouseEvents = true` everywhere; the 60fps pointer poll opens `OverlayWindowMouseEventGate` only while the pointer is inside the eye's own ~76pt square, and shuts it again on the way out. Returning nil from a view's `hitTest(_:)` would not do — the window would still swallow the click instead of passing it to the app below. `OverlayEyeInteractionGeometry.theOverlayShouldAcceptMouseEvents` is the single decision, and `OverlayEyeClickThroughTests` sweeps the whole display against it.
- **The bar is its own window.** The overlay must never become key, so the input bar lives in a small separate `.nonactivatingPanel` (`OverlayEyeInputBarPanelManager`) that can. A non-activating panel takes keystrokes without activating Iris, so the user's app stays frontmost. Because the bar is its own window, its clicks and scrolls never travel through the overlay at all: when an answer makes the bar taller the interactive surface grows because the *panel* grew, and the overlay's gate does not move a pixel. `resizeTheBarToFit` re-places the window against the eye it hangs from, pinning the top edge so it grows downward and clamping at `tallestTheInputBarMayGrow`.
- **The bar holds the keyboard only while a question is being composed.** A panel that stays key after the question is sent goes on swallowing keystrokes meant for the app the reader went back to — real characters typed into a real editor once landed in this bar. `OverlayEyeExchange.theBarShouldHoldTheKeyboard` is the rule; `releaseTheKeyboardSoTheReadersOwnAppGetsItBack` is the mechanism (drop the first responder, turn `canBecomeKey` off, `NSApp.deactivate()`, with an `orderOut`/`orderFront` safety net) and `takeTheKeyboardBackForTheTextField` reverses it when the reader clicks back into the field. Dismissal is still an `orderOut`, which hands key status straight back.

**Global Summon Hotkey**: The background hotkey uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background. Pressing it toggles the companion panel (it previously started/stopped dictation).

**Setup Recovery Detour**: The commonest way an install fails is a prerequisite that is not there. When a branch loads, `GuideSessionController` checks the tools that branch's `setupSteps` declare; if one is missing it diverts the reader into those setup steps — explaining which tool and why — instead of dropping them on step one of an install they cannot start. A re-check ends the detour when the tool appears, and an explicit, de-emphasised skip exists for people who have it under a name the check cannot see. The detour writes nothing to progress storage: the reader's place in the guide survives it untouched, which is why `advanceToTheNextStep` refuses to run while the detour is open. A branch with a missing tool but no `setupSteps` is never diverted, because a card with no repair route is a dead end.

**Adaptive Watch Loop**: While a guide step that declares a `watch` block is open, `WatchLoop` notices that the reader has actually done it and advances the guide without being told. It is a strict cheapest-first ladder — is a watched step even open, is Iris allowed to look at all, has the screen meaningfully changed (one ~256 px grayscale capture and a 64-bit dHash), do the local signals settle it (frontmost app, window title, `ToolVersionService`, `GitInspectionService`, AX), and only then one model call for a step that declares a `visual` expectation. The model budget from `docs/iris-assistant-protocol.md` §7 (≥ 10 s apart, ≤ 8 per step) is enforced in code, and hitting the ceiling drops that step back to local signals rather than stopping the loop. Every privacy rule in §5 is a code path with a test: frames exist only as a local `let` around the one call that sends them, capture hard-suspends on secure input, a `sensitive` step is never captured at all and completes from side signals, a user-editable excluded-apps list seeded with password managers blocks capture while one is frontmost, and an indicator plus an always-immediate global pause are both derived from the loop's own state.

**Guided-install autopilot**: Iris can now run a guide's `command` steps itself instead of only displaying them for a manual copy. `GuideAutopilotRunner` drives a state machine — execute → risk gate → outcome → on failure, a fix ladder (fix from the guide material → fix informed by a web search → surface the diagnosis to the reader) → retry → advance — against a persistent pty-backed login shell, streaming output into a terminal view under the step card. Clean commands run automatically; admin, destructive, and obfuscated commands pause for an explicit "Run it" tap; network-pipe-to-shell and disk-destroying commands are refused outright and are never tappable. Autopilot starts only when the reader taps "Let Iris run it" in the panel — reachable through `performPrimaryAction` and never from an `iris://` deep link, which can preselect a guide and step but cannot start execution. Executed commands come only from the HTTPS-fetched, version-pinned guide JSON (status `pilot`/`approved`); a step with `watch.sensitive: true` is never executed, echoed, or sent to a model, and falls back to the copy-by-hand card. All model-bound terminal output is secret-scrubbed on egress. The panel no longer auto-collapses while a guide is open — a click-off or the eye moving off-screen no longer tears it down; only the × or End does. Everything here is budget-latched per `docs/iris-assistant-protocol.md` §8 (2 fix attempts/step, 8 model calls/guide).

When Iris reaches a step it cannot clear on its own — the ladder gives up, or the reader skips a risky command — it does not stop the whole install. It *hands the step back*: `autopilotOwnsTheCurrentStep` goes false, which un-muzzles the watch loop so it can notice the reader finished that one step and advance, resuming the install for the rest; the eye re-points at the step; and a "Your turn" row in the terminal offers Try again (re-run the step) or Continue past it (skip and carry on). Before this a single un-clearable gate stalled the whole run. The terminal is also paced so a complex install reads as deliberate work rather than an instant flash: each command is typed out, a block cursor blinks while it runs, and a command that finishes faster than `GuideAutopilotPacing.minimumVisibleCommandDuration` (0.7s) has its result line held that long — the shell itself is never slowed, and a command that already runs longer gets no hold, so real installs are untouched.

*Key Files (all in `iris-macos/leanring-buddy/`):*

| File | Purpose |
|------|---------|
| `GuideAutopilotPseudoTerminal.swift` | The only file that touches `openpty`/`posix_spawn`. Spawns the shell with `POSIX_SPAWN_SETSID` so the pty becomes its controlling terminal — real job control, real Ctrl-C — without `fork()`ing inside a Cocoa process. |
| `GuideAutopilotShellSession.swift` | One persistent login shell per guide session, so later steps see earlier steps' `cd`/env changes. Drives it through a generated `ZDOTDIR` that loads the user's real dotfiles and then disables ZLE, so programmatic command injection is reliable. |
| `GuideAutopilotOutputBuffer.swift` | Holds command output in two shapes: an unbounded-looking display ring for the terminal view, and a short, ANSI-stripped, secret-scrubbed tail for anything sent to a model. |
| `GuideAutopilotCommandShape.swift` | Pure text analysis of a command — does it hold the shell open (dev servers, watchers), does it ever return — with no execution and no risk judgment of its own. |
| `GuideAutopilotRiskAssessment.swift` | The gate every command passes before the shell runs it: three tiers (auto-run, confirm-tap, refuse-outright) for guide commands and model-proposed fixes alike. A guardrail against mistakes, not an adversarial sandbox — provenance (HTTPS-fetched, version-pinned guide JSON; schema-constrained fix proposals) is the real boundary. |
| `GuideAutopilotFixProposer.swift` | On a failing command, assembles the step/command/exit status/scrubbed output and asks the model for one structured fix via a forced `propose_fix` tool call — material-only first, then with Anthropic's server-side `web_search` if the first fix also fails. No screenshot ever rides along. |
| `GuideAutopilotRunner.swift` | The state machine described above: owns the budgets, the transcript, and published state, reaching the world only through injected collaborators so it is testable without a pty or network. |
| `GuideAutopilotTranscript.swift` | The terminal view's data model — pure values only, so the runner is testable without a UI. Distinguishes a guide command from a model fix by rule colour, label, and indent. |
| `GuideAutopilotTerminalView.swift` | The SwiftUI terminal shown under the guide step card, dressed as a real macOS Terminal window (traffic-light title bar, solid dark body, a `%` prompt, a block cursor that blinks while a command runs, and each command typed out as if entered by hand — the real shell is never slowed, only the way it is shown). Renders the transcript, the confirm row ("Run it") when a risky command is waiting, and a "Your turn" surface row (Try again / Continue past it) when Iris hands a step back. |
| `GuideAutopilotTakeoverPanel.swift` | The centered "takeover" the install runs in. When the reader taps "Let Iris run it", `GuideAutopilotTakeoverController` dims the desktop (a click-through backdrop panel, so a manual sub-step can still reach the app underneath) and morphs the eye into a centered macOS-Terminal window — a small non-activating panel that grows from eye-size while a SwiftUI cross-fade (`GuideAutopilotTakeoverView`, wrapping `GuideAutopilotTerminalView` verbatim) swaps the eye face for the terminal — then folds it back into the eye on completion. The Swift port of the Windows renderer's eye→terminal→eye morph. `CompanionManager` raises it from `onAutopilotDidStart`, tears it down from `onAutopilotDidStop`/`onGuideCompleted`, and `GuideSessionController.autopilotIsShownAsTakeover` hides the under-the-card pane while it is up so the terminal is never drawn twice. |
| `ClaudeSSEMessageAccumulator.swift` | Pure, line-at-a-time reconstruction of one Messages-API SSE response — text deltas, reassembled `tool_use` input JSON, and full content blocks for a `pause_turn` resend. Used by the fix ladder's `propose_fix` calls. |

PTY tests (`GuideAutopilotShellSessionTests.swift`) spawn a real shell and are `.serialized` — run them with `-parallel-testing-enabled NO`, or set `IRIS_SKIP_PTY_TESTS=1` to skip on a box where spawning processes is unwelcome.

**Transient Cursor Mode**: When the cursor is toggled off, submitting a message fades in the cursor overlay for the duration of the interaction (capture → response → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~157 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. Receives every `iris://` link via `application(_:open:)`, parses it with `IrisDeepLinkParser`, and hands a guide link to `GuideSessionController`. |
| `CompanionManager.swift` | ~864 | Central state machine. Owns summon hotkey monitoring, screen capture, the `AccountService`, the Claude API, and overlay management. Tracks assistant state (idle/capturing/thinking/pointing), conversation history, model selection, and cursor visibility. Coordinates the typed message → screenshot → Claude → text response → pointing pipeline via `sendUserMessage`, and maps transport failures to user-visible text. |
| `MenuBarPanelManager.swift` | ~302 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/toggle/position), installs click-outside-to-dismiss monitor. Observes `.clickyTogglePanel` posted on summon hotkey press, `.clickyShowPanel` posted when a guide link arrives, and `.clickyResizePanelToContent` posted when the panel's SwiftUI content changes height on its own. |
| `CompanionPanelView.swift` | ~822 | Iris's **settings**, hosted in the menu bar dropdown: assistant status, model picker (Sonnet/Opus), the account section (sign in with Google/GitHub, email+password, or your own Anthropic key), the installed publik apps, permissions UI, and quit button. Hands the whole panel over to `GuidePanelView` while a guide is open. There is deliberately no "Ask Iris" field or response area here — asking and answering both happen in the bar under the eye. Dark aesthetic using `DS` design system. |
| `GuideSessionController.swift` | ~1256 | Owns the install guide the reader is following: which guide and branch, the current step, completion, and what the step's primary action is (copy a command, open a link, run tool checks, or move on). Maps every `GuideService` failure to its own user-facing sentence, persists progress through `GuideService`'s existing key scheme, and refuses a step link whose host `ExternalLinkPolicy` does not allow rather than rendering a button that does nothing. Also owns the setup recovery detour (see below). |
| `GuidePanelView.swift` | ~837 | SwiftUI guide surface: step card, progress bar, command block with a Copy button and a transient confirmation, tool-check rows, the device-pair picker, the unsupported-pair explanation, the setup recovery card, the watch indicator with its pause toggle, the proactive `userStuck` hint banner, and the completion card. Also `GuideSlugEntryView`, the way into a guide when no `iris://` link was clicked. |
| `AppInventoryService.swift` | ~623 | Which publik catalog apps are on this Mac. Fetches the catalog from `/api/iris/apps`, resolves each `macBundleId` through `NSWorkspace` with an `mdfind` fallback, reads `CFBundleShortVersionString` out of the bundle, and compares it to the latest release tag. An app with no bundle identifier is `unknown`, never `notInstalled`. Also the two collaborator protocols (catalog source, installed-app locator) that make all of it testable without a network or a real installation. |
| `ReleaseVersionComparison.swift` | ~256 | Whether one release version is newer than another, done numerically rather than as a string compare, because `v1.10.0` sorts *before* `v1.9.0` alphabetically and offering that as an update is a downgrade. Handles a leading `v`, differing component counts, build metadata, and semver pre-release precedence; anything unparseable is `cannotBeCompared` rather than a guessed direction. |
| `AppInventorySectionView.swift` | ~145 | The compact "Your publik apps" section of the panel: installed apps only, anything with an update first, an "Update to …" button that opens the app's publik page through `ExternalLinkPolicy`. Iris never downloads or installs anything itself — the download route is auth-gated in the browser deliberately. |
| `WatchLoop.swift` | ~1030 | The adaptive watch loop (see above): the cheapest-first ladder, the model budget, the privacy gates, the dHash, the `userStuck` hint, the excluded-apps list, and the global pause. Also the four collaborator protocols it is built out of, so all of it is testable without a screen, a clock, a process, or a network. |
| `WatchLoopSystemSources.swift` | ~500 | The real macOS answers to those four protocols: a monotonic clock, ScreenCaptureKit for both the ~256 px fingerprint and the one visual frame, the local signals (AppKit, accessibility, `ToolVersionService`, `GitInspectionService`, secure input via the session dictionary), and the one model call, made through `AssistantTransport` and nothing else. |
| `OverlayWindow.swift` | ~1114 | Full-screen transparent overlay hosting the eye companion. Handles cursor following, where the eye is looking, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. Owns the assistant-state → eye-mood mapping, and `OverlayWindowMouseEventGate` — the only thing allowed to turn the overlay's click-through off, and only for the eye. |
| `OverlayEyeInteraction.swift` | ~524 | The eye as a *control*, with no AppKit or SwiftUI in it so all of it is testable without a screen: `OverlayEyeInteractionGeometry` (the 64pt eye, its resting place, the one rectangle that may accept a click, where the input bar hangs, how tall it may grow, and `rectOccupiedByIris` for the eye-plus-bar region), `OverlayEyeActivation` (eye → bar → gear → settings), `OverlayEyeExchange` (the bar's four-state conversation and the rule for who holds the keyboard), and `OverlayEyeSuggestions` — the suggestion chip strings and the working-state lines, in one place, guide-aware. |
| `OverlayEyeInputBar.swift` | ~728 | The bar that opens under the eye and the whole exchange inside it: the field, the chips, the question echo, the working line, the scrolling answer, the failure sentence in the same slot, and the close button. Its own `.nonactivatingPanel` so it can take keystrokes without activating Iris and without the full-screen overlay ever needing to become key — and so it can grow with an answer without touching the overlay's click-through gate. Owns the keyboard hand-back on send. Sends through `CompanionManager.sendUserMessage` — no second pipeline, and no hand-off to the menu bar panel. |
| `OverlayIrisEyeView.swift` | ~730 | The on-screen eye, transcribed from the website (`components/iris/IrisEye.tsx` plus the `.iris-eye*` rules in `app/globals.css`): track, shell, blinking lid, striated iris, pupil and glint. Also `IrisEyePupilGeometry`, the pure maths for where the iris sits — AppKit screen coordinates in, SwiftUI offsets out, one y flip, clamped so the pupil never leaves the lid — and `IrisEyeGazeTracker`, which decides whether to watch the pointer or fall back to the idle wander. Also `OverlaySettingsGearView`, the gear the eye becomes while the input bar is open — same diameter, same shell, same shadow, so the swap reads as one object changing what it offers. Distinct from `IrisEyeView.swift`, which is the smaller panel-header eye from the Tauri shell. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for a cursor-following response text bubble. Currently unused by the pipeline (responses render in the panel) but kept compiling. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `GlobalSummonHotkeyMonitor.swift` | ~167 | System-wide summon hotkey monitor (ctrl + option). Owns the listen-only `CGEvent` tap and publishes press/release transitions; a press toggles the companion panel. |
| `ClaudeAPI.swift` | ~360 | Claude vision API client with streaming (SSE) and non-streaming modes. Transport-driven: asks `AssistantTransport` for the URL and headers on every request, omits `model` on the funded route, maps non-2xx responses to `AssistantTransportError`. Per-host TLS warmup, image MIME detection, conversation history support. |
| `AssistantTransport.swift` | ~364 | Chooses between the funded and BYO routes and builds the request for each. The only place credentials are attached, and the enforcement point for "the BYO key never reaches a publik host". Also owns the funded tier's error-code → user-visible-state mapping. |
| `AccountService.swift` | ~797 | Supabase auth with no SDK: PKCE OAuth in the system browser (`ASWebAuthenticationSession`), email+password, and refresh-token rotation. Publishes signed-in state; owns the user's BYO key, validated on entry with a `count_tokens` call. Reuses `DeepLinkParser` for the `iris://auth/callback` case. |
| `KeychainStore.swift` | ~144 | The only code that touches the Keychain. Stores exactly two secrets under service `com.publikhq.iris`: the BYO Anthropic key and the Supabase refresh token. Never logs either. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~460 | Iris design tokens transcribed from `iris-desktop/ui/styles.css` (the visual spec): the dark glass shell, the `#6f8cff` accent, ink-on-dark primary pills, motion curves, and the Iris button styles (`irisPrimaryPill`, `irisTinyButton`, `irisTextButton`, `irisIconButton`) plus `IrisShellBackground`. If a value here disagrees with styles.css, styles.css wins. |
| `IrisEyeView.swift` | ~140 | The animated Iris eye from `.iris-eye`: blinking lid, pointer-following iris, mood satellite (green while watching/done, ring tint while thinking, slit while paused), and an optional progress ring used while a guide is open. Shown in the panel header; the menu bar icon is its static twin. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~142 | Cloudflare Worker proxy, kept as a wire-format reference. Only `/chat` (Claude) is used by the app. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker (dead — reference only)

The app no longer calls this. It is inherited from the upstream Clicky fork and kept as a wire-format reference; the commands below are historical.

```bash
cd worker
npm install

# Add secrets (only ANTHROPIC_API_KEY is used by the app;
# the upstream worker also documents ASSEMBLYAI/ELEVENLABS routes that Iris no longer calls)
npx wrangler secret put ANTHROPIC_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.

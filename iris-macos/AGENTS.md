# Iris - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

Iris — the desktop assistant for publik. A text-first fork of Clicky by Farza (see NOTICE / LICENSE.upstream). macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon — or pressing the global summon hotkey (ctrl+option) — toggles a custom floating panel with a text input. The typed message + a screenshot of the user's screen(s) go to Claude; the response is shown as text in the panel. A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

Voice features (AssemblyAI/OpenAI/Apple Speech transcription, ElevenLabs TTS) and PostHog analytics were removed in the fork.

Nothing sensitive ships in the app binary. The assistant reaches a model by exactly one of two routes: publik's funded endpoint (a Supabase-authenticated passthrough, where publik holds the Anthropic key) or the user's own Anthropic key stored in their Keychain. See "Assistant transports" below.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude with SSE streaming, over one of two transports (funded via publik, or the user's own Anthropic key)
- **Identity**: Supabase PKCE OAuth in the system browser (`ASWebAuthenticationSession`) or email+password; no Supabase SDK, no SPM dependencies
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Text Input**: TextField in the menu bar panel, wired to `CompanionManager.sendUserMessage` — the same pipeline that previously received the final dictation transcript. System-wide summon hotkey via listen-only CGEvent tap toggles the panel.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Install Guides**: `iris://guide/<slug>?version=&branch=&step=` links from publikhq.com open a step-by-step install guide inside the panel. `GuideSessionController` owns the open guide; `GuidePanelView` draws it. Reaches parity with the guide pill the Tauri app (`iris-desktop/`) shipped.
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

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, spinner, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Summon Hotkey**: The background hotkey uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background. Pressing it toggles the companion panel (it previously started/stopped dictation).

**Transient Cursor Mode**: When the cursor is toggled off, submitting a message fades in the cursor overlay for the duration of the interaction (capture → response → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~157 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. Receives every `iris://` link via `application(_:open:)`, parses it with `IrisDeepLinkParser`, and hands a guide link to `GuideSessionController`. |
| `CompanionManager.swift` | ~864 | Central state machine. Owns summon hotkey monitoring, screen capture, the `AccountService`, the Claude API, and overlay management. Tracks assistant state (idle/capturing/thinking/pointing), conversation history, model selection, and cursor visibility. Coordinates the typed message → screenshot → Claude → text response → pointing pipeline via `sendUserMessage`, and maps transport failures to user-visible text. |
| `MenuBarPanelManager.swift` | ~302 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/toggle/position), installs click-outside-to-dismiss monitor. Observes `.clickyTogglePanel` posted on summon hotkey press, `.clickyShowPanel` posted when a guide link arrives, and `.clickyResizePanelToContent` posted when the panel's SwiftUI content changes height on its own. |
| `CompanionPanelView.swift` | ~974 | SwiftUI panel content for the menu bar dropdown. Shows assistant status, the "Ask Iris" text input + response area, model picker (Sonnet/Opus), the account section (sign in with Google/GitHub, email+password, or your own Anthropic key), permissions UI, and quit button. Hands the whole panel over to `GuidePanelView` while a guide is open. Dark aesthetic using `DS` design system. |
| `GuideSessionController.swift` | ~749 | Owns the install guide the reader is following: which guide and branch, the current step, completion, and what the step's primary action is (copy a command, open a link, run tool checks, or move on). Maps every `GuideService` failure to its own user-facing sentence, persists progress through `GuideService`'s existing key scheme, and refuses a step link whose host `ExternalLinkPolicy` does not allow rather than rendering a button that does nothing. |
| `GuidePanelView.swift` | ~591 | SwiftUI guide surface: step card, progress bar, command block with a Copy button and a transient confirmation, tool-check rows, the device-pair picker, the unsupported-pair explanation, and the completion card. Also `GuideSlugEntryView`, the way into a guide when no `iris://` link was clicked. |
| `OverlayWindow.swift` | ~833 | Full-screen transparent overlay hosting the blue cursor and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for a cursor-following response text bubble. Currently unused by the pipeline (responses render in the panel) but kept compiling. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `GlobalSummonHotkeyMonitor.swift` | ~167 | System-wide summon hotkey monitor (ctrl + option). Owns the listen-only `CGEvent` tap and publishes press/release transitions; a press toggles the companion panel. |
| `ClaudeAPI.swift` | ~360 | Claude vision API client with streaming (SSE) and non-streaming modes. Transport-driven: asks `AssistantTransport` for the URL and headers on every request, omits `model` on the funded route, maps non-2xx responses to `AssistantTransportError`. Per-host TLS warmup, image MIME detection, conversation history support. |
| `AssistantTransport.swift` | ~364 | Chooses between the funded and BYO routes and builds the request for each. The only place credentials are attached, and the enforcement point for "the BYO key never reaches a publik host". Also owns the funded tier's error-code → user-visible-state mapping. |
| `AccountService.swift` | ~797 | Supabase auth with no SDK: PKCE OAuth in the system browser (`ASWebAuthenticationSession`), email+password, and refresh-token rotation. Publishes signed-in state; owns the user's BYO key, validated on entry with a `count_tokens` call. Reuses `DeepLinkParser` for the `iris://auth/callback` case. |
| `KeychainStore.swift` | ~144 | The only code that touches the Keychain. Stores exactly two secrets under service `com.publikhq.iris`: the BYO Anthropic key and the Supabase refresh token. Never logs either. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
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

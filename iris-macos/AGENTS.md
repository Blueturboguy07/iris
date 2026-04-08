# Learning Buddy - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it, and sends it to an AI model along with a screenshot of the user's screen. The companion is always-on and persists context across sessions via soul.md.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Integration**: Dual provider support (OpenAI GPT, Claude) for companion voice responses plus provider-based voice transcription (OpenAI audio transcription, AssemblyAI streaming, Apple Speech fallback)
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+)
- **Voice Input**: Push-to-talk voice input via `AVAudioEngine` + a pluggable transcription-provider layer. Supports OpenAI audio transcription by default, AssemblyAI streaming when configured, and Apple Speech as the fallback. System-wide keyboard shortcut via listen-only CGEvent tap, hidden partial transcripts, waveform-only bottom overlay during recording.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Persistence**: soul.md for long-lived companion memory across sessions

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Global Push-To-Talk Overlay**: The system-wide dictation feedback UI uses a borderless `NSPanel` rather than a SwiftUI overlay so it can remain visible while other apps are focused. The panel is non-activating, joins all Spaces, sits near the bottom of the active screen, and hosts a SwiftUI waveform view through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~65 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~130 | Central state for companion voice mode. Owns `BuddyDictationManager`, `GlobalPushToTalkShortcutMonitor`, and `GlobalPushToTalkOverlayManager`. Tracks voice state (idle/listening/processing), handles shortcut transitions, polls accessibility permission. |
| `MenuBarPanelManager.swift` | ~150 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~310 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk card with shortcut keys, voice state indicator with waveform, settings rows, and quit button. Dark aesthetic using `DS` design system. |
| `ContentView.swift` | ~3805 | (Legacy) Course mode UI — retained in codebase but no longer referenced from the app entry point. |
| `ScreenshotManager.swift` | ~3071 | (Legacy) Course session logic — retained in codebase but no longer referenced from the app entry point. |
| `BuddyDictationManager.swift` | ~740 | Shared push-to-talk voice pipeline. Handles microphone capture, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `AppBundleConfiguration.swift` | ~28 | Shared runtime configuration reader for keys stored in the app bundle `Info.plist`. Used by AI/transcription providers and other services that need bundle-level configuration. |
| `BuddyTranscriptionProvider.swift` | ~85 | Shared protocol surface and provider factory for voice transcription backends. Chooses between AssemblyAI, OpenAI, and Apple Speech based on configuration. |
| `BuddyAudioConversionSupport.swift` | ~108 | Shared audio conversion helpers for voice transcription. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `AppleSpeechTranscriptionProvider.swift` | ~145 | Local fallback transcription provider backed by Apple's Speech framework. Preserves the existing on-device/native path when cloud AI transcription is unavailable. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~428 | Streaming AI transcription provider for push-to-talk. Opens an AssemblyAI websocket, streams PCM audio, keeps partials internal, and finalizes formatted transcript text on key-up. |
| `OpenAIAudioTranscriptionProvider.swift` | ~311 | AI transcription provider backed by OpenAI's audio transcription API. Buffers push-to-talk audio locally, uploads it as WAV on release, and returns the finalized transcript into the shared chat flow. |
| `AuthenticationView.swift` | ~130 | Sign-in UI: Google button with logo + staggered fade-in animation. Dark minimal aesthetic. |
| `UserMemoryStore.swift` | ~210 | Local JSON file persistence for user profile, step progress, and session state. |
| `UserMemoryModels.swift` | ~91 | Local data models: `UserProfile`, `UserMemory`, `StepProgressData`, `SessionState`. |
| `CourseModels.swift` | ~395 | Data models: `CourseStep` (goal, verification, embedded elements), `EmbeddedElement` enum, legacy `UIPlaceholder` types. |
| `CourseDefinition.swift` | ~624 | 21 bite-sized step definitions organized by section (welcome, getting started, setup, build, ship, completion). |
| `Prompts.swift` | ~674 | All AI prompts: system prompt, content generation, verification, brainstorm buddy, profile extraction. |
| `FloatingSessionButton.swift` | ~179 | Floating `NSPanel` lifecycle (create/show/hide/destroy) + SwiftUI button view with gradient circle. |
| `GlobalPushToTalkOverlay.swift` | ~226 | Bottom-of-screen dictation overlay shown during keyboard-triggered push-to-talk. Manages the non-activating `NSPanel` and waveform-only UI that can stay visible while the app is in the background. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~120 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions for the shared global shortcut flow. |
| `OverlayWindow.swift` | ~366 | Advanced window positioning and overlay management. |
| `WindowPositionManager.swift` | ~255 | Window placement logic, Screen Recording permission flow, and auto-shrink helpers. |
| `PermissionsView.swift` | ~238 | macOS permissions onboarding UI for Screen Recording, Accessibility, ScreenCaptureKit warm-up, and Downloads folder access. |
| `AppPermissionManager.swift` | ~69 | Tracks app-level permission state for Downloads folder access and ScreenCaptureKit warm-up that do not have a simple preflight API. |
| `ClaudeAPI.swift` | ~269 | Claude vision API client. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |

## Build & Run

```bash
# Build (requires Xcode with signing certificate, or use CODE_SIGNING_ALLOWED=NO)
xcodebuild -scheme leanring-buddy -configuration Debug build

# Known non-blocking warnings: Swift 6 concurrency warnings in ScreenshotManager.swift,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

## Floating Session Button

The floating button is an always-on-top circular gradient button (28px) in the top-right corner:
- Appears when a learning session is running AND the main window is not focused
- Hides when the main window is focused/visible
- Is destroyed when the session stops
- Is excluded from screen captures sent to the AI
- Clicking it brings the main app window to the front

Visibility logic: `shouldShowFloatingButton = isSessionCurrentlyRunning && !isMainWindowCurrentlyFocused`

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

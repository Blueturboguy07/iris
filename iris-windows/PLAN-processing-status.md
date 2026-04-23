# PLAN-processing-status.md

## Status
**Complete**

## Tool
Claude Code

## Dates
- Created: 2026-04-23

## Overview

Show real-time processing stage feedback to the user while Clicky reads the screen and queries the AI — similar to the "Listening..." overlay indicator shown during push-to-talk. The user currently sees a static "Thinking..." status from the moment they submit a query until the response arrives, with no indication of which pipeline stage is running.

### Stages to surface

| Stage | Trigger point | User-facing text |
|-------|---------------|------------------|
| `capturing` | Before `captureAllScreens()` | "Reading screen..." |
| `querying` | Before `ai.query()` | "Analyzing..." |
| `refining` | Before `Promise.all` refinement | "Refining points..." |
| `speaking` | Before `tts.speak()` | "Speaking..." |

## Tasks

- [x] **1. Emit `companion:stage` IPC events in `companion.ts`**
  - File: `src/main/companion.ts`
  - Before each pipeline stage, send `companion:stage` to all BrowserWindows:
    ```ts
    private broadcastStage(stage: string, label: string) {
      for (const win of BrowserWindow.getAllWindows()) {
        win.webContents.send("companion:stage", { stage, label });
      }
    }
    ```
  - Call sites:
    - Line ~63 (before `captureAllScreens`): `capturing` / `"Reading screen..."`
    - Line ~70 (before `ai.query`): `querying` / `"Analyzing..."`
    - Line ~94 (before refinement block): `refining` / `"Refining points..."`  
      — only emit if `rawTags.length > 0`
    - Line ~172 (before TTS): `speaking` / `"Speaking..."`
    - Line ~188 (end of processQuery): `done` / `""`

- [x] **2. Expose `onStage` listener in preload bridge**
  - File: `src/preload/index.ts`
  - Add alongside existing `onRecordingChanged`, `onTranscript`, etc.:
    ```ts
    onStage: (cb: (data: { stage: string; label: string }) => void) =>
      ipcRenderer.on("companion:stage", (_e, data) => cb(data)),
    ```

- [x] **3. Update chat window to consume stage events**
  - File: `src/renderer/chat/index.html`
  - Replace static `showStatus('Thinking...', 'thinking')` at query dispatch with dynamic stage updates:
    ```js
    window.clicky.onStage(({ stage, label }) => {
      if (stage === 'done') {
        hideStatus();
      } else {
        showStatus(label, stage === 'speaking' ? 'speaking' : 'thinking');
      }
    });
    ```
  - Remove the `showStatus('Thinking...', 'thinking')` call at line ~1181 (text query) and line ~1302 area (voice path) — stage events now drive all status text.
  - `hideStatus()` at response-received lines stays as a fallback for non-stage-emitting paths.

- [x] **4. Add processing indicator to overlay**
  - File: `src/renderer/overlay/index.html`
  - Add a `#processing-indicator` element styled like `#recording-indicator` but distinct:
    - Position: top-left (recording-indicator is top-right)
    - Color: blue accent (recording-indicator is red)
    - Text driven by stage label
  - CSS pattern mirrors existing `.recording-indicator` block (lines 103-140)
  - JS: listen for `companion:stage`, show/hide and update text:
    ```js
    window.clicky.onStage(({ stage, label }) => {
      if (stage === 'done' || stage === 'speaking') {
        processingIndicator.classList.remove('active');
      } else {
        processingIndicator.querySelector('.indicator-text').textContent = label;
        processingIndicator.classList.add('active');
      }
    });
    ```
  - Hide indicator when recording-indicator is active (don't show both at once).

- [x] **5. Compile and smoke test**
  - `npx tsc` — zero errors
  - Text query: verify status bar cycles `Reading screen...` → `Analyzing...` → (optionally `Refining points...` if POINT tags present) → clears
  - Voice query: verify overlay `processing-indicator` appears after recording stops, cycles through stages, disappears when response is rendered
  - No POINT tags path: `Refining points...` stage must NOT appear
  - TTS disabled: `Speaking...` stage must NOT appear

## Files Affected

| File | Change |
|------|--------|
| `src/main/companion.ts` | Add `broadcastStage()` + 5 call sites |
| `src/preload/index.ts` | Expose `onStage` on contextBridge |
| `src/renderer/chat/index.html` | Replace static status text with stage-event handler |
| `src/renderer/overlay/index.html` | Add `#processing-indicator` HTML + CSS + stage-event handler |

## Risks

- **Refinement stage flicker**: If refinement is very fast (<200ms) the "Refining points..." label flashes and disappears. Acceptable — no debounce needed.
- **Multiple windows on multi-monitor**: `broadcastStage` sends to all windows. Overlay windows on non-primary displays will also receive events — correct behavior since companion already routes POINT tags per-screen.
- **Race on done**: If `processQuery` throws before emitting `done`, status bar stays stuck. Wrap the `broadcastStage('done')` call in a `finally` block.

## Notes

- `speaking` stage is excluded from the overlay indicator because TTS runs non-blocking and the overlay may already be animating cursor POINT tags at that moment — showing both would conflict visually.
- No new dependencies required — all plumbing uses existing Electron IPC patterns.
- `onStage` listener is additive; existing `onRecordingChanged`, `onTranscript` etc. are untouched.

## Completion Summary

Implemented 2026-04-23. Four files changed: `companion.ts` adds `broadcastStage()` with call sites at capturing/querying/refining/speaking/done (always in `finally`); `preload/index.ts` exposes `onStage`; chat renderer drops static "Thinking..." and drives status bar from stage events; overlay gains `#processing-indicator` (top-left, blue) that cycles through stage labels and hides on `done`/`speaking`. `npx tsc` clean.

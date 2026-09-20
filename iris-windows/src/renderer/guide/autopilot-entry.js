/**
 * autopilot-entry.js
 *
 * Adds the "Let Iris run it" entry point the guide panel does not have.
 * `app.js`'s own header says so directly: "This panel is not the autopilot:
 * nobody's shell is being driven... this panel never reaches the autopilot
 * runner (there is no takeover from here)." That is deliberate — app.js is a
 * byte-for-byte transplant of `iris-desktop/ui/app.js` and CLAUDE.md forbids
 * rewriting it to add Windows-only behaviour, the same reason iris-bridge.js
 * exists as a separate file rather than a fork of app.js.
 *
 * So this reads app.js from the OUTSIDE instead, through the one surface it
 * already exposes for exactly that purpose: the frozen `window.__IRIS__`
 * object (`getState()`). There is no event for "a guide finished loading" to
 * hook into — app.js re-renders by toggling `hidden` on whichever of
 * `#loading-state`/`#guide-state`/`#error-state`/`#review-state`/
 * `#complete-state` is current — so a `MutationObserver` on exactly those
 * five elements' own `hidden` attribute (NOT their subtree) reacts the moment
 * app.js does, instead of a poll that would either lag behind a real state
 * change or hammer `autopilot_can_install` on a tight timer. `subtree: true`
 * on a shared ancestor was the first attempt, and it is a trap: this
 * button lives inside `#guide-state`, so `refresh()` setting `button.hidden`
 * would itself be an observed mutation, re-triggering `refresh()`
 * synchronously forever — a self-feeding microtask loop that pegs the CPU
 * and never yields, since it never reaches a real timer or I/O. Observing
 * the five section elements directly (no subtree) watches exactly the
 * signal that matters and excludes the button by construction. A slow
 * interval stays underneath as a backstop only, in case some future render
 * path changes state without touching one of these five elements.
 *
 * Mirrors iris-macos's guide-bar button (`OverlayEyeInputBar.swift`,
 * `Button("Let Iris run it", action: { guideSessionController.startAutopilot() })`):
 * offered whenever the current guide's Windows branch has a derivable
 * autopilot recipe (`autopilot_can_install`), wired to opening the autopilot
 * window for that same slug (`autopilot_open`) — both already handled by
 * `handleGuideCommand` in `main/index.ts`; nothing in this app's IPC surface
 * needed to change for the button to reach them.
 */
(function installAutopilotEntry() {
  const button = document.getElementById("autopilot-button");
  if (!button) return; // index.html always has it; defensive only.

  const BACKSTOP_POLL_INTERVAL_MS = 3000;
  // The last slug:platform actually asked about, and what it answered — NOT
  // just "already asked, never mind". A reload of the very same guide (the
  // reader's own reloadGuide/openGuide, or a fresh version fetch) transits
  // guideStatus through null while it refetches, which hides the button; if
  // a matching key only meant "skip", that hide would never be undone, since
  // nothing would re-run the invoke that used to be the sole path back to
  // `button.hidden = false`. Re-applying the cached answer on every matching
  // key is what actually fixes that, and it's cheap — no repeat IPC call.
  let lastCheckedKey = null;
  let lastAnswer = false;

  function invoke(command, args) {
    // Same shape iris-bridge.js gives app.js. Absent in a browser preview or
    // a shell that predates this file — the button just never appears there.
    if (!window.__TAURI__) return Promise.reject(new Error("no native bridge"));
    return window.__TAURI__.core.invoke(command, args ?? {});
  }

  async function refresh() {
    const iris = window.__IRIS__;
    if (!iris) return;

    const state = iris.getState();
    // Only ever offer it once a guide has actually finished loading and is
    // showing a step — not while loading, erroring, reviewing, or complete.
    if (!state.slug || !state.guideStatus || state.completed) {
      button.hidden = true;
      return;
    }

    const key = state.slug + ":" + state.platform;
    if (key === lastCheckedKey) {
      button.hidden = !lastAnswer;
      return;
    }
    lastCheckedKey = key;

    try {
      const canInstall = await invoke("autopilot_can_install", { slug: state.slug });
      // A slug switch mid-flight (the reader picked a different app while this
      // was in flight) means the answer is for a guide that is no longer
      // showing; only the latest key's answer should reach the button.
      if (key === lastCheckedKey) {
        lastAnswer = canInstall;
        button.hidden = !canInstall;
      }
    } catch {
      if (key === lastCheckedKey) {
        lastAnswer = false;
        button.hidden = true;
      }
    }
  }

  button.addEventListener("click", async () => {
    const state = window.__IRIS__ && window.__IRIS__.getState();
    if (!state || !state.slug) return;
    button.disabled = true;
    try {
      await invoke("autopilot_open", { slug: state.slug });
    } catch {
      // Nothing to show here beyond leaving the button clickable again — the
      // autopilot window itself is where a real failure would surface.
    } finally {
      button.disabled = false;
    }
  });

  const observer = new MutationObserver(refresh);
  const STATE_SECTION_IDS = [
    "loading-state",
    "guide-state",
    "error-state",
    "review-state",
    "complete-state",
  ];
  for (const id of STATE_SECTION_IDS) {
    const section = document.getElementById(id);
    // No `subtree`: this must watch only these five elements' own `hidden`
    // attribute, never their descendants' — the button is one.
    if (section) observer.observe(section, { attributes: true, attributeFilter: ["hidden"] });
  }

  setInterval(refresh, BACKSTOP_POLL_INTERVAL_MS);
  refresh();
})();

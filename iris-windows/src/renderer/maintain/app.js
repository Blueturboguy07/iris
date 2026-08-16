// Maintain mode's ask card — the Windows port of MaintainAskCard.swift.
//
// A pure display over `MaintainIncidentSnapshot` (see
// services/maintain/incident-coordinator.ts): it renders the pending ask
// (if any), then the post-answer fix-status line (if any), and nothing at
// all otherwise. The window itself is shown/hidden by main/index.ts based on
// the same emptiness check — this file's job is only to draw what's inside
// it and to report its own measured height back so the window can be sized
// to fit (main/index.ts's `maintainCardRect`, the Windows answer to Swift's
// `clickyResizePanelToContent`).

(() => {
  "use strict";

  const iris = window.iris;

  const shell = document.getElementById("shell");
  const askCard = document.getElementById("ask-card");
  const askTitle = document.getElementById("ask-title");
  const askEvidence = document.getElementById("ask-evidence");
  const askKnownFix = document.getElementById("ask-known-fix");
  const askYes = document.getElementById("ask-yes");
  const askNo = document.getElementById("ask-no");
  const askDontAsk = document.getElementById("ask-dont-ask");

  const fixCard = document.getElementById("fix-card");
  const fixStatus = document.getElementById("fix-status");
  const fixSteps = document.getElementById("fix-steps");
  const fixDone = document.getElementById("fix-done");

  if (!iris || typeof iris.onMaintainSnapshot !== "function") {
    console.error("[iris maintain] window.iris bridge is not available in this window.");
    return;
  }

  // Rendering an ask needs the app's own name, which the snapshot's
  // `pendingAsk.appName` already carries — nothing here fetches it
  // separately, matching Swift's card (`ask.appName`, not a lookup).
  function renderAsk(pendingAsk, recipesForPendingAsk) {
    if (pendingAsk === null) {
      askCard.hidden = true;
      return;
    }
    askCard.hidden = false;
    askTitle.textContent = `Something wrong with ${pendingAsk.appName}?`;
    askEvidence.textContent = pendingAsk.evidenceSentence;
    askKnownFix.hidden = !(Array.isArray(recipesForPendingAsk) && recipesForPendingAsk.length > 0);
    askDontAsk.title = `Never ask about ${pendingAsk.appName} again — reversible in settings.`;
  }

  function renderFixStatus(pendingAsk, fixStatusLine, fixGuidanceSteps) {
    // The fix-status card is the post-answer surface — it only ever shows
    // once the ask itself is gone, exactly like Swift's
    // `coordinator.pendingAsk == nil, let statusLine = coordinator.fixStatusLine`.
    if (pendingAsk !== null || !fixStatusLine) {
      fixCard.hidden = true;
      return;
    }
    fixCard.hidden = false;
    fixStatus.textContent = fixStatusLine;

    const steps = Array.isArray(fixGuidanceSteps) ? fixGuidanceSteps : [];
    fixSteps.replaceChildren();
    if (steps.length > 0) {
      for (const step of steps) {
        const item = document.createElement("li");
        item.textContent = step;
        fixSteps.appendChild(item);
      }
      fixSteps.hidden = false;
    } else {
      fixSteps.hidden = true;
    }
  }

  function reportMeasuredHeight() {
    // One frame so layout has actually settled (hidden→visible toggles,
    // text reflow) before measuring — an immediate `scrollHeight` read can
    // catch the card mid-layout and undersize the window by a line.
    requestAnimationFrame(() => {
      const height = shell.getBoundingClientRect().height;
      if (typeof iris.resizeMaintainCard === "function") {
        void iris.resizeMaintainCard(height);
      }
    });
  }

  function render(snapshot) {
    const pendingAsk = snapshot && snapshot.pendingAsk ? snapshot.pendingAsk : null;
    const recipesForPendingAsk = snapshot ? snapshot.recipesForPendingAsk : [];
    const fixStatusLine = snapshot ? snapshot.fixStatusLine : null;
    const fixGuidanceSteps = snapshot ? snapshot.fixGuidanceSteps : [];

    renderAsk(pendingAsk, recipesForPendingAsk);
    renderFixStatus(pendingAsk, fixStatusLine, fixGuidanceSteps);
    reportMeasuredHeight();
  }

  askYes.addEventListener("click", () => void iris.answerMaintainAsk("somethingIsBroken"));
  askNo.addEventListener("click", () => void iris.answerMaintainAsk("thatWasMe"));
  askDontAsk.addEventListener("click", () => void iris.answerMaintainAsk("neverAskAboutThisApp"));
  fixDone.addEventListener("click", () => void iris.clearMaintainFixStatus());

  iris.onMaintainSnapshot((snapshot) => render(snapshot));
  // The window can appear after the coordinator already raised an ask (a
  // relaunch mid-ask is not a real scenario today, but a freshly-created
  // window always pulls once so it never opens blank while waiting for the
  // next push).
  void iris.getMaintainSnapshot().then((snapshot) => render(snapshot));
})();

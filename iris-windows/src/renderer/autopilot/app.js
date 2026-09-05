// The animated autopilot terminal.
//
// It is a *display*: the runner in the main process does the real work and streams
// what it did on `autopilot:event`. This renders those events at a deliberate pace
// — typing each command out, holding the "running" cursor a beat, pausing between
// steps — so a fast install still reads as real work, exactly like the macOS
// autopilot. Nothing here slows the actual shell; the commands already ran.
//
// Reader steps (a sign-in, a permission) and sensitive-command confirms raise the
// "your turn" tray with a button that resumes the install. No per-step clicking:
// command and open steps advance themselves.

(() => {
  "use strict";

  const native = window.irisNative;
  const stage = document.getElementById("stage");
  const scrollback = document.getElementById("scrollback");
  const tray = document.getElementById("tray");
  const trayText = document.getElementById("tray-text");
  const trayButtons = document.getElementById("tray-buttons");
  const titleEl = document.getElementById("title");

  const MIN_COMMAND_VISIBLE_MS = 1500; // a command reads as work for at least this long
  const BETWEEN_STEPS_MS = 700; // a deliberate breath between steps
  const TYPE_MS_PER_CHUNK = 18;

  const slug = new URLSearchParams(window.location.search).get("slug") || "";

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const scrollToBottom = () => {
    scrollback.scrollTop = scrollback.scrollHeight;
  };

  function addLine(text, className) {
    const line = document.createElement("div");
    line.className = `line ${className || ""}`.trim();
    line.textContent = text;
    scrollback.appendChild(line);
    scrollToBottom();
    return line;
  }

  // The plain-English lead line above a command, with a spinner that turns while
  // the command runs — the "Iris is working right now" signal for a reader who
  // does not read raw output. `stopRunningFriendlyLine` removes the spinner when
  // the command finishes (or the step is handed back / surfaced).
  function addFriendlyLine(label) {
    const line = document.createElement("div");
    line.className = "line friendly running";
    const spin = document.createElement("span");
    spin.className = "spin";
    spin.textContent = "◐";
    const text = document.createElement("span");
    text.textContent = label;
    line.append(spin, text);
    scrollback.appendChild(line);
    scrollToBottom();
    return line;
  }

  // A command line: a coloured prompt, then the command typed out, then a
  // blinking cursor that stays until the command finishes.
  async function typeCommandLine(text) {
    const line = document.createElement("div");
    line.className = "line command";
    const prompt = document.createElement("span");
    prompt.className = "prompt";
    prompt.textContent = "%";
    const body = document.createElement("span");
    const cursor = document.createElement("span");
    cursor.className = "cursor";
    line.append(prompt, body, cursor);
    scrollback.appendChild(line);
    scrollToBottom();

    const chunks = Math.min(text.length, 80);
    const size = Math.ceil(text.length / Math.max(chunks, 1));
    for (let i = 0; i < text.length; i += size) {
      body.textContent += text.slice(i, i + size);
      scrollToBottom();
      await sleep(TYPE_MS_PER_CHUNK);
    }
    return cursor; // caller removes it when the command finishes
  }

  function hideTray() {
    tray.classList.add("hidden");
    trayButtons.replaceChildren();
  }

  function showTray(instruction, buttons, { eye } = {}) {
    trayText.innerHTML = "";
    if (eye) {
      const mark = document.createElement("span");
      mark.className = "eye";
      mark.textContent = "◉";
      trayText.appendChild(mark);
    }
    trayText.appendChild(document.createTextNode(instruction));
    trayButtons.replaceChildren();
    for (const spec of buttons) {
      const button = document.createElement("button");
      button.textContent = spec.label;
      if (spec.primary) button.classList.add("primary");
      button.addEventListener("click", () => {
        hideTray();
        spec.onClick();
      });
      trayButtons.appendChild(button);
    }
    tray.classList.remove("hidden");
    scrollToBottom();
  }

  // ── The paced render queue ────────────────────────────────────────────────
  // Events arrive as fast as the runner produces them; we render them slowly.

  const queue = [];
  let draining = false;
  let runningCursor = null;
  let runningFriendlyLine = null;
  let commandShownAt = 0;

  function stopRunningFriendlyLine() {
    if (runningFriendlyLine) {
      runningFriendlyLine.classList.remove("running");
      const spin = runningFriendlyLine.querySelector(".spin");
      if (spin) spin.remove();
      runningFriendlyLine = null;
    }
  }

  function enqueue(event) {
    queue.push(event);
    void drain();
  }

  async function drain() {
    if (draining) return;
    draining = true;
    while (queue.length > 0) {
      await renderEvent(queue.shift());
    }
    draining = false;
  }

  async function renderEvent(event) {
    switch (event.type) {
      case "stepStarted":
        addLine(`→ ${event.title}   (${event.index + 1}/${event.total})`, "step");
        await sleep(180);
        break;

      case "commandStarted":
        runningFriendlyLine = addFriendlyLine(event.friendlyLabel || event.text);
        runningCursor = await typeCommandLine(event.text);
        commandShownAt = Date.now();
        break;

      case "commandFinished": {
        const elapsed = Date.now() - commandShownAt;
        if (elapsed < MIN_COMMAND_VISIBLE_MS) await sleep(MIN_COMMAND_VISIBLE_MS - elapsed);
        if (runningCursor) {
          runningCursor.remove();
          runningCursor = null;
        }
        stopRunningFriendlyLine();
        const trimmed = (event.output || "").trim();
        if (trimmed) addLine(trimmed, "output");
        if (event.exitCode === 0) addLine("✓ done", "exit-ok");
        else addLine(`✗ exited ${event.exitCode}`, "exit-fail");
        await sleep(BETWEEN_STEPS_MS);
        break;
      }

      case "openRequested":
        addLine(`opening ${event.href} …`, "info");
        break;

      case "handedToReader":
        if (runningCursor) {
          runningCursor.remove();
          runningCursor = null;
        }
        stopRunningFriendlyLine();
        showTray(
          event.instruction,
          [{ label: "I did it — carry on", primary: true, onClick: () => resume("autopilot_reader_done") }],
          { eye: true },
        );
        break;

      case "needsConfirm":
        showTray(`Iris wants to run:  ${event.command}\n${event.reason}`, [
          { label: "Run it", primary: true, onClick: () => resume("autopilot_confirm", { approved: true }) },
          { label: "Skip", onClick: () => resume("autopilot_confirm", { approved: false }) },
        ]);
        break;

      case "fixProposed":
        // The fix ladder's plain-English line — what the model diagnosed or what
        // Iris is about to try — shown between the failing command and its retry.
        stopRunningFriendlyLine();
        addLine(`◐ ${event.diagnosis}`, "fix");
        await sleep(180);
        break;

      case "surfaced":
        if (runningCursor) {
          runningCursor.remove();
          runningCursor = null;
        }
        stopRunningFriendlyLine();
        addLine(`⚠ ${event.reason}`, "info");
        if (event.failingCommand) addLine(event.failingCommand, "output");
        // The "Your turn" row, mirroring the macOS surface: Iris tried to repair
        // this and couldn't, so the reader chooses — re-run the same step, or
        // skip it and carry on with the rest of the install.
        showTray(
          "Iris couldn't finish this one on its own — take it from here.",
          [
            { label: "Try again", primary: true, onClick: () => resume("autopilot_retry") },
            { label: "Continue past it", onClick: () => resume("autopilot_continue_past") },
          ],
          { eye: true },
        );
        break;

      case "finished":
        addLine("✓ All done. Opening it now.", "done");
        // Let the reader see "done", then morph back into the eye and close.
        setTimeout(() => void native.invoke("autopilot_collapse", {}), 1800);
        break;

      default:
        break;
    }
    scrollToBottom();
  }

  // Resume the runner after a reader action; new events stream back in.
  async function resume(command, args) {
    try {
      await native.invoke(command, args || {});
    } catch (error) {
      addLine(`Iris hit a problem: ${String(error && error.message ? error.message : error)}`, "info");
    }
  }

  let installStarted = false;
  async function beginInstall() {
    if (installStarted) return;
    installStarted = true;
    try {
      await native.invoke("autopilot_start", { slug });
    } catch (error) {
      addLine(`Iris can't install this: ${String(error && error.message ? error.message : error)}`, "info");
    }
  }

  function start() {
    if (!native || typeof native.invoke !== "function") {
      stage.classList.add("as-terminal");
      addLine("Iris's bridge isn't available in this window.", "info");
      return;
    }
    if (slug) titleEl.textContent = `iris — installing ${slug}`;
    native.listen("autopilot:event", (event) => enqueue(event));
    // The window opens as the eye; the main process sends "terminal" once it has
    // glided to centre, and "eye" again when we ask to collapse. The install
    // begins as the terminal appears, so it reads as the eye *becoming* the work.
    native.listen("autopilot:morph", (face) => {
      if (face === "terminal") {
        stage.classList.add("as-terminal");
        setTimeout(() => void beginInstall(), 280);
      } else if (face === "eye") {
        stage.classList.remove("as-terminal");
      }
    });
  }

  start();
})();

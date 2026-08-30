(() => {
  "use strict";

  const $ = (selector) => document.querySelector(selector);

  const elements = {
    eye: $("#iris-eye"),
    guideKicker: $("#guide-kicker"),
    guideTitle: $("#guide-title"),
    guideStatusBadge: $("#guide-status-badge"),
    guideVersionBadge: $("#guide-version-badge"),
    loadingState: $("#loading-state"),
    loadingDetail: $("#loading-detail"),
    errorState: $("#error-state"),
    errorTitle: $("#error-title"),
    errorDetail: $("#error-detail"),
    reviewState: $("#review-state"),
    reviewTitle: $("#review-title"),
    reviewNote: $("#review-note"),
    reviewSourceLink: $("#review-source-link"),
    guideState: $("#guide-state"),
    completeState: $("#complete-state"),
    completeTitle: $("#complete-title"),
    platformSwitch: $("#platform-switch"),
    stepCounter: $("#step-counter"),
    stepCard: $("#step-card"),
    stepTitle: $("#step-title"),
    stepBody: $("#step-body"),
    commandBlock: $("#command-block"),
    commandText: $("#command-text"),
    shellLabel: $("#shell-label"),
    verifyPanel: $("#verify-panel"),
    toolResults: $("#tool-results"),
    successMarker: $("#success-marker"),
    verifierLabel: $("#verifier-label"),
    previousButton: $("#previous-button"),
    nextButton: $("#next-button"),
    restartButton: $("#restart-button"),
    completeTrayButton: $("#complete-tray-button"),
    watchStrip: $("#watch-strip"),
    watchTitle: $("#watch-title"),
    watchDetail: $("#watch-detail"),
    settingsWatchButton: $("#settings-watch-button"),
    settingsPanel: $("#settings-panel"),
    settingsButton: $("#settings-button"),
    settingsCloseButton: $("#settings-close-button"),
    settingsScrim: $("#settings-scrim"),
    footerPlatform: $("#footer-platform"),
    clearProgressButton: $("#clear-progress-button"),
    trayButton: $("#tray-button"),
    quitButton: $("#quit-button"),
    toast: $("#toast"),
    liveRegion: $("#live-region"),
  };

  const STATUS_VALUES = new Set(["pilot", "approved", "review"]);
  const PLATFORM_VALUES = new Set(["macos", "windows"]);
  // Must stay identical to `allowed_external_host` in src-tauri/src/main.rs: a
  // host missing on either side nulls the step link before the other layer is
  // consulted, and the button silently advances instead of opening anything.
  const SAFE_EXTERNAL_HOSTS = new Set([
    "publikhq.com",
    "www.publikhq.com",
    "github.com",
    "docs.github.com",
    "git-scm.com",
    "nodejs.org",
    "python.org",
    "www.python.org",
    "rustup.rs",
    "docker.com",
    "www.docker.com",
    "docs.docker.com",
    "developer.apple.com",
    "learn.microsoft.com",
    "apps.apple.com",
    "developer.android.com",
    "huggingface.co",
    "visualstudio.microsoft.com",
    "cmake.org",
    "www.cmake.org",
    "files.browseros.com",
    "go.dev",
  ]);
  const SAFE_TOOL_NAMES = new Set([
    "git",
    "node",
    "npm",
    "pnpm",
    "bun",
    "python",
    "python3",
    "uv",
    "cargo",
    "rustc",
    "docker",
    "java",
    "adb",
    "xcodebuild",
  ]);
  const STORAGE = {
    apiBase: "iris:api-base",
    lastSlug: "iris:last-slug",
    watching: "iris:watching",
    lastPlatform: "iris:last-platform",
    progressPrefix: "iris:progress:",
  };
  const params = new URLSearchParams(window.location.search);
  const metaApiBase =
    document.querySelector('meta[name="iris-api-base"]')?.getAttribute("content") ||
    "https://publikhq.com";

  const state = {
    apiBase: "",
    slug: "",
    guide: null,
    platform: "macos",
    branch: null,
    requestedVersion: null,
    // Set by an iris:// handoff and consumed once by the next loadGuide().
    resume: null,
    stepIndex: 0,
    completed: false,
    actionReady: false,
    missingTools: [],
    setupTool: null,
    collapsed: false,
    view: "loading",
    watching: localStorage.getItem(STORAGE.watching) !== "false",
    foreground: null,
    terminalNearby: false,
    foregroundTimer: 0,
    fetchController: null,
    toastTimer: 0,
    settingsReturnFocus: null,
    unlisteners: [],
    reducedMotion: window.matchMedia("(prefers-reduced-motion: reduce)").matches,
  };

  const DEMO_GUIDE = {
    appSlug: "cue",
    appName: "cue",
    version: 2,
    status: "pilot",
    sourceOwner: "Blueturboguy07",
    sourceRepo: "cue",
    sourceCommit: "36fa2b41e1c20ea5d4e47bde26e39fcd43db3872",
    outputType: "desktop_app",
    estimatedMinutes: 12,
    reviewNote: "",
    branches: [
      {
        platform: "macos",
        label: "macOS",
        shell: "terminal",
        setupSteps: [
          {
            id: "install-git",
            kind: "terminal",
            tool: "git",
            title: "Install Git",
            body: "Apple opens a small installer.",
            command: "xcode-select --install",
            verifierLabel: "Git responds with a version number",
          },
          {
            id: "install-node",
            kind: "open",
            tool: "node",
            title: "Install Node LTS",
            body: "Choose the macOS Installer (.pkg).",
            href: "https://nodejs.org/en/download",
            actionLabel: "Open download",
            verifierLabel: "Node responds with a version number",
          },
        ],
        steps: [
          {
            id: "open-shell",
            kind: "terminal",
            title: "Open Terminal",
            body: "Keep it open beside Iris.",
            verifierLabel: "Terminal is open",
          },
          {
            id: "check-tools",
            kind: "check",
            title: "Check Git and Node",
            body: "Git and the current Node LTS are required.",
            command: "git --version\nnode --version",
            verifierLabel: "Git and Node respond with version numbers",
          },
          {
            id: "clone",
            kind: "terminal",
            title: "Copy cue to this Mac",
            body: "",
            command: "git clone https://github.com/Blueturboguy07/cue.git",
            verifierLabel: "A cue folder appears",
          },
          {
            id: "run",
            kind: "terminal",
            title: "Run cue",
            body: "Keep Terminal open.",
            command: "cd cue\nnpm ci\nnpm start",
            verifierLabel: "The cue overlay appears",
          },
          {
            id: "finish",
            kind: "verify",
            title: "Move cue to Applications",
            body: "Then open it from Spotlight.",
            verifierLabel: "cue launches from its normal system shortcut",
          },
        ],
      },
      {
        platform: "windows",
        label: "Windows",
        shell: "powershell",
        setupSteps: [
          {
            id: "install-git",
            kind: "open",
            tool: "git",
            title: "Install Git",
            body: "Run the installer, then reopen PowerShell.",
            href: "https://git-scm.com/install/windows",
            actionLabel: "Open installer",
            verifierLabel: "Git responds with a version number",
          },
          {
            id: "install-node",
            kind: "open",
            tool: "node",
            title: "Install Node LTS",
            body: "Run the LTS installer, then reopen PowerShell.",
            href: "https://nodejs.org/en/download",
            actionLabel: "Open download",
            verifierLabel: "Node responds with a version number",
          },
        ],
        steps: [
          {
            id: "open-shell",
            kind: "terminal",
            title: "Open PowerShell",
            body: "Keep it open beside Iris.",
            verifierLabel: "PowerShell is open",
          },
          {
            id: "check-tools",
            kind: "check",
            title: "Check Git and Node",
            body: "Git and the current Node LTS are required.",
            command: "git --version\nnode --version",
            verifierLabel: "Git and Node respond with version numbers",
          },
          {
            id: "clone",
            kind: "terminal",
            title: "Copy cue to this PC",
            body: "",
            command: "git clone https://github.com/Blueturboguy07/cue.git",
            verifierLabel: "A cue folder appears",
          },
          {
            id: "run",
            kind: "terminal",
            title: "Run cue",
            body: "Keep PowerShell open.",
            command: "cd cue\nnpm ci\nnpm start",
            verifierLabel: "The cue overlay appears",
          },
          {
            id: "finish",
            kind: "verify",
            title: "Install cue",
            body: "Then open it from Start.",
            verifierLabel: "cue launches from the Start menu",
          },
        ],
      },
    ],
  };

  function tauri() {
    return window.__TAURI__ || null;
  }

  function nativeInvoke(command, args = {}) {
    const bridge = tauri();
    const invoke = bridge?.core?.invoke || bridge?.invoke;
    if (typeof invoke !== "function") {
      return Promise.reject(new Error("Iris native bridge is unavailable"));
    }
    return invoke(command, args);
  }

  async function nativeListen(eventName, handler) {
    const listen = tauri()?.event?.listen;
    if (typeof listen !== "function") return null;
    return listen(eventName, handler);
  }

  function currentNativeWindow() {
    const bridge = tauri();
    return (
      bridge?.window?.getCurrentWindow?.() ||
      bridge?.webviewWindow?.getCurrentWebviewWindow?.() ||
      null
    );
  }

  let resizeTimer = 0;

  function targetPresetForView() {
    if (elements.settingsPanel?.getAttribute("aria-hidden") === "false") return "menu";
    if (state.collapsed) return "collapsed";
    if (state.view === "loading") return "collapsed";
    if (state.view === "error" || state.view === "complete") return "compact";
    if (state.view === "review") return "compact";
    if (state.view === "guide") {
      const step = currentStep();
      if (state.actionReady && step?.kind !== "check" && (step?.command || step?.href)) {
        return "collapsed";
      }
      if (step?.kind === "check") {
        return elements.verifyPanel.hidden ? "step" : "command";
      }
      return step?.command ? "command" : "step";
    }
    return "compact";
  }

  function resizeForCurrentView() {
    window.clearTimeout(resizeTimer);
    resizeTimer = window.setTimeout(() => {
      nativeInvoke("resize_iris", { preset: targetPresetForView() }).catch(() => {
        // Older shells keep their configured window size.
      });
    }, 30);
  }

  function normalizeApiBase(value) {
    try {
      const url = new URL(String(value || "").trim());
      const hostname = url.hostname.toLowerCase();
      const isPublik =
        url.protocol === "https:" &&
        (hostname === "publikhq.com" || hostname === "www.publikhq.com");
      const isLocal =
        ["http:", "https:"].includes(url.protocol) &&
        (hostname === "localhost" || hostname === "127.0.0.1");
      if (!isPublik && !isLocal) return null;
      url.pathname = "";
      url.hash = "";
      url.search = "";
      return url.toString().replace(/\/+$/, "");
    } catch {
      return null;
    }
  }

  function resolveApiBase() {
    const queryBase = normalizeApiBase(params.get("apiBase"));
    const runtimeBase = normalizeApiBase(window.__IRIS_CONFIG__?.apiBase);
    const storedBase = normalizeApiBase(localStorage.getItem(STORAGE.apiBase));
    const localPageBase =
      ["localhost", "127.0.0.1"].includes(window.location.hostname) &&
      /^https?:$/.test(window.location.protocol)
        ? normalizeApiBase(window.location.origin)
        : null;
    const resolved =
      queryBase || runtimeBase || storedBase || localPageBase || normalizeApiBase(metaApiBase);
    if (queryBase) localStorage.setItem(STORAGE.apiBase, queryBase);
    return resolved || "https://publikhq.com";
  }

  function normalizeSlug(value) {
    const slug = String(value || "")
      .trim()
      .toLowerCase();
    return /^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/.test(slug) ? slug : null;
  }

  function detectPlatform() {
    const stored = localStorage.getItem(STORAGE.lastPlatform);
    if (PLATFORM_VALUES.has(stored)) return stored;
    return /windows/i.test(navigator.userAgent) ? "windows" : "macos";
  }

  function labelForPlatform(platform) {
    return platform === "windows" ? "Windows" : "macOS";
  }

  function sanitizeExternalUrl(value) {
    try {
      const url = new URL(String(value || ""));
      const hostname = url.hostname.toLowerCase();
      const isAllowlistedHttps =
        url.protocol === "https:" && SAFE_EXTERNAL_HOSTS.has(hostname);
      const isLocal =
        ["http:", "https:"].includes(url.protocol) &&
        (hostname === "localhost" || hostname === "127.0.0.1");
      if (!isAllowlistedHttps && !isLocal) return null;
      if (url.username || url.password) return null;
      return url.toString();
    } catch {
      return null;
    }
  }

  /**
   * The host of a step link Iris refuses to open, or null when the step either
   * has no link or has a perfectly good one. Only the host is returned, because
   * naming the host is the entire point: the reader can go there themselves.
   */
  function blockedExternalHost(value) {
    if (typeof value !== "string" || value.trim() === "") return null;
    if (sanitizeExternalUrl(value)) return null;
    try {
      return new URL(value).hostname.toLowerCase() || "that address";
    } catch {
      return "that address";
    }
  }

  function showToast(message) {
    window.clearTimeout(state.toastTimer);
    elements.toast.textContent = message;
    elements.toast.classList.add("is-visible");
    state.toastTimer = window.setTimeout(() => {
      elements.toast.classList.remove("is-visible");
    }, 2200);
  }

  function announce(message) {
    elements.liveRegion.textContent = "";
    window.setTimeout(() => {
      elements.liveRegion.textContent = message;
    }, 20);
  }

  function showMainState(name) {
    const map = {
      loading: elements.loadingState,
      error: elements.errorState,
      review: elements.reviewState,
      guide: elements.guideState,
      complete: elements.completeState,
    };
    Object.values(map).forEach((element) => {
      element.hidden = true;
    });
    if (map[name]) map[name].hidden = false;
    state.view = name;
    resizeForCurrentView();
  }

  function updateIdentity({ name, status, version }) {
    const statusLabel =
      status === "approved"
        ? "Approved"
        : status === "pilot"
          ? "Pilot"
          : status === "review"
            ? "In review"
            : "Loading";
    elements.guideTitle.textContent = name || "Finding your guide…";
    elements.guideStatusBadge.dataset.status = status || "loading";
    elements.guideStatusBadge.lastChild.textContent = ` ${statusLabel}`;
    elements.guideVersionBadge.textContent = version ? `v${version}` : "v—";
    elements.guideKicker.textContent =
      status && name ? `${name} guide` : "Guide";
    document.title = name ? `Iris · ${name}` : "Iris";
  }

  function sanitizeGuideStep(step, index, prefix = "step") {
    return {
      id: String(step.id || `${prefix}-${index + 1}`),
      kind: ["check", "terminal", "open", "permission", "verify"].includes(step.kind)
        ? step.kind
        : "terminal",
      title: String(step.title || `Step ${index + 1}`),
      body: String(step.body || ""),
      tool: ["git", "node"].includes(step.tool) ? step.tool : "",
      command: typeof step.command === "string" ? step.command : "",
      href: sanitizeExternalUrl(step.href),
      // A step that names a host Iris will not open must say so. Dropping the
      // href silently is what turned "Install BrowserOS" into a button that did
      // nothing at all in iris-desktop 0.1.4 — a dead control reads as a broken
      // app, not as a blocked host. `blockedHost` is what the disabled control
      // names.
      blockedHost: blockedExternalHost(step.href),
      actionLabel: typeof step.actionLabel === "string" ? step.actionLabel : "",
      verifierLabel:
        typeof step.verifierLabel === "string" ? step.verifierLabel : "",
      // The folder the guide says this step runs in. Kept, and then actually
      // drawn and copied by `commandToRun` — this panel never reaches the
      // autopilot runner (there is no takeover from here), so if the folder
      // does not end up in the text the reader pastes, it does not exist.
      workingDirectory:
        typeof step.workingDirectory === "string" ? step.workingDirectory : "",
    };
  }

  /**
   * The lines the reader must actually type for a step — the command, with the
   * `cd` that puts them in the folder the guide says the command belongs to.
   *
   * This panel is not the autopilot: nobody's shell is being driven, the reader
   * is pasting into a Terminal/PowerShell window that Iris cannot see. That is
   * precisely why the folder has to be IN the text. Someone who comes back the
   * next day resumes at, say, hickeyfield step 8 — "Build the app",
   * `ui/node_modules/.bin/tauri build --bundles app` — in a brand-new shell
   * sitting in their home folder, because the `cd` that made that path work was
   * three steps and one day ago. They paste, and get
   * `zsh: no such file or directory`, exit 127. Preserving `workingDirectory`
   * through `sanitizeGuideStep` and then never drawing it keeps that bug just as
   * completely as dropping the field did.
   *
   * `cd` rather than `Set-Location`: it is a zsh builtin and a PowerShell alias,
   * so one line is right in both shells this panel hands work to. The folder is
   * pasted exactly as the guide wrote it (`~/hickeyfield`) so the shell — not
   * Iris, which is not the one running it — expands `~`.
   */
  function commandToRun(step) {
    if (!step || !step.command) return "";
    if (!step.workingDirectory) return step.command;
    // Most clone steps are already written `cd ~` and declare `~` as their
    // folder — the declaration records what was already true. Prepending
    // regardless would show `cd ~` twice on every guide's clone step, which
    // reads as a mistake in the guide and costs the folder line its credibility
    // on the steps where it is doing real work. Exact match on the first line
    // only: nothing here guesses whether some other `cd` reaches the same
    // place, because a wrong guess drops the line the fix exists to add.
    if (step.command.split("\n")[0].trim() === `cd ${step.workingDirectory}`) {
      return step.command;
    }
    return `cd ${step.workingDirectory}\n${step.command}`;
  }

  function validateGuide(candidate) {
    const raw = candidate?.guide || candidate;
    if (!raw || typeof raw !== "object") throw new Error("Guide response is empty");
    if (!normalizeSlug(raw.appSlug)) throw new Error("Guide has an invalid app identifier");
    if (typeof raw.appName !== "string" || !raw.appName.trim()) {
      throw new Error("Guide is missing an app name");
    }
    if (!STATUS_VALUES.has(raw.status)) throw new Error("Guide has an unknown review state");
    if (!Number.isInteger(Number(raw.version)) || Number(raw.version) < 1) {
      throw new Error("Guide has an invalid version");
    }
    if (!Array.isArray(raw.branches)) throw new Error("Guide branches are missing");

    const branches = raw.branches
      .filter((branch) => PLATFORM_VALUES.has(branch?.platform) && Array.isArray(branch?.steps))
      .map((branch) => ({
        platform: branch.platform,
        // Mobile guides branch on the computer/phone pair; desktop guides
        // leave target null and behave exactly as before.
        target: branch.target === "ios" || branch.target === "android" ? branch.target : null,
        unsupported: sanitizeUnsupported(branch.unsupported),
        label: String(branch.label || labelForPlatform(branch.platform)),
        shell: branch.shell === "powershell" ? "powershell" : "terminal",
        setupSteps: Array.isArray(branch.setupSteps)
          ? branch.setupSteps
              .filter((step) => step && typeof step === "object")
              .map((step, index) => sanitizeGuideStep(step, index, "setup"))
              .filter((step) => step.tool)
          : [],
        steps: branch.steps
          .filter((step) => step && typeof step === "object")
          .map((step, index) => sanitizeGuideStep(step, index)),
      }));

    return {
      appSlug: normalizeSlug(raw.appSlug),
      appName: raw.appName.trim(),
      version: Number(raw.version),
      status: raw.status,
      sourceOwner: String(raw.sourceOwner || ""),
      sourceRepo: String(raw.sourceRepo || ""),
      sourceCommit: typeof raw.sourceCommit === "string" ? raw.sourceCommit : null,
      estimatedMinutes: Number.isFinite(Number(raw.estimatedMinutes))
        ? Number(raw.estimatedMinutes)
        : null,
      reviewNote: typeof raw.reviewNote === "string" ? raw.reviewNote : "",
      branches,
    };
  }

  function sanitizeUnsupported(raw) {
    if (!raw || typeof raw !== "object") return null;
    const headline = typeof raw.headline === "string" ? raw.headline.trim().slice(0, 120) : "";
    const reason = typeof raw.reason === "string" ? raw.reason.trim().slice(0, 600) : "";
    if (!headline || !reason) return null;
    const alternatives = Array.isArray(raw.alternatives)
      ? raw.alternatives
          .filter((item) => typeof item === "string")
          .map((item) => item.trim().slice(0, 300))
          .filter(Boolean)
          .slice(0, 6)
      : [];
    return { headline, reason, alternatives };
  }

  /** Branch identity for a guide: the computer alone is not enough for mobile. */
  function branchKey(branch) {
    return `${branch.platform}:${branch.target || "desktop"}`;
  }

  function progressKey() {
    if (!state.guide) return "";
    const key = state.branch ? branchKey(state.branch) : state.platform;
    return `${STORAGE.progressPrefix}${state.guide.appSlug}:v${state.guide.version}:${key}`;
  }

  function loadProgress() {
    state.stepIndex = 0;
    state.completed = false;
    const key = progressKey();
    if (!key) return;
    try {
      const saved = JSON.parse(localStorage.getItem(key) || "{}");
      const max = Math.max(0, (state.branch?.steps.length || 1) - 1);
      state.stepIndex = Math.min(Math.max(0, Number(saved.step) || 0), max);
      state.completed = Boolean(saved.completed);
    } catch {
      localStorage.removeItem(key);
    }
  }

  function saveProgress() {
    const key = progressKey();
    if (!key) return;
    localStorage.setItem(
      key,
      JSON.stringify({
        step: state.stepIndex,
        completed: state.completed,
        updatedAt: Date.now(),
      })
    );
  }

  function currentStep() {
    if (!state.branch) return null;
    if (state.setupTool) {
      return (
        state.branch.setupSteps.find((step) => step.tool === state.setupTool) || null
      );
    }
    return state.branch.steps[state.stepIndex] || null;
  }

  function setPlatform(platform, { restore = true, key = null, step = null } = {}) {
    if (!PLATFORM_VALUES.has(platform) || !state.guide) return;
    const nextBranch =
      (key ? state.guide.branches.find((branch) => branchKey(branch) === key) : null) ||
      state.guide.branches.find((branch) => branch.platform === platform) ||
      state.guide.branches[0] ||
      null;
    if (!nextBranch) {
      renderError("No compatible steps", "This guide has no desktop branch to display.");
      return;
    }
    state.platform = nextBranch.platform;
    state.branch = nextBranch;
    state.setupTool = null;
    state.missingTools = [];
    localStorage.setItem(STORAGE.lastPlatform, state.platform);
    if (restore) loadProgress();
    if (Number.isInteger(step)) {
      // A handoff carries the reader's place with it. The website is where they
      // just were, so its position wins over anything this app had stored for
      // the same branch.
      state.stepIndex = Math.min(
        Math.max(0, step),
        Math.max(0, nextBranch.steps.length - 1)
      );
      state.completed = false;
      saveProgress();
    }
    renderPlatformSwitch();
    if (state.completed) {
      renderComplete();
    } else {
      renderStep();
    }
    elements.footerPlatform.textContent = labelForPlatform(state.platform);
  }

  function renderPlatformSwitch() {
    elements.platformSwitch.replaceChildren();
    const activeKey = state.branch ? branchKey(state.branch) : null;
    state.guide.branches.forEach((branch) => {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = branch.label || labelForPlatform(branch.platform);
      button.setAttribute("aria-pressed", String(branchKey(branch) === activeKey));
      button.addEventListener("click", () =>
        setPlatform(branch.platform, { key: branchKey(branch) })
      );
      elements.platformSwitch.append(button);
    });
    elements.platformSwitch.hidden = state.guide.branches.length < 2;
  }

  function extractSafeTools(command) {
    if (!command) return [];
    const found = new Set();
    command.split(/\r?\n/).forEach((line) => {
      const match = line.trim().match(/^([a-zA-Z0-9._+-]+)\s+--version$/);
      if (match && SAFE_TOOL_NAMES.has(match[1].toLowerCase())) {
        found.add(match[1].toLowerCase());
      }
    });
    return Array.from(found);
  }

  function renderToolRows(tools, mode = "idle") {
    elements.toolResults.replaceChildren();
    tools.forEach((tool) => {
      const row = document.createElement("div");
      row.className = "tool-result";
      row.dataset.tool = tool;
      row.dataset.state = mode;

      const mark = document.createElement("span");
      mark.className = "tool-result__mark";
      mark.textContent = mode === "checking" ? "…" : "·";

      const label = document.createElement("span");
      label.textContent = `${tool} · ready to check`;
      row.append(mark, label);
      elements.toolResults.append(row);
    });
  }

  function updatePrimaryAction() {
    const steps = state.branch?.steps || [];
    const step = currentStep();
    if (!step) return;

    // A step whose only action is a link Iris will not open gets a disabled
    // control naming the host, and nothing else. Falling through to "Done" would
    // let the reader mark a step complete that they were never able to perform.
    if (step.blockedHost && !step.command) {
      elements.nextButton.replaceChildren(
        document.createTextNode(`Can’t open ${step.blockedHost}`)
      );
      elements.nextButton.disabled = true;
      elements.nextButton.title = `Iris only opens links on publik's allowed list. This step points at ${step.blockedHost}.`;
      return;
    }
    elements.nextButton.disabled = false;
    elements.nextButton.removeAttribute("title");

    let label;
    if (step.id === "open-shell") {
      label = "I’m there";
    } else if (state.setupTool && state.actionReady) {
      label = "Check again";
    } else if (state.setupTool && step.command) {
      label = "Copy";
    } else if (state.setupTool && step.href) {
      label = step.actionLabel || "Open";
    } else if (step.kind === "check" && state.missingTools.length) {
      const tool = state.missingTools[0];
      label = `Install ${tool === "git" ? "Git" : "Node"}`;
    } else if (state.actionReady) {
      if (step.kind === "check") {
        label = state.stepIndex === steps.length - 1 ? "Finish" : "Continue";
      } else if (step.command) {
        label = "I ran it";
      } else {
        label = state.stepIndex === steps.length - 1 ? "Finish" : "Continue";
      }
    } else if (step.kind === "check" && extractSafeTools(step.command).length) {
      label = elements.verifyPanel.hidden ? "Check tools" : "Check again";
    } else if (step.command) {
      label = "Copy";
    } else if (step.href) {
      label = step.actionLabel || "Open";
    } else {
      label = state.stepIndex === steps.length - 1 ? "Finish" : "Done";
    }

    elements.nextButton.replaceChildren(document.createTextNode(label));
    const arrow = document.createElement("span");
    arrow.setAttribute("aria-hidden", "true");
    arrow.textContent = "→";
    elements.nextButton.append(arrow);
  }

  function showHandoff() {
    const step = currentStep();
    if (step?.command) {
      elements.guideTitle.textContent =
        state.branch.shell === "powershell" ? "Paste in PowerShell" : "Paste in Terminal";
    } else if (state.setupTool) {
      elements.guideTitle.textContent = `Finish installing ${
        state.setupTool === "git" ? "Git" : "Node"
      }`;
    }
    elements.stepCounter.textContent = "Done?";
    elements.stepCounter.disabled = false;
    elements.stepCounter.classList.add("is-action");
    resizeForCurrentView();
  }

  async function handlePrimaryAction() {
    const step = currentStep();
    if (!step || elements.nextButton.disabled) return;
    if (state.setupTool && state.actionReady) {
      state.setupTool = null;
      state.missingTools = [];
      renderStep();
      await verifyCurrentTools();
      return;
    }
    if (step.kind === "check" && state.missingTools.length) {
      const nextTool = state.missingTools[0];
      const setupStep = state.branch?.setupSteps.find((item) => item.tool === nextTool);
      if (!setupStep) {
        showToast(`Open the official ${nextTool === "git" ? "Git" : "Node"} installer.`);
        return;
      }
      state.setupTool = nextTool;
      renderStep();
      return;
    }
    if (state.actionReady) {
      moveStep(1);
      return;
    }

    const tools = step.kind === "check" ? extractSafeTools(step.command) : [];
    if (tools.length) {
      await verifyCurrentTools();
      return;
    }
    if (step.command) {
      await copyCurrentCommand();
      return;
    }
    if (step.href) {
      const opened = await openExternalUrl(step.href);
      if (opened) {
        state.actionReady = true;
        updatePrimaryAction();
        showHandoff();
      }
      return;
    }
    moveStep(1);
  }

  function renderStep() {
    // A pair with no valid install route explains itself instead of falling
    // through to the generic "needs review" error, which would read as a bug.
    if (state.branch?.unsupported) {
      const { headline, reason, alternatives } = state.branch.unsupported;
      const body = alternatives.length
        ? `${reason}\n\nWhat you can do instead:\n${alternatives
            .map((item) => `• ${item}`)
            .join("\n")}`
        : reason;
      renderError(headline, body);
      renderPlatformSwitch();
      return;
    }

    const steps = state.branch?.steps || [];
    const step = currentStep();
    if (!step) {
      renderError("This branch has no steps", "Publik needs to review this platform branch.");
      return;
    }
    state.completed = false;
    state.actionReady = false;
    state.collapsed = false;
    showMainState("guide");
    elements.guideTitle.textContent = state.guide.appName;

    const completedCount = state.stepIndex + 1;
    elements.stepCounter.textContent = state.setupTool
      ? "Setup"
      : `${completedCount} / ${steps.length}`;
    elements.stepCounter.disabled = true;
    elements.stepCounter.classList.remove("is-action");
    elements.reviewSourceLink.hidden = true;

    elements.stepTitle.textContent = step.title;
    const pasteDestination =
      state.branch.shell === "powershell" ? "PowerShell" : "Terminal";
    const stepBody =
      step.command && step.kind !== "check"
        ? `Paste in ${pasteDestination}.`
        : step.body;
    elements.stepBody.textContent = stepBody;
    elements.stepBody.hidden = !stepBody;

    elements.commandBlock.hidden = !step.command || step.kind === "check";
    // The folder line is drawn, not just copied: a reader who reads the block
    // and types it by hand has to see it too.
    elements.commandText.textContent = commandToRun(step);
    elements.shellLabel.textContent =
      state.branch.shell === "powershell" ? "POWERSHELL" : "TERMINAL";

    const tools = step.kind === "check" ? extractSafeTools(step.command) : [];
    elements.verifyPanel.hidden = true;
    renderToolRows(tools);

    elements.successMarker.hidden = !step.verifierLabel;
    elements.verifierLabel.textContent = step.verifierLabel || "";
    elements.previousButton.disabled = Boolean(state.setupTool) || state.stepIndex === 0;
    updatePrimaryAction();

    elements.stepCard.classList.remove("is-entering");
    void elements.stepCard.offsetWidth;
    elements.stepCard.classList.add("is-entering");
    elements.eye.dataset.mood = state.watching ? "watching" : "idle";
    resizeForCurrentView();
    if (!stepUsesShell(step)) {
      state.terminalNearby = false;
      window.setTimeout(() => glideIris("bottom-right"), 80);
    }
    announce(state.setupTool ? `Setup: ${step.title}` : `Step ${completedCount}: ${step.title}`);
  }

  function renderComplete() {
    state.completed = true;
    state.collapsed = false;
    saveProgress();
    showMainState("complete");
    elements.stepCounter.textContent = "Done";
    elements.completeTitle.textContent = `${state.guide.appName} is ready.`;
    elements.eye.dataset.mood = "done";
    announce(`Guide complete for ${state.guide.appName}`);
  }

  function renderReview() {
    state.collapsed = false;
    showMainState("review");
    elements.stepCounter.textContent = "In review";
    elements.stepCounter.disabled = true;
    elements.stepCounter.classList.remove("is-action");
    elements.reviewTitle.textContent = `${state.guide.appName} isn’t ready yet.`;
    elements.reviewNote.textContent = "We’re still checking the install.";
    const sourceUrl = sanitizeExternalUrl(
      `https://github.com/${state.guide.sourceOwner}/${state.guide.sourceRepo}`
    );
    if (sourceUrl) {
      elements.reviewSourceLink.href = sourceUrl;
      elements.reviewSourceLink.hidden = false;
    } else {
      elements.reviewSourceLink.hidden = true;
    }
    elements.eye.dataset.mood = "thinking";
    announce(`${state.guide.appName} guide review is in progress`);
  }

  function renderError(title, detail) {
    state.collapsed = false;
    showMainState("error");
    elements.stepCounter.textContent = "Unavailable";
    elements.stepCounter.disabled = true;
    elements.stepCounter.classList.remove("is-action");
    elements.reviewSourceLink.hidden = true;
    elements.errorTitle.textContent = title;
    elements.errorDetail.textContent = detail;
    elements.eye.dataset.mood = "paused";
    updateIdentity({
      name: state.slug || "Iris",
      status: null,
      version: null,
    });
  }

  async function loadGuide(slug = state.slug) {
    const safeSlug = normalizeSlug(slug);
    if (!safeSlug) {
      renderError("That guide link is invalid", "Open a guide from a Publik app page.");
      return;
    }

    state.slug = safeSlug;
    state.guide = null;
    state.branch = null;
    state.collapsed = false;
    state.fetchController?.abort();
    state.fetchController = new AbortController();
    localStorage.setItem(STORAGE.lastSlug, safeSlug);
    showMainState("loading");
    elements.stepCounter.textContent = "Loading";
    elements.stepCounter.disabled = true;
    elements.stepCounter.classList.remove("is-action");
    elements.loadingDetail.textContent = `Opening ${safeSlug}…`;
    updateIdentity({ name: "Iris", status: null, version: null });
    elements.eye.dataset.mood = "thinking";

    try {
      let payload;
      if (params.get("demo") === "1" && !tauri()) {
        await new Promise((resolve) => window.setTimeout(resolve, state.reducedMotion ? 0 : 280));
        payload = { ...DEMO_GUIDE, appSlug: safeSlug, appName: safeSlug === "cue" ? "cue" : safeSlug };
      } else {
        const versionQuery = state.requestedVersion
          ? `?version=${encodeURIComponent(state.requestedVersion)}`
          : "";
        const response = await fetch(
          `${state.apiBase}/api/iris/guides/${encodeURIComponent(safeSlug)}${versionQuery}`,
          {
            method: "GET",
            headers: { Accept: "application/json" },
            cache: "no-store",
            signal: state.fetchController.signal,
          }
        );
        if (!response.ok) {
          if (response.status === 404) {
            throw new Error("Publik has not published a guide for this app yet.");
          }
          throw new Error(`Guide service returned ${response.status}.`);
        }
        payload = await response.json();
      }

      state.guide = validateGuide(payload);
      if (state.requestedVersion && state.guide.version !== state.requestedVersion) {
        throw new Error(`Guide version ${state.requestedVersion} is no longer available.`);
      }
      state.slug = state.guide.appSlug;
      updateIdentity({
        name: state.guide.appName,
        status: state.guide.status,
        version: state.guide.version,
      });
      if (state.guide.status === "review") {
        renderReview();
        return;
      }
      if (state.guide.branches.length === 0) {
        throw new Error("This guide has no reviewed desktop steps.");
      }
      // A handoff names the exact branch the reader was on. Falling back to the
      // detected platform would drop a "Mac + Android" reader into the iPhone
      // steps, which is a different toolchain from the first command onwards.
      const resume = state.resume;
      state.resume = null;
      const resumeBranch = resume
        ? state.guide.branches.find((branch) => branchKey(branch) === resume.branch)
        : null;
      if (resumeBranch) {
        setPlatform(resumeBranch.platform, {
          key: resume.branch,
          step: resume.step,
        });
      } else {
        const preferred = state.guide.branches.some(
          (branch) => branch.platform === state.platform
        )
          ? state.platform
          : state.guide.branches[0].platform;
        setPlatform(preferred);
      }
    } catch (error) {
      if (error?.name === "AbortError") return;
      renderError(
        "Iris could not load this guide.",
        error instanceof Error ? error.message : "Check the API address and try again."
      );
    }
  }

  async function copyText(value) {
    try {
      await navigator.clipboard.writeText(value);
      return true;
    } catch {
      const textarea = document.createElement("textarea");
      textarea.value = value;
      textarea.setAttribute("readonly", "");
      textarea.style.position = "fixed";
      textarea.style.opacity = "0";
      document.body.append(textarea);
      textarea.select();
      const copied = document.execCommand("copy");
      textarea.remove();
      return copied;
    }
  }

  async function copyCurrentCommand() {
    const step = currentStep();
    if (!step?.command) return false;
    const copied = await copyText(commandToRun(step));
    if (!copied) {
      showToast("Copy failed. Try again.");
      state.actionReady = false;
      updatePrimaryAction();
      return false;
    }
    state.actionReady = true;
    updatePrimaryAction();
    showHandoff();
    showToast(
      state.branch.shell === "powershell"
        ? "Copied — paste in PowerShell."
        : "Copied — paste in Terminal."
    );
    return true;
  }

  function normalizeToolResult(tool, response) {
    if (typeof response === "string") {
      return { tool, state: "ok", detail: response };
    }
    if (!response || typeof response !== "object") {
      return { tool, state: "error", detail: "No result returned" };
    }
    const available =
      response.available ??
      response.ok ??
      response.installed ??
      (typeof response.version === "string" && response.version.length > 0);
    const detail =
      response.version ||
      response.output ||
      response.detail ||
      response.message ||
      (available === false ? "Not installed" : "Installed");
    return {
      tool,
      state: available === true ? "ok" : available === false ? "missing" : "error",
      detail: String(detail),
    };
  }

  function updateToolRow(result) {
    const row = elements.toolResults.querySelector(`[data-tool="${CSS.escape(result.tool)}"]`);
    if (!row) return;
    row.dataset.state = result.state;
    row.querySelector(".tool-result__mark").textContent =
      result.state === "ok" ? "✓" : result.state === "missing" ? "×" : "!";
    row.lastElementChild.textContent = `${result.tool} · ${result.detail}`;
  }

  async function verifyCurrentTools() {
    const step = state.branch?.steps[state.stepIndex];
    const tools = extractSafeTools(step?.command);
    if (!tools.length) return false;
    elements.nextButton.disabled = true;
    elements.nextButton.textContent = "Checking…";
    elements.verifyPanel.hidden = false;
    renderToolRows(tools, "checking");
    resizeForCurrentView();

    const results = await Promise.all(
      tools.map(async (tool) => {
        try {
          const response = await nativeInvoke("check_tool_version", { tool });
          return normalizeToolResult(tool, response);
        } catch (error) {
          return {
            tool,
            state: "error",
            detail: tauri()
              ? error instanceof Error
                ? error.message
                : String(error || "Verification unavailable")
              : "Desktop bridge unavailable in browser preview",
          };
        }
      })
    );
    results.forEach(updateToolRow);
    const allReady = results.every((result) => result.state === "ok");
    state.missingTools = results
      .filter((result) => result.state === "missing")
      .map((result) => result.tool);
    state.actionReady = allReady;
    elements.nextButton.disabled = false;
    updatePrimaryAction();
    if (allReady) {
      showToast("Tools ready");
    } else if (state.missingTools.length) {
      const tool = state.missingTools[0];
      showToast(`${tool === "git" ? "Git" : "Node"} is required`);
    } else {
      showToast("Couldn’t verify a tool. Try again.");
    }
    announce(allReady ? "All checked tools are ready" : "Tool verification needs attention");
    return allReady;
  }

  function moveStep(direction) {
    if (!state.branch) return;
    state.setupTool = null;
    state.missingTools = [];
    const lastIndex = state.branch.steps.length - 1;
    if (direction > 0 && state.stepIndex >= lastIndex) {
      renderComplete();
      return;
    }
    state.stepIndex = Math.min(lastIndex, Math.max(0, state.stepIndex + direction));
    state.completed = false;
    saveProgress();
    renderStep();
    if (!state.reducedMotion) {
      elements.guideState.scrollIntoView({ behavior: "smooth", block: "start" });
    }
  }

  function restartGuide() {
    state.stepIndex = 0;
    state.completed = false;
    state.setupTool = null;
    state.missingTools = [];
    state.collapsed = false;
    saveProgress();
    showMainState("guide");
    renderStep();
    closeSettings();
  }

  function openSettings() {
    state.settingsReturnFocus = document.activeElement;
    elements.settingsPanel.setAttribute("aria-hidden", "false");
    elements.settingsPanel.removeAttribute("inert");
    elements.settingsButton.setAttribute("aria-expanded", "true");
    resizeForCurrentView();
    window.setTimeout(() => elements.settingsCloseButton.focus(), state.reducedMotion ? 0 : 180);
  }

  function closeSettings() {
    elements.settingsPanel.setAttribute("aria-hidden", "true");
    elements.settingsPanel.setAttribute("inert", "");
    elements.settingsButton.setAttribute("aria-expanded", "false");
    resizeForCurrentView();
    state.settingsReturnFocus?.focus?.();
  }

  function normalizeForeground(payload) {
    const raw = payload?.payload ?? payload?.detail ?? payload;
    if (typeof raw === "string") {
      return { name: raw, paused: false, reason: "", managed: null };
    }
    if (!raw || typeof raw !== "object") return null;
    return {
      name: String(
        raw.displayName || raw.name || raw.appName || raw.application || "Foreground app"
      ),
      paused: Boolean(raw.paused || raw.sensitive),
      reason: String(raw.reason || (raw.sensitive ? "Sensitive window" : "")),
      managed:
        typeof raw.managed === "boolean"
          ? raw.managed
          : typeof raw.eligible === "boolean"
            ? raw.eligible
            : null,
    };
  }

  function foregroundIsShell(foreground) {
    const name = String(foreground?.name || "").toLowerCase();
    return [
      "terminal",
      "iterm",
      "warp",
      "powershell",
      "command prompt",
      "cmd.exe",
      "pwsh",
      "alacritty",
      "kitty",
      "wezterm",
    ].some((candidate) => name.includes(candidate));
  }

  function stepUsesShell(step = currentStep()) {
    return Boolean(
      step &&
        (step.id === "open-shell" ||
          step.kind === "terminal" ||
          step.kind === "check" ||
          step.command)
    );
  }

  async function glideIris(anchor) {
    try {
      await nativeInvoke("glide_iris", { anchor });
    } catch {
      // Browser previews and older Iris builds remain stationary.
    }
  }

  function renderWatching() {
    const foreground = state.foreground;
    if (!state.watching) {
      elements.watchStrip.dataset.state = "paused";
      elements.watchTitle.textContent = "Paused";
      elements.watchDetail.textContent = "Nothing is observed.";
      elements.settingsWatchButton.textContent = "Start";
      if (state.guide && !state.completed) elements.eye.dataset.mood = "paused";
      return;
    }

    if (foreground?.paused) {
      elements.watchStrip.dataset.state = "paused";
      elements.watchTitle.textContent = "Privacy pause";
      elements.watchDetail.textContent = foreground.reason || "Sensitive app";
      elements.settingsWatchButton.textContent = "Pause";
      elements.eye.dataset.mood = "paused";
      return;
    }

    elements.watchStrip.dataset.state = "watching";
    elements.watchTitle.textContent = "Watching";
    elements.watchDetail.textContent = foreground?.name
      ? `${foreground.name} · not saved`
      : tauri()
        ? "App name only. Nothing saved."
        : "Available in the desktop app.";
    elements.settingsWatchButton.textContent = "Pause";
    if (!state.completed) elements.eye.dataset.mood = "watching";
  }

  async function pollForeground() {
    if (!state.watching || document.hidden) return;
    try {
      const result = await nativeInvoke("foreground_app_identity");
      state.foreground = normalizeForeground(result);
      renderWatching();
      if (
        stepUsesShell() &&
        foregroundIsShell(state.foreground) &&
        !state.terminalNearby
      ) {
        state.terminalNearby = true;
        glideIris("top-right");
      }
    } catch {
      state.foreground = null;
      renderWatching();
    }
  }

  function scheduleForegroundPolling() {
    window.clearInterval(state.foregroundTimer);
    if (!state.watching) return;
    pollForeground();
    state.foregroundTimer = window.setInterval(pollForeground, 1600);
  }

  async function setWatching(next) {
    state.watching = Boolean(next);
    state.foreground = null;
    localStorage.setItem(STORAGE.watching, String(state.watching));
    renderWatching();
    scheduleForegroundPolling();
    announce(state.watching ? "Iris watching enabled" : "Iris watching paused");
  }

  async function hideToTray() {
    try {
      await nativeInvoke("hide_iris");
      return;
    } catch {
      const nativeWindow = currentNativeWindow();
      if (nativeWindow?.hide) {
        await nativeWindow.hide();
        return;
      }
    }
    showToast("Tray behavior is available in the desktop build.");
  }

  async function quitIris() {
    try {
      await nativeInvoke("quit_iris");
      return;
    } catch {
      try {
        const exit = tauri()?.app?.exit;
        if (typeof exit === "function") {
          await exit(0);
          return;
        }
      } catch {
        // Browser preview falls through to a visible message.
      }
    }
    showToast("Quit is available in the desktop build.");
  }

  /** `computer:phone`, matching branchKey() and the shell's own validation. */
  function normalizeBranchKey(value) {
    return typeof value === "string" && /^(macos|windows):(ios|android|desktop)$/.test(value)
      ? value
      : null;
  }

  /** Step 0 is the first step, so absent and zero must not be conflated. */
  function normalizeStep(value) {
    const step = Number(value);
    return Number.isInteger(step) && step >= 0 && step <= 500 ? step : null;
  }

  function parseDeepLink(input) {
    const raw = input?.payload ?? input?.detail ?? input;
    if (Array.isArray(raw)) return parseDeepLink(raw[0]);
    if (raw && typeof raw === "object") {
      const directSlug = normalizeSlug(raw.slug || raw.appSlug);
      return {
        slug: directSlug,
        platform: PLATFORM_VALUES.has(raw.platform) ? raw.platform : null,
        version:
          Number.isInteger(Number(raw.version)) && Number(raw.version) > 0
            ? Number(raw.version)
            : null,
        branch: normalizeBranchKey(raw.branch),
        step: normalizeStep(raw.step),
      };
    }
    if (typeof raw !== "string") {
      return { slug: null, platform: null, version: null, branch: null, step: null };
    }
    try {
      const url = new URL(raw);
      const parts = url.pathname.split("/").filter(Boolean);
      const slug =
        normalizeSlug(url.searchParams.get("slug")) ||
        normalizeSlug(url.hostname === "guide" ? parts[0] : parts.at(-1)) ||
        normalizeSlug(parts.at(-1));
      const platform = PLATFORM_VALUES.has(url.searchParams.get("platform"))
        ? url.searchParams.get("platform")
        : null;
      const rawVersion = Number(url.searchParams.get("version"));
      const version = Number.isInteger(rawVersion) && rawVersion > 0 ? rawVersion : null;
      return {
        slug,
        platform,
        version,
        branch: normalizeBranchKey(url.searchParams.get("branch")),
        step: normalizeStep(url.searchParams.get("step")),
      };
    } catch {
      return { slug: normalizeSlug(raw), platform: null, version: null, branch: null, step: null };
    }
  }

  async function handleDeepLink(input) {
    const parsed = parseDeepLink(input);
    if (!parsed.slug) {
      showToast("Iris received an invalid guide link.");
      return;
    }
    if (parsed.platform) state.platform = parsed.platform;
    state.requestedVersion = parsed.version;
    // A step without a branch is meaningless — step 6 of which toolchain? —
    // so the pair is only honoured together.
    state.resume = parsed.branch ? { branch: parsed.branch, step: parsed.step } : null;
    await loadGuide(parsed.slug);
    // Say "picked up" only if the branch actually matched. A link built against
    // a guide that has since changed shape should not claim to have resumed.
    const resumed =
      Boolean(parsed.branch) &&
      Boolean(state.branch) &&
      branchKey(state.branch) === parsed.branch;
    showToast(
      resumed
        ? `Picked up ${parsed.slug} where you left off.`
        : `Opened ${parsed.slug} guide.`
    );
  }

  async function openExternalUrl(value) {
    const url = sanitizeExternalUrl(value);
    if (!url) {
      showToast("Iris blocked an invalid link.");
      return false;
    }
    try {
      const openUrl = tauri()?.opener?.openUrl;
      if (typeof openUrl === "function") {
        await openUrl(url);
        return true;
      }
      await nativeInvoke("open_external", { url });
      return true;
    } catch {
      if (tauri()) {
        showToast("Iris blocked this external link.");
        return false;
      }
      window.open(url, "_blank", "noopener,noreferrer");
      return true;
    }
  }

  async function openExternal(event) {
    event.preventDefault();
    return openExternalUrl(event.currentTarget.href);
  }

  async function setupNativeEvents() {
    try {
      const unlisten = await nativeListen("iris-guide-opened", (event) => handleDeepLink(event));
      if (typeof unlisten === "function") state.unlisteners.push(unlisten);
    } catch {
      // Browser preview and older shells use the DOM event fallback below.
    }
    try {
      const unlisten = await nativeListen("iris-deep-link-rejected", () => {
        showToast("Iris blocked an invalid guide link.");
      });
      if (typeof unlisten === "function") state.unlisteners.push(unlisten);
    } catch {
      // Browser preview has no native rejection event.
    }
    window.addEventListener("iris-deep-link", handleDeepLink);
  }

  function clearSavedProgress() {
    Object.keys(localStorage).forEach((key) => {
      if (key.startsWith(STORAGE.progressPrefix)) localStorage.removeItem(key);
    });
    state.stepIndex = 0;
    state.completed = false;
    state.collapsed = false;
    if (state.guide?.status !== "review") renderStep();
    showToast("Saved guide progress cleared.");
  }

  function keepFocusInSettings(event) {
    if (
      event.key !== "Tab" ||
      elements.settingsPanel.getAttribute("aria-hidden") !== "false"
    ) {
      return;
    }
    const focusable = Array.from(
      elements.settingsPanel.querySelectorAll(
        'button:not([disabled]), a[href], input:not([disabled]), summary, [tabindex]:not([tabindex="-1"])'
      )
    ).filter((element) => !element.closest("[hidden]"));
    if (!focusable.length) return;
    const first = focusable[0];
    const last = focusable.at(-1);
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  function bindEvents() {
    $("#retry-button").addEventListener("click", () => loadGuide());
    elements.previousButton.addEventListener("click", () => {
      closeSettings();
      moveStep(-1);
    });
    elements.stepCounter.addEventListener("click", () => {
      if (!elements.stepCounter.disabled && state.actionReady) handlePrimaryAction();
    });
    elements.nextButton.addEventListener("click", handlePrimaryAction);
    elements.restartButton.addEventListener("click", restartGuide);
    elements.completeTrayButton.addEventListener("click", async () => {
      await setWatching(true);
      state.collapsed = true;
      resizeForCurrentView();
    });
    elements.settingsWatchButton.addEventListener("click", () => setWatching(!state.watching));
    elements.settingsButton.addEventListener("click", openSettings);
    elements.settingsCloseButton.addEventListener("click", closeSettings);
    elements.settingsScrim.addEventListener("click", closeSettings);
    elements.clearProgressButton.addEventListener("click", clearSavedProgress);
    elements.trayButton.addEventListener("click", hideToTray);
    elements.quitButton.addEventListener("click", quitIris);
    elements.reviewSourceLink.addEventListener("click", openExternal);

    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && elements.settingsPanel.getAttribute("aria-hidden") === "false") {
        event.preventDefault();
        closeSettings();
        return;
      }
      keepFocusInSettings(event);
    });

    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) pollForeground();
    });

    let pointerFrame = 0;
    document.addEventListener("pointermove", (event) => {
      if (state.reducedMotion || pointerFrame) return;
      pointerFrame = requestAnimationFrame(() => {
        pointerFrame = 0;
        const rect = elements.eye.getBoundingClientRect();
        const x = Math.max(-1.5, Math.min(1.5, (event.clientX - (rect.left + rect.width / 2)) / 90));
        const y = Math.max(-1, Math.min(1, (event.clientY - (rect.top + rect.height / 2)) / 110));
        elements.eye.style.setProperty("--look-x", `${x}px`);
        elements.eye.style.setProperty("--look-y", `${y}px`);
      });
    });

    window.addEventListener("beforeunload", () => {
      window.clearInterval(state.foregroundTimer);
      state.unlisteners.forEach((unlisten) => {
        try {
          unlisten();
        } catch {
          // Nothing to clean up in browser preview.
        }
      });
    });
  }

  async function init() {
    state.apiBase = resolveApiBase();
    state.platform = detectPlatform();
    state.slug =
      normalizeSlug(params.get("slug")) ||
      normalizeSlug(localStorage.getItem(STORAGE.lastSlug)) ||
      "cue";
    const rawVersion = Number(params.get("version"));
    state.requestedVersion =
      Number.isInteger(rawVersion) && rawVersion > 0 ? rawVersion : null;
    elements.footerPlatform.textContent = labelForPlatform(state.platform);
    bindEvents();
    await setupNativeEvents();
    renderWatching();
    scheduleForegroundPolling();
    try {
      const pendingGuide = await nativeInvoke("take_pending_guide");
      if (pendingGuide) {
        await handleDeepLink(pendingGuide);
        return;
      }
    } catch {
      // Browser preview and older shells load the URL/default guide below.
    }
    await loadGuide(state.slug);
  }

  window.__IRIS__ = Object.freeze({
    openGuide: (slug, platform) => handleDeepLink({ slug, platform }),
    handleDeepLink,
    reloadGuide: () => loadGuide(),
    getState: () => ({
      slug: state.slug,
      platform: state.platform,
      guideStatus: state.guide?.status || null,
      stepIndex: state.stepIndex,
      completed: state.completed,
      collapsed: state.collapsed,
      watching: state.watching,
      apiBase: state.apiBase,
    }),
  });

  init();
})();

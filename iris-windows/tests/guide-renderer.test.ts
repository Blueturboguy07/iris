import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";
import { afterEach, describe, expect, it } from "vitest";

/**
 * The guide window, driven for real.
 *
 * Everything else in this suite is pure, because everything else can be. The
 * guide panel cannot: it is 1,600 lines of DOM code loaded into a real window,
 * and the defect this file exists for — `workingDirectory` arriving in the
 * guide JSON, being carefully preserved by `sanitizeGuideStep`, and then never
 * reaching the reader — is invisible to any test that does not look at what the
 * panel actually put on screen and on the clipboard. So this boots the shipped
 * `index.html` and the shipped `app.js` in jsdom, answers the guide fetch with a
 * guide, and reads the rendered DOM. No network: `fetch` is replaced before the
 * panel is asked to load anything.
 *
 * jsdom, not Electron: the panel's only Electron-specific surface is
 * `window.__TAURI__`, which `iris-bridge.js` installs and which is left absent
 * here (the panel's `tauri()` helper already has to answer "no bridge" — that is
 * its browser-preview path). Everything under test — step rendering, the copy
 * payload — is plain DOM.
 */

const GUIDE_DIR = join(__dirname, "..", "src", "renderer", "guide");

/** The exact shape of a hickeyfield step as the guides table now serves it. */
const RESUME_STEP = {
  id: "build",
  kind: "terminal",
  title: "Build the app",
  body: "The first build compiles the whole Rust core.",
  command: "ui/node_modules/.bin/tauri build --bundles app",
  workingDirectory: "~/hickeyfield",
  verifierLabel: "",
};

/** The step before it, which is where the folder used to come from. */
const ENTER_FOLDER_STEP = {
  id: "enter-folder",
  kind: "terminal",
  title: "Open the hickeyfield folder",
  body: "",
  command: "cd hickeyfield",
  workingDirectory: "~",
  verifierLabel: "",
};

/** The clone step, which every guide already writes as `cd ~` + the clone. */
const CLONE_STEP = {
  id: "clone",
  kind: "terminal",
  title: "Copy Hickeyfield to this Mac",
  body: "",
  command: "cd ~\ngit clone https://github.com/Blueturboguy07/hickeyfield.git",
  workingDirectory: "~",
  verifierLabel: "",
};

/** A step with no folder of its own — the shape every published guide had. */
const UNDECLARED_STEP = {
  id: "check-tools",
  kind: "terminal",
  title: "Check your tools",
  body: "",
  command: "git --version",
  verifierLabel: "",
};

function guidePayload(steps: readonly unknown[]): unknown {
  return {
    appSlug: "hickeyfield",
    appName: "Hickeyfield",
    status: "approved",
    version: 4,
    outputType: "desktop_app",
    branches: [
      {
        platform: "windows",
        target: null,
        label: "Windows",
        shell: "powershell",
        setupSteps: [],
        steps,
        unsupported: null,
      },
    ],
  };
}

interface Panel {
  readonly dom: JSDOM;
  /** What the command block shows the reader, verbatim. */
  commandOnScreen(): string;
  /** What the copy button actually put on the clipboard. */
  copy(): Promise<string>;
  /** Move to the next step (the panel's own "I ran it" / "Done" control). */
  advance(): Promise<void>;
}

const openPanels: JSDOM[] = [];

afterEach(() => {
  for (const dom of openPanels.splice(0)) dom.window.close();
});

/** Boots the shipped panel on a guide and waits for its first step to render. */
async function openPanel(steps: readonly unknown[]): Promise<Panel> {
  const html = readFileSync(join(GUIDE_DIR, "index.html"), "utf-8")
    // The stylesheet is irrelevant here and jsdom would try to read it off disk.
    .replace('<link rel="stylesheet" href="./styles.css" />', "");

  const dom = new JSDOM(html, {
    url: "https://localhost/guide.html?slug=hickeyfield&platform=windows",
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });
  openPanels.push(dom);
  const { window } = dom;

  const clipboard: string[] = [];
  Object.defineProperty(window.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (text: string) => void clipboard.push(text) },
  });
  window.matchMedia = (query: string) => ({
    matches: false,
    media: query,
    onchange: null,
    addEventListener() {},
    removeEventListener() {},
    addListener() {},
    removeListener() {},
    dispatchEvent: () => false,
  });
  // jsdom has no layout, so it implements neither of these. Both are pure
  // scrolling/animation polish in the panel, and neither is under test.
  window.Element.prototype.scrollIntoView = () => {};
  window.fetch = async () => ({
    ok: true,
    status: 200,
    json: async () => guidePayload(steps),
  });

  // The panel's own scripts, in the order index.html loads them.
  window.eval(readFileSync(join(GUIDE_DIR, "iris-bridge.js"), "utf-8"));
  window.eval(readFileSync(join(GUIDE_DIR, "app.js"), "utf-8"));

  const iris = window as unknown as { __IRIS__: { reloadGuide(): Promise<void> } };
  await iris.__IRIS__.reloadGuide();

  const nextButton = window.document.querySelector("#next-button")!;
  return {
    dom,
    commandOnScreen: () => window.document.querySelector("#command-text")!.textContent ?? "",
    copy: async () => {
      const before = clipboard.length;
      nextButton.click();
      // The copy path is async (navigator.clipboard). Let its promise settle.
      for (let tick = 0; tick < 20 && clipboard.length === before; tick += 1) {
        await new Promise((resolve) => setTimeout(resolve, 0));
      }
      return clipboard[clipboard.length - 1] ?? "";
    },
    advance: async () => {
      // "Copy", then "I ran it" — the two taps a reader makes per command step.
      nextButton.click();
      await new Promise((resolve) => setTimeout(resolve, 0));
      nextButton.click();
      await new Promise((resolve) => setTimeout(resolve, 0));
    },
  };
}

describe("the guide panel and the folder a step runs in", () => {
  it("shows the reader the folder, not just the command", async () => {
    const panel = await openPanel([RESUME_STEP]);
    // Before the wiring this was the bare build line, and a reader who had just
    // opened a shell was one paste away from exit 127 in their home folder.
    expect(panel.commandOnScreen()).toBe(
      "cd ~/hickeyfield\nui/node_modules/.bin/tauri build --bundles app"
    );
  });

  it("copies the folder along with the command", async () => {
    const panel = await openPanel([RESUME_STEP]);
    expect(await panel.copy()).toBe(
      "cd ~/hickeyfield\nui/node_modules/.bin/tauri build --bundles app"
    );
  });

  it("leaves a step that declares no folder exactly as the guide wrote it", async () => {
    const panel = await openPanel([UNDECLARED_STEP]);
    expect(panel.commandOnScreen()).toBe("git --version");
    expect(await panel.copy()).toBe("git --version");
  });

  it("does not tell the reader to `cd ~` twice on the clone step", async () => {
    const panel = await openPanel([CLONE_STEP]);
    expect(panel.commandOnScreen()).toBe(CLONE_STEP.command);
    expect(await panel.copy()).toBe(CLONE_STEP.command);
  });

  it("keeps the folder on a step reached by resuming, not only on the first one", async () => {
    // The reported case is not step one. It is the reader who comes back and is
    // put back on step N, in a shell that never ran the `cd` in step N-1.
    const panel = await openPanel([ENTER_FOLDER_STEP, RESUME_STEP]);
    expect(panel.commandOnScreen()).toBe("cd ~\ncd hickeyfield");
    await panel.advance();
    expect(panel.commandOnScreen()).toBe(
      "cd ~/hickeyfield\nui/node_modules/.bin/tauri build --bundles app"
    );
    expect(await panel.copy()).toBe(
      "cd ~/hickeyfield\nui/node_modules/.bin/tauri build --bundles app"
    );
  });
});

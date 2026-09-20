import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";
import { afterEach, describe, expect, it } from "vitest";

/**
 * The "Let Iris run it" button (autopilot-entry.js), driven for real.
 *
 * app.js itself deliberately has no autopilot entry point — see its own "This
 * panel is not the autopilot" comment — so autopilot-entry.js reads app.js's
 * frozen `window.__IRIS__` surface from the outside and drives the native
 * bridge iris-bridge.js installs. Nothing here touches app.js; this boots the
 * shipped index.html's full script order (iris-bridge.js, app.js,
 * autopilot-entry.js) in jsdom, the same way tests/guide-renderer.test.ts
 * boots app.js on its own, and answers `window.irisNative.invoke` the way the
 * real preload bridge would.
 */

const GUIDE_DIR = join(__dirname, "..", "src", "renderer", "guide");

const openPanels: JSDOM[] = [];

afterEach(() => {
  for (const dom of openPanels.splice(0)) dom.window.close();
});

interface OpenOptions {
  /** What `autopilot_can_install` should answer for this guide. */
  canInstall: boolean;
  /** Omit `window.irisNative` entirely, simulating a browser-preview shell. */
  withoutNativeBridge?: boolean;
}

async function openPanel(options: OpenOptions) {
  const html = readFileSync(join(GUIDE_DIR, "index.html"), "utf-8").replace(
    '<link rel="stylesheet" href="./styles.css" />',
    ""
  );

  const dom = new JSDOM(html, {
    url: "https://localhost/guide.html?slug=hickeyfield&platform=windows",
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });
  openPanels.push(dom);
  const { window } = dom;

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
  window.Element.prototype.scrollIntoView = () => {};
  window.fetch = async () => ({
    ok: true,
    status: 200,
    json: async () => ({
      appSlug: "hickeyfield",
      appName: "Hickeyfield",
      status: "approved",
      version: 1,
      outputType: "desktop_app",
      branches: [
        {
          platform: "windows",
          target: null,
          label: "Windows",
          shell: "powershell",
          setupSteps: [],
          steps: [
            {
              id: "check-tools",
              kind: "terminal",
              title: "Check your tools",
              body: "",
              command: "git --version",
              verifierLabel: "",
            },
          ],
          unsupported: null,
        },
      ],
    }),
  });

  const autopilotOpenCalls: Array<{ slug: string }> = [];

  if (!options.withoutNativeBridge) {
    Object.defineProperty(window, "irisNative", {
      configurable: true,
      value: {
        invoke: async (command: string, args: Record<string, unknown>) => {
          switch (command) {
            case "take_pending_guide":
              return null; // fall through to the URL's ?slug=, like a browser preview
            case "autopilot_can_install":
              return options.canInstall;
            case "autopilot_open":
              autopilotOpenCalls.push({ slug: String(args.slug) });
              return null;
            default:
              return null;
          }
        },
        listen: () => () => {},
      },
    });
  }

  // The panel's own scripts, in the order index.html loads them.
  window.eval(readFileSync(join(GUIDE_DIR, "iris-bridge.js"), "utf-8"));
  window.eval(readFileSync(join(GUIDE_DIR, "app.js"), "utf-8"));
  window.eval(readFileSync(join(GUIDE_DIR, "autopilot-entry.js"), "utf-8"));

  const iris = window as unknown as { __IRIS__: { reloadGuide(): Promise<void> } };
  await iris.__IRIS__.reloadGuide();

  // autopilot-entry.js's own refresh() is async and not awaited by anything
  // above; give its microtasks room to settle before asserting on the button.
  for (let tick = 0; tick < 20; tick += 1) {
    await new Promise((resolve) => setTimeout(resolve, 0));
  }

  const button = window.document.querySelector("#autopilot-button")!;
  return {
    button,
    click: async () => {
      button.click();
      for (let tick = 0; tick < 20; tick += 1) {
        await new Promise((resolve) => setTimeout(resolve, 0));
      }
    },
    autopilotOpenCalls,
  };
}

describe("the guide panel's autopilot entry point", () => {
  it("stays hidden when the current guide has no derivable autopilot recipe", async () => {
    const panel = await openPanel({ canInstall: false });
    expect(panel.button.disabled).toBeFalsy();
    expect(panel.button.hidden).toBe(true);
  });

  it("shows the button and opens autopilot for the guide's own slug when a recipe exists", async () => {
    const panel = await openPanel({ canInstall: true });
    expect(panel.button.hidden).toBe(false);

    await panel.click();
    expect(panel.autopilotOpenCalls).toEqual([{ slug: "hickeyfield" }]);
  });

  it("never appears in a shell with no native bridge (browser preview)", async () => {
    const panel = await openPanel({ canInstall: true, withoutNativeBridge: true });
    expect(panel.button.hidden).toBe(true);
  });
});

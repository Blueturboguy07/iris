import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";
import { afterEach, describe, expect, it } from "vitest";

/**
 * The settings window, driven for real — the panel that owns the two
 * sign-in buttons this suite had never once clicked before 2026-09-19.
 *
 * `configuredSupabaseProject` (services/account-service.ts) is covered on its
 * own, but that only proves the main process computes the right flag. Nothing
 * proved the renderer actually reads `supabaseConfigured`/`signedIn` off
 * `window.iris.getSettings()` and wires each button to the right provider —
 * a swapped id or an inverted `disabled` condition here would look identical
 * to the reported bug (click, nothing happens) and no non-UI test would ever
 * catch it. So this boots the shipped `settings/index.html` in jsdom with a
 * fake `window.iris` bridge standing in for the preload script, and reads the
 * rendered DOM the way a person looking at the window would.
 *
 * jsdom, not Electron: `window.iris` is the entire preload surface this panel
 * touches (see `src/preload/index.ts`), so faking it is faking the one seam
 * between this file and the main process. No network, no display, no model —
 * deterministic and as fast as the rest of the suite.
 */

const SETTINGS_DIR = join(__dirname, "..", "src", "renderer", "settings");

interface FakeSettings {
  claudeModel?: string;
  alwaysOnTop?: boolean;
  cursorBuddyEnabled?: boolean;
  autopilotAutonomyGranted?: boolean;
  signedIn?: boolean;
  signedInEmail?: string | null;
  supabaseConfigured?: boolean;
  hasAnthropicApiKey?: boolean;
  hasOpenAiApiKey?: boolean;
  secretStorageAvailable?: boolean;
}

const openPanels: JSDOM[] = [];

afterEach(() => {
  for (const dom of openPanels.splice(0)) dom.window.close();
});

/** Boots the shipped settings panel against a fake preload bridge and waits for its first `load()` to settle. */
async function openPanel(settings: FakeSettings) {
  const html = readFileSync(join(SETTINGS_DIR, "index.html"), "utf-8");
  const inlineScript = html.match(/<script>([\s\S]*)<\/script>/)?.[1];
  if (!inlineScript) throw new Error("settings/index.html has no inline <script> to run");
  const htmlWithoutScript = html.replace(/<script>[\s\S]*<\/script>/, "");

  const signInCalls: string[] = [];
  let signOutCalls = 0;

  const dom = new JSDOM(htmlWithoutScript, {
    url: "https://localhost/settings.html",
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });
  openPanels.push(dom);
  const { window } = dom;

  // The entire preload surface this panel touches (src/preload/index.ts),
  // faked the same way `window.__TAURI__` is faked in guide-renderer.test.ts.
  Object.defineProperty(window, "iris", {
    configurable: true,
    value: {
      getSettings: async () => settings,
      setSetting: async () => true,
      signIn: (provider: string) => {
        signInCalls.push(provider);
      },
      signOut: async () => {
        signOutCalls += 1;
      },
      onAccountChanged: () => {},
    },
  });
  window.eval(inlineScript);

  // load() awaits window.iris.getSettings() before touching the DOM; give its
  // microtasks room to settle rather than asserting mid-flight.
  for (let tick = 0; tick < 20; tick += 1) {
    await new Promise((resolve) => setTimeout(resolve, 0));
  }

  return {
    document: window.document,
    signInCalls,
    signOutCallCount: () => signOutCalls,
  };
}

describe("the settings panel's account section", () => {
  it("disables both sign-in buttons and names the reason when the build has no Supabase project configured", async () => {
    // This is the exact bug reported 2026-09-19: a packaged build where
    // configuredSupabaseProject() returned null. The buttons must be visibly
    // disabled with an explanation — not merely inert, which reads to a user
    // as "broken" rather than "unavailable in this build".
    const panel = await openPanel({ signedIn: false, supabaseConfigured: false });

    const google = panel.document.querySelector("#signin-google")!;
    const github = panel.document.querySelector("#signin-github")!;
    const status = panel.document.querySelector("#account-status")!;

    expect(google.disabled).toBe(true);
    expect(github.disabled).toBe(true);
    expect(status.textContent).toBe("No publik account configured in this build");
    expect(status.className).toBe("status warn");

    // A disabled button's activation behavior is suppressed by the DOM itself
    // (HTML spec, not this app's code) — assert it holds here too, since this
    // is the exact "I clicked it and nothing happened" the report described,
    // and it should be silence-because-disabled, not silence-because-broken.
    google.click();
    github.click();
    expect(panel.signInCalls).toEqual([]);
  });

  it("enables both sign-in buttons and wires each to its own provider when a Supabase project is configured", async () => {
    const panel = await openPanel({ signedIn: false, supabaseConfigured: true });

    const google = panel.document.querySelector("#signin-google")!;
    const github = panel.document.querySelector("#signin-github")!;
    const status = panel.document.querySelector("#account-status")!;

    expect(google.disabled).toBe(false);
    expect(github.disabled).toBe(false);
    expect(status.textContent).toBe("Not signed in");
    expect(status.className).toBe("status");

    google.click();
    expect(panel.signInCalls).toEqual(["google"]);

    github.click();
    expect(panel.signInCalls).toEqual(["google", "github"]);
  });

  it("shows the signed-in state, hides both sign-in buttons, and wires sign out", async () => {
    const panel = await openPanel({
      signedIn: true,
      signedInEmail: "founder@publikhq.com",
      supabaseConfigured: true,
    });

    const google = panel.document.querySelector("#signin-google")!;
    const github = panel.document.querySelector("#signin-github")!;
    const signOut = panel.document.querySelector("#signout")!;
    const status = panel.document.querySelector("#account-status")!;

    expect(status.textContent).toBe("Signed in as founder@publikhq.com");
    expect(status.className).toBe("status ok");
    expect(google.style.display).toBe("none");
    expect(github.style.display).toBe("none");
    expect(signOut.style.display).toBe("");

    signOut.click();
    // The handler is async (`await window.iris.signOut()` then a chained
    // `load()`, itself awaiting `getSettings()` again) — wait past both
    // before the test ends and afterEach closes the window out from under
    // whichever microtask is still in flight.
    for (let tick = 0; tick < 40; tick += 1) {
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
    expect(panel.signOutCallCount()).toBe(1);
  });
});

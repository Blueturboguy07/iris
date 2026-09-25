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

/** The balance view the main process hands the panel (services/publik-balance.ts). */
interface FakePublikBalance {
  balanceLine: string | null;
  isLow: boolean;
  costLine: string;
  addCreditUrl: string;
}

interface FakeSettings {
  hasPublikApiKey?: boolean;
  buildCanProvisionAutomatically?: boolean;
  publikCard?: { balanceLine: string; whyItCosts: string; buttonLabel: string; buttonUrl: string | null };
  publikBalance?: FakePublikBalance | null;
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
async function openPanel(
  settings: FakeSettings,
  options: { publikBalanceAfterRefresh?: FakePublikBalance | null } = {}
) {
  const html = readFileSync(join(SETTINGS_DIR, "index.html"), "utf-8");
  const inlineScript = html.match(/<script>([\s\S]*)<\/script>/)?.[1];
  if (!inlineScript) throw new Error("settings/index.html has no inline <script> to run");
  const htmlWithoutScript = html.replace(/<script>[\s\S]*<\/script>/, "");

  const signInCalls: string[] = [];
  let signOutCalls = 0;
  const openedLinks: string[] = [];
  let pushBalanceChange: ((balance: FakePublikBalance | null) => void) | null = null;

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
      openExternal: async (url: string) => {
        openedLinks.push(url);
      },
      // What publik API has left: the panel reads it fresh on open, and is
      // pushed a new one whenever the main process learns something.
      refreshPublikBalance: async () =>
        "publikBalanceAfterRefresh" in options ? options.publikBalanceAfterRefresh : settings.publikBalance ?? null,
      onPublikBalanceChanged: (callback: (balance: FakePublikBalance | null) => void) => {
        pushBalanceChange = callback;
      },
      // Usage counts, prices and the nudge have their own suite
      // (usage-and-prices-renderer.test.ts); here they are simply quiet.
      usageState: async () => ({ state: "sharing", showDisclosure: false }),
      usageDisclosureShown: async () => ({ state: "sharing", showDisclosure: false }),
      setUsageSharing: async () => ({ state: "sharing", showDisclosure: false }),
      onUsageChanged: () => {},
      priceComparison: async () => ({ state: "unavailable" }),
      onPriceComparisonChanged: () => {},
      currentNudge: async () => null,
      dismissNudge: async () => {},
      nudgeActedOn: async () => {},
      onNudgeChanged: () => {},
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
    openedLinks,
    pushBalanceChange: (balance: FakePublikBalance | null) => pushBalanceChange?.(balance),
  };
}

async function settle(): Promise<void> {
  for (let tick = 0; tick < 20; tick += 1) {
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
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

describe("the settings panel's publik API balance", () => {
  const card = {
    balanceLine: "$1.84 left",
    whyItCosts: "The AI model behind Iris is run by a provider that charges per use.",
    buttonLabel: "Add a plan or pack",
    buttonUrl: "https://publikhq.com/dashboard/api/add",
  };
  const healthyBalance: FakePublikBalance = {
    balanceLine: "$1.84 left",
    isLow: false,
    costLine: "Last reply: $0.004",
    addCreditUrl: "https://publikhq.com/dashboard/api/add",
  };
  const lowBalance: FakePublikBalance = {
    balanceLine: "$0.18 left",
    isLow: true,
    costLine: "About $0.010 per message on publik-balanced",
    addCreditUrl: "https://publikhq.com/claim/HK7F-2QWD",
  };

  it("shows the balance, the cost line and Add credit — and only one link — while publik API answers", async () => {
    const panel = await openPanel({ hasPublikApiKey: true, publikCard: card, publikBalance: healthyBalance });

    const status = panel.document.querySelector("#publik-status")!;
    const addCredit = panel.document.querySelector("#publik-add-credit")!;
    expect(status.textContent).toBe("$1.84 left");
    expect(status.className).toBe("status ok");
    expect(panel.document.querySelector("#publik-cost")!.textContent).toBe("Last reply: $0.004");
    expect(addCredit.style.display).toBe("");
    expect(addCredit.className).toBe("");
    // The older plan button would be a second link to the same page.
    expect(panel.document.querySelector("#publik-cta")!.style.display).toBe("none");
    expect(panel.document.querySelector("#publik-low")!.style.display).toBe("none");

    addCredit.click();
    expect(panel.openedLinks).toEqual(["https://publikhq.com/dashboard/api/add"]);
  });

  it("turns into a warning with a loud Add credit under $0.25, and still blocks nothing", async () => {
    const panel = await openPanel({ hasPublikApiKey: true, publikCard: card, publikBalance: lowBalance });

    const status = panel.document.querySelector("#publik-status")!;
    const addCredit = panel.document.querySelector("#publik-add-credit")!;
    expect(status.textContent).toBe("$0.18 left");
    expect(status.className).toBe("status low");
    expect(panel.document.querySelector("#publik-low")!.style.display).toBe("");
    expect(addCredit.className).toBe("accent");
    expect(addCredit.disabled).toBe(false);

    addCredit.click();
    expect(panel.openedLinks).toEqual(["https://publikhq.com/claim/HK7F-2QWD"]);
  });

  it("shows nothing new when publik API is not the provider answering", async () => {
    // A stored publik key, but the reader answers with their own key or codex:
    // the main process sends no balance view, and the section is as it was.
    const panel = await openPanel({ hasPublikApiKey: true, publikCard: card, publikBalance: null });

    expect(panel.document.querySelector("#publik-add-credit")!.style.display).toBe("none");
    expect(panel.document.querySelector("#publik-cost")!.style.display).toBe("none");
    const cta = panel.document.querySelector("#publik-cta")!;
    expect(cta.style.display).toBe("");
    expect(cta.textContent).toBe("Add a plan or pack");
  });

  it("re-reads the balance when the panel opens and draws the fresh one", async () => {
    const panel = await openPanel(
      { hasPublikApiKey: true, publikCard: card, publikBalance: healthyBalance },
      { publikBalanceAfterRefresh: lowBalance }
    );
    expect(panel.document.querySelector("#publik-status")!.textContent).toBe("$0.18 left");
  });

  it("redraws when the main process pushes a new balance after a reply", async () => {
    const panel = await openPanel({ hasPublikApiKey: true, publikCard: card, publikBalance: healthyBalance });
    panel.pushBalanceChange({ ...healthyBalance, balanceLine: "$1.83 left", costLine: "Last reply: $0.011" });
    await settle();
    expect(panel.document.querySelector("#publik-status")!.textContent).toBe("$1.83 left");
    expect(panel.document.querySelector("#publik-cost")!.textContent).toBe("Last reply: $0.011");
  });
});

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";
import { afterEach, describe, expect, it } from "vitest";

/**
 * The chat window, driven for real, for the two things "Balance + Add credit"
 * put in it: the balance beside the provider name, and the one "Add credit"
 * link under publik API's out-of-money sentence.
 *
 * Same approach as `settings-renderer.test.ts`: boot the shipped
 * `chat/index.html` in jsdom against a fake `window.iris` standing in for the
 * preload script, and read the DOM the way a person would. The 402 case is the
 * one worth measuring: `ipcRenderer.invoke` carries only an error's message
 * across, so the link has to come back through `lastChatFailure` — a window
 * that forgot to ask would show the sentence and no way to act on it.
 */

const CHAT_DIR = join(__dirname, "..", "src", "renderer", "chat");

interface FakeBalance {
  balanceLine: string | null;
  isLow: boolean;
  costLine: string;
  addCreditUrl: string;
}

const openWindows: JSDOM[] = [];

afterEach(() => {
  for (const dom of openWindows.splice(0)) dom.window.close();
});

async function settle(): Promise<void> {
  for (let tick = 0; tick < 20; tick += 1) {
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

async function openChat(options: {
  publikBalance: FakeBalance | null;
  failure?: { message: string; addCreditUrl: string | null };
}) {
  const html = readFileSync(join(CHAT_DIR, "index.html"), "utf-8");
  const inlineScript = html.match(/<script>([\s\S]*)<\/script>/)?.[1];
  if (!inlineScript) throw new Error("chat/index.html has no inline <script> to run");
  const htmlWithoutScript = html.replace(/<script>[\s\S]*<\/script>/, "");

  const dom = new JSDOM(htmlWithoutScript, {
    url: "https://localhost/chat.html",
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });
  openWindows.push(dom);
  const { window } = dom;
  const openedLinks: string[] = [];

  Object.defineProperty(window, "iris", {
    configurable: true,
    value: {
      getSettings: async () => ({
        hasPublikApiKey: true,
        hasAnthropicApiKey: false,
        buildCanProvisionAutomatically: true,
        secretStorageAvailable: true,
        publikBalance: options.publikBalance,
      }),
      refreshPublikBalance: async () => options.publikBalance,
      onPublikBalanceChanged: () => {},
      onStage: () => {},
      onAccountChanged: () => {},
      // Electron prefixes an invoke rejection's message; the window must show
      // the clean sentence it reads back instead.
      sendQuery: async () => {
        throw new Error(
          `Error invoking remote method 'chat:query': Error: ${options.failure?.message ?? "no failure"}`
        );
      },
      lastChatFailure: async () => options.failure ?? null,
      openExternal: async (url: string) => {
        openedLinks.push(url);
      },
      openGuide: () => {},
      minimizeWindow: () => {},
      closeWindow: () => {},
    },
  });
  window.eval(inlineScript);
  await settle();

  async function ask(question: string): Promise<void> {
    const input = window.document.querySelector("#input")!;
    input.value = question;
    window.document.querySelector("#send")!.click();
    await settle();
  }

  return { document: window.document, openedLinks, ask };
}

describe("the chat window's publik API balance", () => {
  it("puts the balance beside the provider name, with the cost of a message on hover", async () => {
    const chat = await openChat({
      publikBalance: {
        balanceLine: "$1.84 left",
        isLow: false,
        costLine: "Last reply: $0.004",
        addCreditUrl: "https://publikhq.com/dashboard/api/add",
      },
    });
    const tier = chat.document.querySelector("#tier")!;
    expect(tier.textContent).toBe("publik API · $1.84 left");
    expect(tier.title).toBe("Last reply: $0.004");
    expect(tier.classList.contains("low")).toBe(false);
  });

  it("marks a balance under $0.25 as low", async () => {
    const chat = await openChat({
      publikBalance: {
        balanceLine: "$0.18 left",
        isLow: true,
        costLine: "About $0.010 per message on publik-balanced",
        addCreditUrl: "https://publikhq.com/claim/HK7F-2QWD",
      },
    });
    expect(chat.document.querySelector("#tier")!.classList.contains("low")).toBe(true);
  });

  it("shows nothing new when publik API is not the provider answering", async () => {
    const chat = await openChat({ publikBalance: null });
    const tier = chat.document.querySelector("#tier")!;
    expect(tier.textContent).toBe("publik API");
    expect(tier.title).toBe("");
  });
});

describe("the chat window's out-of-money refusal", () => {
  it("shows the server's own sentence and an Add credit button that opens its one link", async () => {
    const chat = await openChat({
      publikBalance: null,
      failure: {
        message: "Not enough publik credit for this request.",
        addCreditUrl: "https://publikhq.com/claim/HK7F-2QWD",
      },
    });
    await chat.ask("what is on my screen?");

    const errorMessage = chat.document.querySelector(".msg.error")!;
    expect(errorMessage.firstChild!.textContent).toBe("Not enough publik credit for this request.");
    expect(errorMessage.textContent).not.toContain("Error invoking remote method");
    const addCredit = errorMessage.querySelector("button.add-credit")!;
    expect(addCredit.textContent).toBe("Add credit");

    addCredit.click();
    expect(chat.openedLinks).toEqual(["https://publikhq.com/claim/HK7F-2QWD"]);
  });

  it("offers no Add credit under any other failure", async () => {
    const chat = await openChat({
      publikBalance: null,
      failure: { message: "publik api is unavailable right now.", addCreditUrl: null },
    });
    await chat.ask("what is on my screen?");

    const errorMessage = chat.document.querySelector(".msg.error")!;
    expect(errorMessage.textContent).toBe("publik api is unavailable right now.");
    expect(errorMessage.querySelector("button")).toBeNull();
  });
});

// cdp.mjs
//
// A tiny, dependency-free Chrome DevTools Protocol client for driving the
// *real* launched Iris app on the windows-latest CI runner. It talks to the
// DevTools HTTP endpoint the app exposes when started with
// `--remote-debugging-port`, over Node's built-in `fetch` + `WebSocket`
// (global since Node 21) — no puppeteer, no chrome-remote-interface, nothing
// that would drag a Chromium download onto the runner.
//
// It is the Windows sibling of the throwaway `cdp.mjs` the macOS Iris work
// used, generalized into a reusable session object with wait/poll helpers so a
// headed GUI suite can attach to each renderer, evaluate JS through the real
// preload bridge, and capture genuine `Page.captureScreenshot` PNGs (on
// Windows the app's windows are actually shown, so the screenshots have real
// pixels in them, unlike the hidden-tray macOS case).

import { writeFileSync } from "node:fs";

// Bind to 127.0.0.1 explicitly: on Windows `localhost` can resolve to ::1
// first, but Chromium's remote-debugging server binds to 127.0.0.1.
const HOST = "127.0.0.1";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Waits until the DevTools HTTP endpoint on `port` answers — i.e. the app has
 *  started far enough to have a debuggable renderer. */
export async function waitForDebuggerEndpoint(port, timeoutMs = 40_000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://${HOST}:${port}/json/version`);
      if (response.ok) return await response.json();
    } catch (error) {
      lastError = error;
    }
    await sleep(300);
  }
  throw new Error(`CDP endpoint on port ${port} never came up (${lastError?.message ?? "no response"})`);
}

/** Lists the debuggable targets (one per BrowserWindow webContents). */
export async function listTargets(port) {
  const response = await fetch(`http://${HOST}:${port}/json`);
  if (!response.ok) throw new Error(`GET /json returned ${response.status}`);
  return await response.json();
}

/** Waits for a `page` target whose URL contains `urlSubstr` (e.g.
 *  "chat/index.html") and returns it once it has a websocket to attach to. */
export async function waitForTarget(port, urlSubstr, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  let seen = [];
  while (Date.now() < deadline) {
    const targets = await listTargets(port).catch(() => []);
    seen = targets.map((t) => t.url);
    const match = targets.find(
      (t) => t.type === "page" && (t.url || "").includes(urlSubstr) && t.webSocketDebuggerUrl,
    );
    if (match) return match;
    await sleep(300);
  }
  throw new Error(`no CDP page target matching '${urlSubstr}' within ${timeoutMs}ms; had: ${JSON.stringify(seen)}`);
}

/** Returns whether any current target's URL contains `urlSubstr`. */
export async function hasTarget(port, urlSubstr) {
  const targets = await listTargets(port).catch(() => []);
  return targets.some((t) => (t.url || "").includes(urlSubstr));
}

/** One attached DevTools session to a single renderer target. */
export class CdpSession {
  constructor(target) {
    this.target = target;
    this.socket = null;
    this.nextId = 0;
    this.pending = new Map();
  }

  async open() {
    this.socket = new WebSocket(this.target.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      this.socket.addEventListener("open", () => resolve());
      this.socket.addEventListener("error", () => reject(new Error("websocket failed to open")));
    });
    this.socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (message.id && this.pending.has(message.id)) {
        const { resolve, reject } = this.pending.get(message.id);
        this.pending.delete(message.id);
        if (message.error) {
          reject(new Error(JSON.stringify(message.error)));
        } else {
          resolve(message.result);
        }
      }
    });
    await this.send("Runtime.enable");
    await this.send("Page.enable");
    return this;
  }

  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++this.nextId;
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  /** Evaluates a JS expression in the renderer and returns its (by-value)
   *  result. Awaits promises, and turns a thrown exception into a rejected
   *  promise carrying the renderer-side message. */
  async eval(expression) {
    const result = await this.send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (result.exceptionDetails) {
      const description =
        result.exceptionDetails.exception?.description ||
        result.exceptionDetails.exception?.value ||
        result.exceptionDetails.text ||
        JSON.stringify(result.exceptionDetails);
      throw new Error(`renderer eval threw: ${description}`);
    }
    return result.result?.value;
  }

  /** Polls `expression` until `predicate(value)` is true (or times out),
   *  returning the last value. */
  async waitForEval(expression, predicate, timeoutMs = 15_000, intervalMs = 300) {
    const deadline = Date.now() + timeoutMs;
    let last;
    while (Date.now() < deadline) {
      last = await this.eval(expression).catch((error) => ({ __evalError: String(error) }));
      if (predicate(last)) return last;
      await sleep(intervalMs);
    }
    throw new Error(`waitForEval('${expression}') timed out; last value: ${JSON.stringify(last)}`);
  }

  /** Captures the renderer's own content as a PNG written to `filePath`. */
  async screenshot(filePath) {
    const { data } = await this.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: false,
    });
    writeFileSync(filePath, Buffer.from(data, "base64"));
    return filePath;
  }

  close() {
    try {
      this.socket?.close();
    } catch {
      // Already gone; nothing to do.
    }
  }
}

/** Attaches a session to the first target matching `urlSubstr`, waiting for it
 *  to appear if necessary. */
export async function attach(port, urlSubstr, timeoutMs = 30_000) {
  const target = await waitForTarget(port, urlSubstr, timeoutMs);
  return await new CdpSession(target).open();
}

import { contextBridge, ipcRenderer } from "electron";

/**
 * preload/index.ts
 *
 * The only channel between the renderers and the main process. Context isolation
 * is on and node integration is off, so this file is the complete list of what a
 * renderer can do.
 *
 * Two surfaces are exposed:
 *   `window.iris`       — the chat, overlay, settings, and maintain-mode ask
 *                         card windows.
 *   `window.irisNative` — the generic command/event pair the transplanted guide
 *                         panel needs. `src/renderer/guide/iris-bridge.js`
 *                         reshapes it into the `window.__TAURI__` object that
 *                         `app.js` already knows how to call.
 *
 * Notably absent: anything that returns a stored secret. A renderer can ask
 * whether a key exists and can set one, but never read one back.
 */

contextBridge.exposeInMainWorld("iris", {
  // Chat
  sendQuery: (text: string): Promise<string> => ipcRenderer.invoke("chat:query", text),
  /** Why the last `sendQuery` rejected: the clean sentence, and the one "Add
   *  credit" link when publik API refused for lack of money. */
  lastChatFailure: (): Promise<{ message: string; addCreditUrl: string | null } | null> =>
    ipcRenderer.invoke("chat:lastFailure"),
  onStage: (callback: (data: { stage: string; label: string }) => void) => {
    ipcRenderer.on("companion:stage", (_event, data) => callback(data));
  },

  // Overlay
  onPoint: (
    callback: (tags: Array<{ x: number; y: number; label: string; screen: number }>) => void
  ) => {
    ipcRenderer.on("overlay:point", (_event, tags) => callback(tags));
  },
  onCursorBuddy: (callback: (x: number, y: number) => void) => {
    ipcRenderer.on("overlay:cursor-buddy", (_event, x, y) => callback(x, y));
  },
  onCursorBuddyVisible: (callback: (visible: boolean) => void) => {
    ipcRenderer.on("overlay:cursor-buddy-visible", (_event, visible) => callback(visible));
  },

  // Settings. `getSettings` reports whether a key is stored, never the key.
  getSettings: () => ipcRenderer.invoke("settings:getAll"),
  setSetting: (key: string, value: unknown) => ipcRenderer.invoke("settings:set", key, value),

  // publik API. The renderer never sees the key itself — it asks the main
  // process to provision or to accept a pasted one, and gets back only the
  // card's rendered state (CONTRACT section 1: a desktop app's key must not
  // enter a renderer).
  provisionPublikApi: () => ipcRenderer.invoke("publik:provision"),
  publikCard: (isFirstRun: boolean) => ipcRenderer.invoke("publik:card", isFirstRun),
  markPublikCardShown: () => ipcRenderer.invoke("publik:cardShown"),
  // The balance lines: what is left, what a message costs, and where "Add
  // credit" goes. Null while publik API is not the provider answering.
  publikBalance: () => ipcRenderer.invoke("publik:balance"),
  refreshPublikBalance: () => ipcRenderer.invoke("publik:refreshBalance"),
  onPublikBalanceChanged: (callback: (balance: unknown) => void) => {
    ipcRenderer.on("publik:balanceChanged", (_event, balance) => callback(balance));
  },
  completeFirstRun: () => ipcRenderer.invoke("firstRun:complete"),

  // Codex. Iris opens the login in a console and never sees the credential.
  codexLogin: () => ipcRenderer.invoke("codex:login"),
  refreshCodexAvailability: () => ipcRenderer.invoke("codex:refresh"),

  // Account
  signIn: (provider: "google" | "github") => ipcRenderer.invoke("account:signIn", provider),
  signOut: () => ipcRenderer.invoke("account:signOut"),
  onAccountChanged: (callback: (state: { signedIn: boolean }) => void) => {
    ipcRenderer.on("iris-account-changed", (_event, state) => callback(state));
  },

  // Guides
  openGuide: () => ipcRenderer.invoke("guide:open"),
  // Settings, from the chat window's gear button (the tray menu has its own).
  openSettings: () => ipcRenderer.invoke("settings:open"),

  // Shell + window controls
  openExternal: (url: string) => ipcRenderer.invoke("shell:openExternal", url),
  minimizeWindow: () => ipcRenderer.invoke("window:minimize"),
  closeWindow: () => ipcRenderer.invoke("window:close"),

  // Maintain mode. The ask card (src/renderer/maintain) is the only renderer
  // that calls these — see `main/index.ts`'s "Maintain mode" section and
  // `services/maintain/incident-coordinator.ts`'s `MaintainIncidentSnapshot`.
  getMaintainSnapshot: () => ipcRenderer.invoke("maintain:getSnapshot"),
  answerMaintainAsk: (answer: "somethingIsBroken" | "thatWasMe" | "neverAskAboutThisApp") =>
    ipcRenderer.invoke("maintain:answerAsk", answer),
  clearMaintainFixStatus: () => ipcRenderer.invoke("maintain:clearFixStatus"),
  mutedMaintainApps: () => ipcRenderer.invoke("maintain:mutedApps"),
  unmuteMaintainApp: (appSlug: string) => ipcRenderer.invoke("maintain:unmuteApp", appSlug),
  /** The card measures its own rendered height and reports it back so the
   *  (frameless, non-resizable-by-the-OS) window can be sized to fit — see
   *  `main/index.ts`'s `maintainCardRect`. */
  resizeMaintainCard: (height: number) => ipcRenderer.invoke("maintain:resize", height),
  onMaintainSnapshot: (callback: (snapshot: unknown) => void) => {
    ipcRenderer.on("maintain:snapshot", (_event, snapshot) => callback(snapshot));
  },
});

/** The generic bridge the transplanted guide panel drives. */
contextBridge.exposeInMainWorld("irisNative", {
  invoke: (command: string, args: Record<string, unknown>) =>
    ipcRenderer.invoke("iris:invoke", command, args),

  /** Returns an unlisten function, which is what `app.js` stores and calls. */
  listen: (eventName: string, handler: (payload: unknown) => void) => {
    const subscription = (_event: unknown, payload: unknown) => handler(payload);
    ipcRenderer.on(eventName, subscription);
    return () => ipcRenderer.removeListener(eventName, subscription);
  },
});

import { contextBridge, ipcRenderer } from "electron";

/**
 * preload/index.ts
 *
 * The only channel between the renderers and the main process. Context isolation
 * is on and node integration is off, so this file is the complete list of what a
 * renderer can do.
 *
 * Two surfaces are exposed:
 *   `window.iris`       — the chat, overlay, and settings windows.
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

  // Account
  signIn: (provider: "google" | "github") => ipcRenderer.invoke("account:signIn", provider),
  signOut: () => ipcRenderer.invoke("account:signOut"),
  onAccountChanged: (callback: (state: { signedIn: boolean }) => void) => {
    ipcRenderer.on("iris-account-changed", (_event, state) => callback(state));
  },

  // Guides
  openGuide: () => ipcRenderer.invoke("guide:open"),

  // Shell + window controls
  openExternal: (url: string) => ipcRenderer.invoke("shell:openExternal", url),
  minimizeWindow: () => ipcRenderer.invoke("window:minimize"),
  closeWindow: () => ipcRenderer.invoke("window:close"),
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

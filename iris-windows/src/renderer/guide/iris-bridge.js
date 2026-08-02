/**
 * iris-bridge.js
 *
 * The entire Windows-specific delta for the guide panel.
 *
 * `app.js` in this directory is a byte-for-byte copy of `iris-desktop/ui/app.js`,
 * the Tauri guide panel. It reaches the native shell through exactly three
 * helpers — `tauri()`, `nativeInvoke`, `nativeListen` — plus
 * `window.__IRIS_CONFIG__`. Rather than fork 1,600 lines of working UI to change
 * how those four things are spelled, this file presents Electron's preload
 * bridge in the shape `app.js` already expects, and is loaded before it.
 *
 * The upside is that the two panels stay diffable: a fix to the Tauri guide UI
 * can be copied across without a merge, and this file is the only place that has
 * to know which shell it is running in.
 *
 * Commands are handled in `src/main/index.ts`; the names below are the ones
 * `app.js` already invokes.
 */
(function installIrisNativeBridge() {
  // `app.js` reads localStorage at module scope (its `watching` default), so if
  // localStorage throws, the entire panel fails to render rather than losing one
  // setting. Chromium treats a `file://` page as an opaque origin and can refuse
  // storage there, and this window is loaded with `loadFile`. Rather than gamble
  // on Electron's behaviour — which cannot be verified from macOS — substitute an
  // in-memory store when the real one is unusable. Guide progress is then lost
  // between launches, which is a far smaller failure than a blank window.
  try {
    window.localStorage.setItem("iris:storage-probe", "1");
    window.localStorage.removeItem("iris:storage-probe");
  } catch {
    const memory = new Map();
    Object.defineProperty(window, "localStorage", {
      configurable: true,
      value: {
        getItem: (key) => (memory.has(String(key)) ? memory.get(String(key)) : null),
        setItem: (key, value) => memory.set(String(key), String(value)),
        removeItem: (key) => memory.delete(String(key)),
        clear: () => memory.clear(),
        key: (index) => Array.from(memory.keys())[index] ?? null,
        get length() {
          return memory.size;
        },
      },
    });
  }

  const electronBridge = window.irisNative;
  if (!electronBridge) return;

  window.__IRIS_CONFIG__ = window.__IRIS_CONFIG__ || {};
  if (electronBridge.apiBase) {
    window.__IRIS_CONFIG__.apiBase = electronBridge.apiBase;
  }

  window.__TAURI__ = {
    core: {
      invoke: (command, args) => electronBridge.invoke(command, args ?? {}),
    },
    event: {
      // `app.js` stores whatever this resolves to and calls it to unsubscribe,
      // so the return value has to be the unlisten function itself.
      listen: (eventName, handler) =>
        Promise.resolve(electronBridge.listen(eventName, (payload) => handler({ payload }))),
    },
    opener: {
      openUrl: (url) => electronBridge.invoke("open_external", { url }),
    },
    app: {
      exit: () => electronBridge.invoke("quit_iris", {}),
    },
  };
})();

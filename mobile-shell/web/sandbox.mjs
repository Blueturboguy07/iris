import {
  AppUserDataStore,
} from "./storage.mjs";
import {
  PackageValidationError,
  UnsupportedCapabilityError,
  assessCapabilities,
  validateAppId,
  validateContentPath,
  validateStableId,
} from "./runtime.mjs";

const ENTRY_CSP = [
  "default-src 'none'",
  "script-src 'unsafe-inline'",
  "style-src 'unsafe-inline'",
  "img-src data: blob:",
  "media-src data: blob:",
  "connect-src 'none'",
  "font-src 'none'",
  "frame-src 'none'",
  "child-src 'none'",
  "worker-src 'none'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
].join("; ");

const MAX_MESSAGE_BYTES = 72 * 1024;
const REQUEST_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,96}$/;

function randomToken() {
  const bytes = new Uint8Array(24);
  globalThis.crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function safeJsonSize(value) {
  try {
    return new TextEncoder().encode(JSON.stringify(value)).byteLength;
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

function escapeScriptData(value) {
  return JSON.stringify(value).replace(/</g, "\\u003c").replace(/>/g, "\\u003e");
}

function bridgeBootstrap(channelToken, storageEnabled) {
  const config = escapeScriptData({ channelToken, storageEnabled });
  return `
<script>
(() => {
  "use strict";
  const config = ${config};
  let nextRequest = 1;
  const pending = new Map();
  function call(op, payload) {
    if (!config.storageEnabled) return Promise.reject(new Error("Iris storage capability is not granted"));
    const requestId = "app_" + (nextRequest++);
    return new Promise((resolve, reject) => {
      pending.set(requestId, { resolve, reject });
      parent.postMessage({
        type: "iris:web-storage",
        channelToken: config.channelToken,
        requestId,
        op,
        ...payload,
      }, "*");
    });
  }
  addEventListener("message", (event) => {
    const data = event.data;
    if (!data || data.type !== "iris:web-storage:result" || data.channelToken !== config.channelToken) return;
    const waiter = pending.get(data.requestId);
    if (!waiter) return;
    pending.delete(data.requestId);
    if (data.ok) waiter.resolve(data.value);
    else waiter.reject(new Error(String(data.error || "Storage request failed")));
  });
  Object.defineProperty(window, "IrisApp", {
    configurable: false,
    enumerable: true,
    writable: false,
    value: Object.freeze({
      storage: Object.freeze({
        get: (key) => call("get", { key }),
        set: (key, value) => call("set", { key, value }),
        remove: (key) => call("remove", { key }),
        list: () => call("list", {}),
      }),
    }),
  });
})();
</script>`;
}

function buildSrcdoc(html, channelToken, storageEnabled) {
  const csp = `<meta http-equiv="Content-Security-Policy" content="${ENTRY_CSP.replaceAll("&", "&amp;").replaceAll('"', "&quot;")}">`;
  const bootstrap = bridgeBootstrap(channelToken, storageEnabled);
  const source = String(html || "");
  if (/<head[\s>]/i.test(source)) {
    return source.replace(/<head([^>]*)>/i, `<head$1>${csp}${bootstrap}`);
  }
  return `<!doctype html><html><head>${csp}${bootstrap}</head><body>${source}</body></html>`;
}

function entryHtml(verifiedPackage) {
  const manifest = verifiedPackage?.manifest;
  const entryPath = validateContentPath(manifest?.runtime?.entrypoint || manifest?.entryPath);
  const file = verifiedPackage?.files?.find((item) => item.path === entryPath);
  if (!file || file.mime !== "text/html") {
    throw new PackageValidationError("Verified package entry HTML is missing", "missing_entry");
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(file.bytes);
}

export class SandboxedAppHost {
  constructor(iframe, { onError = () => {} } = {}) {
    if (!(iframe instanceof HTMLIFrameElement)) throw new TypeError("SandboxedAppHost requires an iframe");
    this.iframe = iframe;
    this.onError = onError;
    this.session = null;
    this.handleMessage = this.handleMessage.bind(this);
    window.addEventListener("message", this.handleMessage);
    iframe.setAttribute("sandbox", "allow-scripts");
    iframe.setAttribute("referrerpolicy", "no-referrer");
    iframe.setAttribute("allow", "");
  }

  close() {
    this.session = null;
    this.iframe.removeAttribute("src");
    this.iframe.srcdoc = "";
  }

  destroy() {
    this.close();
    window.removeEventListener("message", this.handleMessage);
  }

  open(verifiedPackage) {
    const manifest = verifiedPackage?.manifest;
    const appId = validateAppId(manifest?.appId);
    const projectId = validateStableId(manifest?.projectId, "Project id");
    const dataNamespace = String(manifest?.data?.namespace || "");
    const requested = Array.isArray(manifest?.capabilities) ? manifest.capabilities : [];
    const unsupported = assessCapabilities(requested);
    if (unsupported.length) throw new UnsupportedCapabilityError(unsupported);
    const html = entryHtml(verifiedPackage);
    const channelToken = randomToken();
    const storageEnabled = requested.includes("web.storage");
    this.session = {
      appId,
      channelToken,
      source: null,
      storage: storageEnabled ? new AppUserDataStore(appId, projectId, dataNamespace) : null,
    };
    this.iframe.srcdoc = buildSrcdoc(html, channelToken, storageEnabled);
    this.session.source = this.iframe.contentWindow;
    return { appId, channelToken, storageEnabled };
  }

  async handleMessage(event) {
    const session = this.session;
    if (!session || event.source !== session.source || event.source !== this.iframe.contentWindow) return;
    const data = event.data;
    if (!data || typeof data !== "object" || data.type !== "iris:web-storage") return;
    if (data.channelToken !== session.channelToken) return;
    if (!session.storage) return;
    if (!REQUEST_ID_PATTERN.test(String(data.requestId || ""))) return;
    if (safeJsonSize(data) > MAX_MESSAGE_BYTES) return;

    let ok = true;
    let value = null;
    let error = "";
    try {
      if (data.op === "get") value = await session.storage.get(data.key);
      else if (data.op === "set") value = await session.storage.set(data.key, data.value);
      else if (data.op === "remove") await session.storage.remove(data.key);
      else if (data.op === "list") value = await session.storage.list();
      else throw new PackageValidationError("Unknown storage operation", "invalid_storage_operation");
    } catch (caught) {
      ok = false;
      error = caught instanceof Error ? caught.message : "Storage request failed";
      this.onError(caught);
    }
    if (!this.session || this.session.channelToken !== session.channelToken) return;
    event.source.postMessage(
      {
        type: "iris:web-storage:result",
        channelToken: session.channelToken,
        requestId: data.requestId,
        ok,
        value,
        error,
      },
      "*"
    );
  }
}

export const sandboxPolicy = Object.freeze({
  sandbox: "allow-scripts",
  csp: ENTRY_CSP,
  embedderNavigationPolicy: "frame-src 'none'",
  authentication: "exact WindowProxy + fresh per-open channel token",
});

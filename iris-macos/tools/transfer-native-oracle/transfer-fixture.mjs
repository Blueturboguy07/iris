// Hidden Electron fixture for the NitroAI transfer oracle. It drives the
// built app through visible DOM controls and never writes IndexedDB directly.
import fsSync from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const targetRoot = process.env.IRIS_NITROAI_TARGET_ROOT;
if (!targetRoot || !path.isAbsolute(targetRoot)) {
  throw new Error("IRIS_NITROAI_TARGET_ROOT must name an explicit approved fixture root.");
}
const TARGET = path.resolve(targetRoot);
const { app, BrowserWindow } = await import("electron");
const DIST = path.join(TARGET, "dist");
const [profileRoot, action, encodedArgs = "{}"] = process.argv.slice(2);
const args = JSON.parse(encodedArgs);
const userData = path.join(profileRoot, "user-data");
const sessionData = path.join(profileRoot, "session-data");

// Electron requires these paths before readiness. Keep the fixture isolated
// even when the ESM entrypoint is evaluated asynchronously.
fsSync.mkdirSync(userData, { recursive: true });
fsSync.mkdirSync(sessionData, { recursive: true });
app.setPath("userData", userData);
app.setPath("sessionData", sessionData);

let currentStage = "module-start";
const stageTrace = [];
let openProfileServer;

class UnsupportedUI extends Error {
  kind = "unsupported";
}

let info;
let window;

function markStage(stage) {
  currentStage = stage;
  stageTrace.push({ stage, at: Date.now() });
  console.error(`NITROAI_STAGE ${stage}`);
}

function pageCode(fn, value) {
  return `(async () => { const textOf = (element) => element?.textContent?.replace(/\\s+/g, " ").trim() ?? ""; try { return { ok: true, value: await (${fn.toString()})(${JSON.stringify(value ?? null)}) }; } catch (error) { return { ok: false, error: String(error?.message ?? error) }; } })()`;
}

async function page(fn, value) {
  const result = await window.webContents.executeJavaScript(pageCode(fn, value), true);
  if (!result.ok) throw new Error(result.error);
  return result.value;
}

async function waitFor(fn, value, timeout = 12000) {
  const deadline = Date.now() + timeout;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const result = await page(fn, value);
      if (result) return result;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Timed out waiting for page state${lastError ? `: ${lastError.message}` : ""}`);
}

async function waitPath(prefix) {
  return waitFor((wanted) => wanted === "/"
    ? location.pathname === "/"
    : location.pathname.startsWith(wanted), prefix);
}

function textOf(element) {
  return element?.textContent?.replace(/\s+/g, " ").trim() ?? "";
}

function assertEnvelope(value) {
  if (!value || value.format !== "nitroai-library" || value.version !== 1 ||
      !Array.isArray(value.notes) || !Array.isArray(value.folders)) {
    throw new Error("Transfer file is not a NitroAI library envelope v1.");
  }
  for (const note of value.notes) {
    if (!note || typeof note.id !== "string" || typeof note.title !== "string" ||
        typeof note.sourceKind !== "string" || typeof note.sourceText !== "string" ||
        !Array.isArray(note.blocks) || !Number.isFinite(note.createdAt) ||
        !Number.isFinite(note.updatedAt) || !Number.isFinite(note.lastOpenedAt)) {
      throw new Error("Transfer envelope contains an invalid note.");
    }
    if (note.sourceMeta !== undefined &&
        (!note.sourceMeta || typeof note.sourceMeta !== "object" || Array.isArray(note.sourceMeta))) {
      throw new Error("Transfer envelope contains invalid note source metadata.");
    }
    if (note.blocks.some((block) => !block || typeof block.id !== "string" ||
        typeof block.type !== "string" || typeof block.text !== "string")) {
      throw new Error("Transfer envelope contains an invalid note block.");
    }
  }
  for (const folder of value.folders) {
    if (!folder || typeof folder.id !== "string" || typeof folder.name !== "string" ||
        !Number.isFinite(folder.createdAt)) {
      throw new Error("Transfer envelope contains an invalid folder.");
    }
  }
  return value;
}

async function ensureDashboard() {
  markStage("ensure-dashboard");
  const currentPath = await page(() => location.pathname);
  if (currentPath === "/settings") {
    await page(() => {
      const link = [...document.querySelectorAll("a")].find((el) => textOf(el) === "Dashboard");
      if (!link) throw new Error("Cannot return from Settings to Dashboard.");
      link.click();
    });
    await waitPath("/");
  } else if (currentPath.startsWith("/notes/")) {
    await page(() => document.querySelector('button[aria-label="Back to dashboard"]')?.click());
    await waitPath("/");
  }
  await waitFor(() => location.pathname === "/onboarding" ||
    (location.pathname === "/" && document.querySelector("h1")?.textContent?.trim() === "Dashboard"), null);
  const onboarding = await page(() => location.pathname === "/onboarding");
  if (onboarding) {
    await page((label) => {
      const button = [...document.querySelectorAll("button")].find((el) =>
        el.textContent?.replace(/\s+/g, " ").trim().includes(label),
      );
      if (!button) throw new Error(`Missing onboarding control: ${label}`);
      button.click();
    }, "Codex CLI");
    await page((label) => {
      const button = [...document.querySelectorAll("button")].find((el) =>
        el.textContent?.replace(/\s+/g, " ").trim() === label,
      );
      if (!button) throw new Error(`Missing onboarding control: ${label}`);
      button.click();
    }, "Get started");
  }
  await waitPath("/");
  await waitFor(() => document.querySelector("h1")?.textContent?.trim() === "Dashboard", null);
}

async function clickButton(label, index = 0, contains = false) {
  markStage(`click:${label}`);
  await page(({ label: wanted, index: wantedIndex, contains: useContains }) => {
    const matches = [...document.querySelectorAll("button")].filter((el) =>
      (useContains
        ? el.textContent?.replace(/\s+/g, " ").trim().includes(wanted)
        : el.textContent?.replace(/\s+/g, " ").trim() === wanted) &&
      getComputedStyle(el).display !== "none" && getComputedStyle(el).visibility !== "hidden",
    );
    const button = matches[wantedIndex];
    if (!button) throw new Error(`Missing button ${wanted} at index ${wantedIndex}.`);
    button.click();
  }, { label, index, contains });
}

async function setField(selector, value) {
  await page(({ selector: wanted, value: next }) => {
    const element = document.querySelector(wanted);
    if (!(element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement)) {
      throw new Error(`Missing field ${wanted}.`);
    }
    const prototype = element instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype
      : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
    if (!setter) throw new Error(`Cannot set field ${wanted}.`);
    element.focus();
    element.select?.();
    setter.call(element, next);
    element.dispatchEvent(new InputEvent("input", {
      bubbles: true,
      inputType: "insertText",
      data: next,
    }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
  }, { selector, value });
  await page(() => new Promise((resolve) => setTimeout(resolve, 0)));
}

async function blurField(selector) {
  await page((wanted) => {
    const field = document.querySelector(wanted);
    if (!field) throw new Error(`Missing field ${wanted}.`);
    field.focus();
    const focusTarget = document.querySelector('button[aria-label="Back to dashboard"]') ?? document.body;
    focusTarget.focus?.();
    // Hidden executeJavaScript focus transitions can leave activeElement
    // changed without dispatching the delegated focusout React uses for
    // onBlur. Preserve the real transition, then deliver that missing event.
    field.dispatchEvent(new FocusEvent("blur", { relatedTarget: focusTarget }));
    field.dispatchEvent(new FocusEvent("focusout", {
      bubbles: true,
      relatedTarget: focusTarget,
    }));
  }, selector);
  await page(() => new Promise((resolve) => setTimeout(resolve, 0)));
}

async function createFolder(name) {
  await clickButton("New Folder");
  await waitFor(() => !!document.querySelector('input[placeholder="Folder name"]'), null);
  await setField('input[placeholder="Folder name"]', name);
  await clickButton("Create folder");
  await waitFor((wanted) => [...document.querySelectorAll("button")].some((el) => textOf(el) === wanted), name);
}

async function seed({ noteTitle, body, folderName }) {
  markStage("seed-controls");
  await ensureDashboard();
  markStage("seed-folder");
  if (folderName) await createFolder(folderName);
  markStage("seed-blank-click");
  await clickButton("Blank document", 0, true);
  markStage("seed-note-route");
  await waitPath("/notes/");
  markStage("seed-paragraph-control");
  await waitFor(() => [...document.querySelectorAll("span")].some((el) => textOf(el) === "Type / for command menu"), null);
  await page(() => {
    const placeholder = [...document.querySelectorAll("span")].find((el) => textOf(el) === "Type / for command menu");
    if (!placeholder) throw new Error("Blank document editor did not expose its paragraph control.");
    placeholder.click();
  });
  await waitFor(() => !!document.querySelector("textarea"), null);
  markStage("seed-note-fields");
  await setField("main textarea", body);
  await waitFor((wanted) => document.querySelector("main textarea")?.value === wanted, body);
  await blurField("main textarea");
  await waitFor((wanted) => {
    const main = document.querySelector("main");
    return main?.innerText?.includes(wanted) || main?.querySelector("textarea")?.value === wanted;
  }, body);
  await new Promise((resolve) => setTimeout(resolve, 650));
  // NoteView persists blocks through a closure over the current note. Commit
  // the body first, then title, so the older note object cannot overwrite it.
  await setField("main input", noteTitle);
  await waitFor((wanted) => document.querySelector("main input")?.value === wanted, noteTitle);
  await blurField("main input");
  await new Promise((resolve) => setTimeout(resolve, 650));
  markStage("seed-back-dashboard");
  await page(() => document.querySelector('button[aria-label="Back to dashboard"]')?.click());
  await waitPath("/");
  await waitFor((wanted) => [...document.querySelectorAll("p")].some((el) => textOf(el) === wanted), noteTitle);
  if (folderName) {
    markStage("seed-note-menu");
    await page((wanted) => {
      const title = [...document.querySelectorAll("p")].find((el) => textOf(el) === wanted);
      const card = title?.parentElement?.parentElement;
      const more = card?.querySelector('button[aria-label="More"]');
      if (!more) throw new Error(`Cannot open note menu for ${wanted}.`);
      more.click();
    }, noteTitle);
    await waitFor(({ title, folder }) => {
      const note = [...document.querySelectorAll("p")].find((el) => textOf(el) === title);
      const card = note?.parentElement?.parentElement;
      return !![...(card?.querySelectorAll("button") ?? [])].find((el) => textOf(el) === folder);
    }, { title: noteTitle, folder: folderName });
    await page(({ title, folder }) => {
      const note = [...document.querySelectorAll("p")].find((el) => textOf(el) === title);
      const card = note?.parentElement?.parentElement;
      const move = [...(card?.querySelectorAll("button") ?? [])].find((el) => textOf(el) === folder);
      if (!move) throw new Error(`Cannot move ${title} to ${folder}.`);
      move.click();
    }, { title: noteTitle, folder: folderName });
    await clickButton(folderName);
    await waitFor((wanted) => [...document.querySelectorAll("p")]
      .some((el) => textOf(el) === wanted), noteTitle);
    await clickButton("All notes");
    await waitFor((wanted) => [...document.querySelectorAll("button")]
      .some((el) => textOf(el) === wanted), folderName);
  }
  return { noteTitle, folderName };
}

async function settings() {
  await ensureDashboard();
  await page((label) => {
    const link = [...document.querySelectorAll("a")].find((el) => textOf(el) === label);
    if (!link) throw new Error(`Missing navigation control: ${label}`);
    link.click();
  }, "Settings");
  await waitPath("/settings");
  await waitFor(() => document.querySelector("h1")?.textContent?.trim() === "Settings", null);
}

async function visibleSnapshot({ titles = [], folders = [] } = {}) {
  markStage("visible-readback");
  await ensureDashboard();
  const notes = [];
  for (const title of titles) {
    const count = await page((wanted) => [...document.querySelectorAll("p")]
      .filter((el) => textOf(el) === wanted).length, title);
    const seen = new Set();
    for (let attempt = 0; seen.size < count && attempt < count * 3; attempt++) {
      const wantedIndex = attempt % Math.max(1, count);
      await page(({ wanted, index }) => {
        const matches = [...document.querySelectorAll("p")].filter((el) => textOf(el) === wanted);
        const card = matches[index]?.parentElement?.parentElement;
        if (!card) throw new Error(`Cannot open note card ${wanted} at index ${index}.`);
        card.click();
      }, { wanted: title, index: wantedIndex });
      await waitPath("/notes/");
      await waitFor((wanted) => document.querySelector("main input")?.value === wanted, title);
      const href = await page(() => location.pathname);
      const id = href.split("/")[2] ?? href;
      const text = await page(() => document.querySelector("main")?.innerText ?? document.body.innerText);
      if (!seen.has(id)) notes.push({ title, id, href, text });
      seen.add(id);
      await page(() => document.querySelector('button[aria-label="Back to dashboard"]')?.click());
      await waitPath("/");
      await waitFor(() => document.querySelector("h1")?.textContent?.trim() === "Dashboard", null);
    }
    if (seen.size !== count) throw new Error(`Could not traverse all visible ${title} cards by stable route ID.`);
  }
  const folderViews = [];
  for (const name of folders) {
    await waitFor((wanted) => [...document.querySelectorAll("button")]
      .some((el) => textOf(el) === wanted), name);
    const count = await page((wanted) => [...document.querySelectorAll("button")]
      .filter((el) => textOf(el) === wanted).length, name);
    for (let index = 0; index < count; index++) {
      await clickButton(name, index);
      await waitFor(() => document.querySelector("h1")?.textContent?.trim() === "Dashboard", null);
      const visible = await page((wantedTitles) => wantedTitles.filter((wanted) =>
        [...document.querySelectorAll("p")].some((el) => textOf(el) === wanted),
      ), titles);
      folderViews.push({ name, index, visibleTitles: visible });
      await clickButton("All notes");
    }
  }
  return { notes, folderViews };
}

async function downloadEnvelope(filePath) {
  await settings();
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  let timer;
  let listener;
  let rejectDownload;
  const cleanup = () => {
    if (timer) clearTimeout(timer);
    if (listener) window.webContents.session.removeListener("will-download", listener);
  };
  const download = new Promise((resolve, reject) => {
    rejectDownload = reject;
    timer = setTimeout(() => {
      cleanup();
      reject(new Error("Timed out waiting for library download."));
    }, 15000);
    listener = (_event, item) => {
      item.setSavePath(filePath);
      item.once("done", (_doneEvent, state) => {
        cleanup();
        resolve({ state, filename: item.getFilename() });
      });
    };
    window.webContents.session.once("will-download", listener);
  });
  download.catch(() => {});
  try {
    await clickButton("Export notes and folders");
  } catch (error) {
    cleanup();
    rejectDownload(error);
    await download.catch(() => {});
    throw error;
  }
  const result = await download;
  if (result.state !== "completed") throw new Error(`Library download ended ${result.state}.`);
  const bytes = await fs.readFile(filePath);
  assertEnvelope(JSON.parse(bytes.toString("utf8")));
  return { path: filePath, bytes: bytes.length, filename: result.filename };
}

async function installAbortHook() {
  await page(() => {
    const state = { triggered: false, writes: 0 };
    const patch = (method) => {
      const original = IDBObjectStore.prototype[method];
      IDBObjectStore.prototype[method] = function (...values) {
        const request = original.apply(this, values);
        if (!state.triggered && (this.name === "notes" || this.name === "folders") &&
            this.transaction?.mode === "readwrite") {
          state.writes += 1;
          request.addEventListener("success", () => {
            if (state.triggered) return;
            state.triggered = true;
            try { this.transaction.abort(); } catch {}
          }, { once: true });
        }
        return request;
      };
    };
    patch("put");
    patch("add");
    window.__nitroaiTransferAbort = state;
  });
}

async function beginImportObservation() {
  return page(() => {
    window.__nitroaiImportObserver?.observer?.disconnect();
    const state = { generation: 0, feedback: {} };
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        const element = mutation.target.nodeType === Node.ELEMENT_NODE
          ? mutation.target : mutation.target.parentElement;
        const candidates = [element?.closest('[role="alert"],[role="status"]'),
          ...[...mutation.addedNodes].flatMap((node) => node.nodeType === Node.ELEMENT_NODE
            ? [node, ...node.querySelectorAll('[role="alert"],[role="status"]')] : [])];
        for (const candidate of candidates) {
          const role = candidate?.getAttribute("role");
          if ((role === "alert" || role === "status") && candidate.isConnected) {
            state.feedback[role] = { generation: ++state.generation, text: textOf(candidate) };
          }
        }
      }
    });
    observer.observe(document.body, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true,
    });
    window.__nitroaiImportObserver = { state, observer };
    return state.generation;
  });
}

async function waitForVisibleTransferContent(labels) {
  await ensureDashboard();
  if (labels.length === 0) {
    await waitFor(() => [...document.querySelectorAll('[role="status"]')]
      .some((el) => textOf(el).length > 0), null);
    return { mode: "status" };
  }
  await waitFor((wanted) => wanted.every((label) =>
    [...document.querySelectorAll("p,button")].some((el) => textOf(el) === label),
  ), labels);
  return { mode: "visible-record", labels };
}

async function submitImport(filePath, expectRejected, abort = false) {
  await settings();
  if (abort) await installAbortHook();
  const bytes = await fs.readFile(filePath);
  let envelope = null;
  try { envelope = assertEnvelope(JSON.parse(bytes.toString("utf8"))); } catch {}
  await clickButton("Import notes and folders");
  await waitFor(() => !!document.querySelector('input[type="file"]'), null);
  const generation = await beginImportObservation();
  await page(({ name, base64 }) => {
    const input = document.querySelector('input[type="file"]');
    if (!(input instanceof HTMLInputElement)) throw new Error("Missing import file input.");
    const data = Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
    const file = new File([data], name, { type: "application/json" });
    const transfer = new DataTransfer();
    transfer.items.add(file);
    input.files = transfer.files;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }, { name: path.basename(filePath), base64: bytes.toString("base64") });
  let alert = null;
  if (expectRejected) {
    alert = await waitFor((beforeGeneration) => {
      const state = window.__nitroaiImportObserver?.state;
      const feedback = state?.feedback.alert;
      return feedback?.generation > beforeGeneration && feedback.text ? feedback.text : null;
    }, generation, 5000);
  }
  const abortState = await page(() => window.__nitroaiTransferAbort ?? null);
  if (expectRejected && !alert) throw new Error("Import did not expose a role=alert rejection.");
  if (abort && !abortState?.triggered) throw new Error("Native IndexedDB abort hook did not trigger.");
  if (!expectRejected) {
    const operationMutation = await waitFor((beforeGeneration) => {
      const state = window.__nitroaiImportObserver?.state;
      const feedback = state?.feedback.status;
      return feedback?.generation > beforeGeneration &&
        /import|already|skip|nothing/i.test(feedback.text) &&
        !/importing|loading|please wait|working/i.test(feedback.text)
        ? feedback.generation : null;
    }, generation, 5000);
    const error = await page(() => [...document.querySelectorAll('[role="alert"]')]
      .map((el) => textOf(el)).find((text) => text.length > 0) || null);
    if (error) throw new Error(`Valid import was rejected: ${error}`);
    const labels = [
      ...(envelope?.notes ?? []).map((note) => note.title),
      ...(envelope?.folders ?? []).map((folder) => folder.name),
    ];
    const completion = await waitForVisibleTransferContent(labels);
    return { outcome: "accepted", completion, operationMutation, abort: abortState };
  }
  return { outcome: "rejected", alert: true, abort: abortState };
}

async function importFiles(operations) {
  const results = [];
  for (const operation of operations) {
    results.push(await submitImport(operation.path, operation.expected === "rejected", operation.abort));
  }
  return results;
}

async function readiness() {
  markStage("readiness-controls");
  await ensureDashboard();
  const controls = await page(() => ["Blank document", "New Folder"].map((label) => ({
    label,
    present: [...document.querySelectorAll("button")].some((el) => textOf(el).includes(label)),
  })));
  if (controls.some((control) => !control.present)) throw new UnsupportedUI("Baseline note/folder controls are missing.");
  await seed({
    noteTitle: "Transfer readiness note",
    body: "The hidden native fixture can seed and reopen this note.",
    folderName: "Transfer readiness folder",
  });
  const snapshot = await visibleSnapshot({
    titles: ["Transfer readiness note"],
    folders: ["Transfer readiness folder"],
  });
  if (!snapshot.notes[0]?.text.includes("hidden native fixture")) {
    throw new Error("Readiness note body was not visible after seeding.");
  }
  if (!snapshot.folderViews[0]?.visibleTitles.includes("Transfer readiness note")) {
    throw new Error("Readiness folder membership was not visible after seeding.");
  }
  return { mode: "readiness", controls, snapshot };
}

async function run() {
  markStage("profile-directories");
  markStage("app-when-ready");
  await app.whenReady();
  if (app.getPath("userData") !== userData || app.getPath("sessionData") !== sessionData) {
    throw new Error("Electron did not retain the private fixture profile paths.");
  }
  ({ openProfileServer } = await import(
    pathToFileURL(path.join(TARGET, "electron/persistence.mjs")).href,
  ));
  markStage("profile-server");
  info = await openProfileServer({ userData, sessionData, distDir: DIST });
  markStage("browser-window");
  window = new BrowserWindow({
    show: false,
    webPreferences: { contextIsolation: true, nodeIntegration: false, backgroundThrottling: false },
  });
  window.webContents.on("select-file", (event) => event.preventDefault());
  const allowedOrigin = new URL(info.url).origin;
  window.webContents.session.webRequest.onBeforeRequest(
    { urls: ["http://*/*", "https://*/*"] },
    (details, callback) => {
      const url = new URL(details.url);
      const readOnly = details.method === "GET" || details.method === "HEAD";
      const asset = !url.pathname.startsWith("/api/");
      const health = details.method === "GET" && url.pathname === "/api/health" && !url.search;
      callback({ cancel: url.origin !== allowedOrigin || !readOnly || (!asset && !health) });
    },
  );
  markStage("load-url");
  await window.loadURL(info.url);
  markStage("page-loaded");
  if (action === "readiness") return readiness();
  if (action === "seed-export") {
    const seeded = await seed(args.seed);
    return { seed: seeded, export: await downloadEnvelope(args.exportPath) };
  }
  if (action === "restart-snapshot") {
    const visible = await visibleSnapshot(args.read);
    return { visible, export: await downloadEnvelope(args.exportPath) };
  }
  if (action === "import-roundtrip") {
    await importFiles([{ path: args.libraryPath, expected: "accepted" }]);
    const before = await downloadEnvelope(args.beforePath);
    await importFiles([{ path: args.originalPath, expected: "accepted" }]);
    return { before, after: await downloadEnvelope(args.afterPath) };
  }
  if (action === "transfer-journey") {
    const firstImports = await importFiles(args.firstImport);
    const opened = await visibleSnapshot(args.open);
    const secondImports = await importFiles(args.secondImport);
    const beforeAbort = await downloadEnvelope(args.beforeAbortPath);
    const failed = { imports: await importFiles([{ path: args.abortPath, expected: "rejected", abort: true }]) };
    const afterAbort = await downloadEnvelope(args.afterAbortPath);
    const visible = await visibleSnapshot(args.read);
    return { firstImports, opened, secondImports, beforeAbort, failed, afterAbort, visible };
  }
  if (action === "seed") return seed(args);
  if (action === "read") return visibleSnapshot(args);
  if (action === "export") return downloadEnvelope(args.path);
  if (action === "import") return { imports: await importFiles(args.operations) };
  if (action === "force-write-failure") {
    return { imports: await importFiles([{ path: args.path, expected: "rejected", abort: true }]) };
  }
  throw new Error(`Unknown transfer fixture action ${action}.`);
}

async function main() {
  try {
    const result = await run();
    console.log(`NITROAI_TRANSFER_RESULT ${JSON.stringify({ status: "ok", result })}`);
  } catch (error) {
    let url = "";
    let visibleText = "";
    try {
      url = window?.webContents?.getURL?.() ?? info?.url ?? "";
      if (window && !window.isDestroyed()) {
        visibleText = await Promise.race([
          window.webContents.executeJavaScript("document.body?.innerText ?? ''"),
          new Promise((resolve) => setTimeout(() => resolve("<DOM snapshot timed out>"), 750)),
        ]);
      }
    } catch (snapshotError) {
      visibleText = `<DOM snapshot failed: ${snapshotError.message}>`;
    }
    try {
      await fs.mkdir(profileRoot, { recursive: true });
      await fs.writeFile(path.join(profileRoot, "transfer-failure-artifact.json"), JSON.stringify({
        action,
        stage: currentStage,
        url,
        visibleText: String(visibleText).slice(0, 12000),
        trace: stageTrace,
        error: error.message,
      }, null, 2), "utf8");
    } catch {}
    console.error(`NITROAI_FAILURE_STAGE ${currentStage}`);
    console.error(`NITROAI_FAILURE_URL ${url}`);
    console.error(`NITROAI_FAILURE_DOM ${String(visibleText).slice(0, 1200)}`);
    const status = error?.kind === "unsupported" ? "unsupported" : "error";
    console.log(`NITROAI_TRANSFER_RESULT ${JSON.stringify({ status, error: error.message })}`);
  } finally {
    if (window && !window.isDestroyed()) window.destroy();
    if (info?.server) await new Promise((resolve) => info.server.close(resolve));
    app.quit();
  }
}

void main();

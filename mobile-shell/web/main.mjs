import {
  PackageValidationError,
  UnsupportedCapabilityError,
  authorizeVerifiedPackageForLocalStorage,
  makeEditRequest,
  parsePackageJson,
  validateRevisionTransition,
  verifyPackageTransport,
} from "./runtime.mjs";
import { ContentStore } from "./storage.mjs";
import { SandboxedAppHost } from "./sandbox.mjs";
import { DEMO_APP_ID, buildDemoPackages } from "./demo/notes-demo.mjs";

const $ = (selector) => document.querySelector(selector);

const elements = {
  homeButton: $("#home-button"),
  importButton: $("#import-button"),
  heroImportButton: $("#hero-import-button"),
  packageFile: $("#package-file"),
  networkPill: $("#network-pill"),
  offlineNotice: $("#offline-notice"),
  errorNotice: $("#error-notice"),
  errorText: $("#error-text"),
  errorClose: $("#error-close"),
  shellUpdate: $("#shell-update"),
  activateShellUpdate: $("#activate-shell-update"),
  libraryView: $("#library-view"),
  detailView: $("#detail-view"),
  appList: $("#app-list"),
  appCount: $("#app-count"),
  emptyLibrary: $("#empty-library"),
  installDemoButton: $("#install-demo-button"),
  backButton: $("#back-button"),
  detailIcon: $("#detail-icon"),
  detailAppId: $("#detail-app-id"),
  detailName: $("#detail-name"),
  detailRevision: $("#detail-revision"),
  compatibilityCard: $("#compatibility-card"),
  compatibilityTitle: $("#compatibility-title"),
  compatibilityDetail: $("#compatibility-detail"),
  openAppButton: $("#open-app-button"),
  demoUpdateButton: $("#demo-update-button"),
  revisionList: $("#revision-list"),
  editForm: $("#edit-form"),
  editType: $("#edit-type"),
  editText: $("#edit-text"),
  createEditButton: $("#create-edit-button"),
  requestReview: $("#request-review"),
  requestTitle: $("#request-title"),
  requestDetail: $("#request-detail"),
  exportRequestButton: $("#export-request-button"),
  requestList: $("#request-list"),
  deploymentState: $("#deployment-state"),
  runtimeDialog: $("#runtime-dialog"),
  runtimeTitle: $("#runtime-title"),
  appFrame: $("#app-frame"),
  closeRuntime: $("#close-runtime"),
  toast: $("#toast"),
};

const store = new ContentStore();
const state = {
  selectedAppId: null,
  currentRequest: null,
  toastTimer: 0,
  swRegistration: null,
  reloadOnControllerChange: false,
};

const sandboxHost = new SandboxedAppHost(elements.appFrame, {
  onError(error) {
    showError(error instanceof Error ? error.message : "App storage request failed");
  },
});

function showToast(message) {
  window.clearTimeout(state.toastTimer);
  elements.toast.textContent = message;
  elements.toast.classList.add("is-visible");
  state.toastTimer = window.setTimeout(() => elements.toast.classList.remove("is-visible"), 2600);
}

function showError(message) {
  elements.errorText.textContent = String(message || "Something went wrong.");
  elements.errorNotice.hidden = false;
}

function clearError() {
  elements.errorNotice.hidden = true;
  elements.errorText.textContent = "";
}

function errorMessage(error) {
  if (error instanceof UnsupportedCapabilityError && error.capabilities?.length) {
    return error.capabilities.map((item) => `${item.capability}: ${item.reason}`).join(" ");
  }
  return error instanceof Error ? error.message : String(error || "Unexpected error");
}

function shortRevision(value) {
  const text = String(value || "");
  return text.startsWith("rev-sha256:") ? `rev…${text.slice(-10)}` : text || "No active revision";
}

function initials(name) {
  return String(name || "I")
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase())
    .join("") || "I";
}

function showLibrary() {
  state.selectedAppId = null;
  state.currentRequest = null;
  elements.detailView.hidden = true;
  elements.libraryView.hidden = false;
  document.title = "Iris · Apps";
  renderLibrary().catch((error) => showError(errorMessage(error)));
}

async function renderLibrary() {
  const apps = await store.listApps();
  elements.appList.replaceChildren();
  elements.appCount.textContent = String(apps.length);
  elements.emptyLibrary.hidden = apps.length > 0;
  for (const app of apps) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "app-row";
    const identity = document.createElement("span");
    identity.className = "app-row__identity";
    const name = document.createElement("strong");
    name.textContent = app.name;
    const detail = document.createElement("span");
    detail.textContent = `${app.appId} · ${shortRevision(app.activeRevisionId)}`;
    identity.append(name, detail);
    const rowState = document.createElement("span");
    rowState.className = "row-state";
    rowState.textContent = app.activeRevisionId ? "Ready" : "Inactive";
    button.append(identity, rowState);
    button.addEventListener("click", () => selectApp(app.appId));
    elements.appList.append(button);
  }
}

async function selectApp(appId) {
  state.selectedAppId = appId;
  state.currentRequest = null;
  elements.libraryView.hidden = true;
  elements.detailView.hidden = false;
  await renderDetail();
  window.scrollTo({ top: 0, behavior: "auto" });
}

async function selectedRecords() {
  if (!state.selectedAppId) return null;
  const app = await store.getApp(state.selectedAppId);
  if (!app) return null;
  const active = app.activeRevisionId
    ? await store.getRevision(app.appId, app.activeRevisionId)
    : null;
  const revisions = await store.listRevisions(app.appId);
  const requests = await store.listEditRequests(app.appId);
  return { app, active, revisions, requests };
}

function renderCompatibility(active, revisions) {
  if (!active) {
    const staged = revisions[0]?.package;
    const incompatible = staged && !staged.compatible;
    elements.compatibilityCard.dataset.state = incompatible ? "unsupported" : "missing";
    elements.compatibilityTitle.textContent = incompatible ? "Downloaded, not supported here" : "No active revision";
    elements.compatibilityDetail.textContent = incompatible
      ? [
          ...(staged.compatibilityReasons || []),
          ...(staged.unsupportedCapabilities || []).map((item) => `${item.capability}: ${item.reason}`),
        ].join(" ")
      : "Import or activate a compatible verified revision before opening this app.";
    elements.openAppButton.disabled = true;
    return;
  }
  const pkg = active.package;
  if (!pkg.compatible) {
    elements.compatibilityCard.dataset.state = "unsupported";
    elements.compatibilityTitle.textContent = "This revision needs unsupported capabilities";
    elements.compatibilityDetail.textContent = [
      ...(pkg.compatibilityReasons || []),
      ...(pkg.unsupportedCapabilities || []).map((item) => `${item.capability}: ${item.reason}`),
    ].join(" ");
    elements.openAppButton.disabled = true;
    return;
  }
  elements.compatibilityCard.dataset.state = "ready";
  elements.compatibilityTitle.textContent = navigator.onLine ? "Verified and ready" : "Verified and ready offline";
  elements.compatibilityDetail.textContent = "Iris opens the locally verified revision in an opaque sandbox. App user data is stored separately from revision content.";
  elements.openAppButton.disabled = false;
}

function revisionButtonLabel(app, active, record) {
  if (record.revisionId === app.activeRevisionId) return "Active";
  if (!record.package.compatible) return "Unsupported";
  if (!active && record.package.revision.baseRevisionId === null) return "Activate";
  if (active && record.package.revision.baseRevisionId === active.revisionId) return "Activate update";
  if (Array.isArray(app.activationHistory) && app.activationHistory.includes(record.revisionId)) return "Revert";
  return "Stale candidate";
}

async function activateRevision(record) {
  const current = await selectedRecords();
  if (!current) return;
  const label = revisionButtonLabel(current.app, current.active, record);
  if (label === "Active" || label === "Unsupported" || label === "Stale candidate") return;
  if (label === "Activate" || label === "Activate update") {
    validateRevisionTransition(current.active?.package?.revision || null, record.package.revision);
  }
  await store.setActiveRevision(current.app.appId, record.revisionId, {
    expectedCurrent: current.app.activeRevisionId,
  });
  await renderDetail();
  showToast(label === "Revert" ? "Reverted to an earlier verified revision. App data was kept." : "Verified revision activated. App data was kept.");
}

function renderRevisions(app, active, revisions) {
  elements.revisionList.replaceChildren();
  for (const record of revisions) {
    const row = document.createElement("div");
    row.className = "revision-row";
    const identity = document.createElement("div");
    identity.className = "revision-row__identity";
    const title = document.createElement("strong");
    title.textContent = record.revisionId === app.activeRevisionId ? "Current revision" : "Verified revision";
    const detail = document.createElement("span");
    detail.textContent = `${shortRevision(record.revisionId)} · ${new Date(record.installedAt).toLocaleString()}`;
    identity.append(title, detail);
    const actions = document.createElement("div");
    actions.className = "revision-actions";
    const action = document.createElement("button");
    action.type = "button";
    action.className = "row-button";
    const label = revisionButtonLabel(app, active, record);
    action.textContent = label;
    action.disabled = ["Active", "Unsupported", "Stale candidate"].includes(label);
    action.addEventListener("click", () => activateRevision(record).catch((error) => showError(errorMessage(error))));
    actions.append(action);
    row.append(identity, actions);
    elements.revisionList.append(row);
  }
}

function exportJson(filename, value) {
  const blob = new Blob([JSON.stringify(value, null, 2)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  anchor.rel = "noopener";
  document.body.append(anchor);
  anchor.click();
  anchor.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 0);
}

function renderRequestReview(request) {
  state.currentRequest = request || null;
  elements.requestReview.hidden = !request;
  if (!request) return;
  elements.requestTitle.textContent = `${request.intent.type === "bugfix" ? "Bug fix" : "Feature"} request ready`;
  elements.requestDetail.textContent = `${shortRevision(request.baseRevisionId)} · waiting for the trusted desktop edit/review flow`;
}

function renderRequests(requests) {
  elements.requestList.replaceChildren();
  for (const request of requests) {
    const row = document.createElement("div");
    row.className = "request-row";
    const identity = document.createElement("div");
    identity.className = "request-row__identity";
    const title = document.createElement("strong");
    title.textContent = request.intent.text;
    const detail = document.createElement("span");
    detail.textContent = `${request.requestId} · awaiting desktop review`;
    identity.append(title, detail);
    const actions = document.createElement("div");
    actions.className = "request-actions";
    const exportButton = document.createElement("button");
    exportButton.type = "button";
    exportButton.className = "row-button";
    exportButton.textContent = "Export";
    exportButton.addEventListener("click", () => exportJson(`${request.requestId}.json`, request));
    actions.append(exportButton);
    row.append(identity, actions);
    elements.requestList.append(row);
  }
}

async function renderDetail() {
  const records = await selectedRecords();
  if (!records) {
    showLibrary();
    return;
  }
  const { app, active, revisions, requests } = records;
  elements.detailIcon.textContent = initials(app.name);
  elements.detailAppId.textContent = app.appId;
  elements.detailName.textContent = app.name;
  elements.detailRevision.textContent = app.activeRevisionId ? shortRevision(app.activeRevisionId) : "No active compatible revision";
  document.title = `Iris · ${app.name}`;
  renderCompatibility(active, revisions);
  renderRevisions(app, active, revisions);
  renderRequests(requests);
  renderRequestReview(null);
  elements.editForm.hidden = !active;
  elements.demoUpdateButton.hidden = app.appId !== DEMO_APP_ID || revisions.length >= 2;
}

async function installDemo() {
  clearError();
  const existing = await store.getApp(DEMO_APP_ID);
  if (existing) {
    await selectApp(DEMO_APP_ID);
    showToast("Iris Notes Demo is already installed.");
    return;
  }
  elements.installDemoButton.disabled = true;
  try {
    const packages = await buildDemoPackages();
    const verified = await verifyPackageTransport(packages.v1, {
      currentRevisionId: null,
      usedDeliveryNonces: await store.usedDeliveryNonces(),
    });
    validateRevisionTransition(null, verified.revision);
    const localApproval = authorizeVerifiedPackageForLocalStorage(verified);
    await store.saveVerifiedPackage(verified, { activateInitial: true, localApproval });
    await selectApp(DEMO_APP_ID);
    showToast("Local demo installed from verified bundled bytes.");
  } finally {
    elements.installDemoButton.disabled = false;
  }
}

async function loadDemoUpdate() {
  clearError();
  const records = await selectedRecords();
  if (!records || records.app.appId !== DEMO_APP_ID || !records.active) return;
  const packages = await buildDemoPackages();
  const verified = await verifyPackageTransport(packages.v2, {
    currentRevisionId: records.active.revisionId,
    usedDeliveryNonces: await store.usedDeliveryNonces(),
  });
  validateRevisionTransition(records.active.package.revision, verified.revision);
  const localApproval = authorizeVerifiedPackageForLocalStorage(verified);
  await store.saveVerifiedPackage(verified, { activateInitial: false, localApproval });
  await renderDetail();
  showToast("Demo update verified and staged. Review its revision before activating it.");
}

async function readImportFile(file) {
  if (!file) return;
  clearError();
  if (file.size > 45 * 1024 * 1024) {
    throw new PackageValidationError("Package file is larger than the web-shell import limit", "package_too_large");
  }
  const transport = parsePackageJson(await file.text());
  const appId = transport.envelope?.appId;
  const existingApp = appId ? await store.getApp(appId) : null;
  const active = existingApp?.activeRevisionId
    ? await store.getRevision(existingApp.appId, existingApp.activeRevisionId)
    : null;
  const requestId = transport.approval?.requestId;
  const editRequest = requestId ? await store.getEditRequest(requestId) : undefined;
  const verified = await verifyPackageTransport(transport, {
    currentRevisionId: existingApp ? existingApp.activeRevisionId : null,
    usedDeliveryNonces: await store.usedDeliveryNonces(),
    editRequest,
  });
  validateRevisionTransition(active?.package?.revision || null, verified.revision);
  if (existingApp) {
    if (existingApp.projectId !== verified.revision.projectId) {
      throw new PackageValidationError("Imported revision belongs to a different project than the installed app", "wrong_project");
    }
    if (existingApp.dataNamespace !== verified.manifest.data.namespace) {
      throw new PackageValidationError("Imported revision changes the v1 user-data namespace", "userdata_namespace_changed");
    }
  }
  const approved = window.confirm(
    `Store verified revision ${verified.revision.revisionId} for ${verified.manifest.displayName}?\n\nThis local review authorizes only this exact app, project, base, content hash, and delivery nonce.`
  );
  if (!approved) {
    showToast("Verified package was not stored because local approval was declined.");
    return;
  }
  const localApproval = authorizeVerifiedPackageForLocalStorage(verified);
  await store.saveVerifiedPackage(verified, {
    activateInitial: !existingApp && verified.compatible,
    localApproval,
  });
  await selectApp(verified.revision.appId);
  if (!verified.compatible) {
    showToast("Revision verified and stored inactive because it is not compatible with this web shell.");
  } else if (existingApp) {
    showToast(requestId ? "Request-bound delivery verified and staged for your review." : "Verified update staged. Activate it when you are ready.");
  } else {
    showToast("Verified app installed locally.");
  }
}

async function openSelectedApp() {
  const records = await selectedRecords();
  if (!records?.active) throw new PackageValidationError("This app has no active revision", "revision_missing");
  if (!records.active.package.compatible) {
    throw new UnsupportedCapabilityError(records.active.package.unsupportedCapabilities || []);
  }
  sandboxHost.open(records.active.package);
  elements.runtimeTitle.textContent = records.app.name;
  if (typeof elements.runtimeDialog.showModal === "function") elements.runtimeDialog.showModal();
  else elements.runtimeDialog.setAttribute("open", "");
}

function closeRuntime() {
  sandboxHost.close();
  if (elements.runtimeDialog.open && typeof elements.runtimeDialog.close === "function") elements.runtimeDialog.close();
  else elements.runtimeDialog.removeAttribute("open");
}

async function createEditRequest(event) {
  event.preventDefault();
  clearError();
  const records = await selectedRecords();
  if (!records?.active) throw new PackageValidationError("Activate a revision before requesting an edit", "revision_missing");
  const request = makeEditRequest(
    {
      appId: records.active.package.revision.appId,
      projectId: records.active.package.revision.projectId,
      baseRevisionId: records.active.package.revision.revisionId,
      intentType: elements.editType.value,
      intentText: elements.editText.value,
    },
    { usedNonces: await store.usedRequestNonces() }
  );
  await store.saveEditRequest(request);
  elements.editText.value = "";
  renderRequestReview(request);
  renderRequests(await store.listEditRequests(records.app.appId));
  showToast("Edit request created locally. It is waiting for desktop review.");
}

function renderNetworkState() {
  const online = navigator.onLine;
  elements.networkPill.dataset.state = online ? "online" : "offline";
  elements.networkPill.textContent = online ? "Online" : "Offline";
  elements.offlineNotice.hidden = online;
  if (state.selectedAppId) renderDetail().catch(() => {});
}

function showWaitingWorker(registration) {
  state.swRegistration = registration;
  elements.shellUpdate.hidden = !registration?.waiting;
}

async function registerServiceWorker() {
  if (!("serviceWorker" in navigator) || !["http:", "https:"].includes(location.protocol)) {
    elements.deploymentState.textContent = "This local preview is not running under a service-worker-capable origin. Home Screen installation and offline shell caching require HTTPS (or localhost) and separate browser/device verification.";
    return;
  }
  try {
    const registration = await navigator.serviceWorker.register("./sw.js", { scope: "./" });
    state.swRegistration = registration;
    if (registration.waiting && navigator.serviceWorker.controller) showWaitingWorker(registration);
    registration.addEventListener("updatefound", () => {
      const worker = registration.installing;
      if (!worker) return;
      worker.addEventListener("statechange", () => {
        if (worker.state === "installed" && navigator.serviceWorker.controller) showWaitingWorker(registration);
      });
    });
    navigator.serviceWorker.addEventListener("controllerchange", () => {
      if (state.reloadOnControllerChange) location.reload();
    });
  } catch (error) {
    elements.deploymentState.textContent = `Service worker registration failed in this preview: ${errorMessage(error)} Installed revision data remains separate in IndexedDB when available.`;
  }
}

function activateShellUpdate() {
  const registration = state.swRegistration;
  if (!registration?.waiting) return;
  const draft = elements.editText.value.trim();
  if (draft && !window.confirm("Refreshing Iris will discard the unsent edit-request text on this screen. Continue?")) return;
  state.reloadOnControllerChange = true;
  registration.waiting.postMessage({ type: "ACTIVATE_UPDATE" });
}

function bindEvents() {
  elements.homeButton.addEventListener("click", showLibrary);
  elements.backButton.addEventListener("click", showLibrary);
  const openPicker = () => elements.packageFile.click();
  elements.importButton.addEventListener("click", openPicker);
  elements.heroImportButton.addEventListener("click", openPicker);
  elements.packageFile.addEventListener("change", async () => {
    const [file] = elements.packageFile.files || [];
    elements.packageFile.value = "";
    if (!file) return;
    try {
      await readImportFile(file);
    } catch (error) {
      showError(errorMessage(error));
    }
  });
  elements.installDemoButton.addEventListener("click", () => installDemo().catch((error) => showError(errorMessage(error))));
  elements.demoUpdateButton.addEventListener("click", () => loadDemoUpdate().catch((error) => showError(errorMessage(error))));
  elements.openAppButton.addEventListener("click", () => openSelectedApp().catch((error) => showError(errorMessage(error))));
  elements.closeRuntime.addEventListener("click", closeRuntime);
  elements.runtimeDialog.addEventListener("close", () => sandboxHost.close());
  elements.editForm.addEventListener("submit", (event) => createEditRequest(event).catch((error) => showError(errorMessage(error))));
  elements.exportRequestButton.addEventListener("click", () => {
    if (state.currentRequest) exportJson(`${state.currentRequest.requestId}.json`, state.currentRequest);
  });
  elements.errorClose.addEventListener("click", clearError);
  elements.activateShellUpdate.addEventListener("click", activateShellUpdate);
  window.addEventListener("online", renderNetworkState);
  window.addEventListener("offline", renderNetworkState);
}

async function init() {
  bindEvents();
  renderNetworkState();
  await renderLibrary();
  await registerServiceWorker();
}

init().catch((error) => showError(errorMessage(error)));

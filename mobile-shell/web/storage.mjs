import {
  PackageValidationError,
  consumeLocalReaderApproval,
  userDataDatabaseName,
  validateAppId,
  validateRevisionId,
  validateStableId,
} from "./runtime.mjs";

const CONTENT_DB = "iris-mobile-content-v1";
const CONTENT_DB_VERSION = 2;
const MAX_USER_VALUE_BYTES = 64 * 1024;
const USER_KEY_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const ENCODER = new TextEncoder();

function idbApi() {
  if (!globalThis.indexedDB) {
    throw new PackageValidationError("IndexedDB is unavailable in this browser", "storage_unavailable");
  }
  return globalThis.indexedDB;
}

function requestAsPromise(request) {
  return new Promise((resolve, reject) => {
    request.addEventListener("success", () => resolve(request.result), { once: true });
    request.addEventListener("error", () => reject(request.error || new Error("IndexedDB request failed")), {
      once: true,
    });
  });
}

function transactionDone(transaction) {
  return new Promise((resolve, reject) => {
    transaction.addEventListener("complete", () => resolve(), { once: true });
    transaction.addEventListener("abort", () => reject(transaction.error || new Error("IndexedDB transaction aborted")), {
      once: true,
    });
    transaction.addEventListener("error", () => reject(transaction.error || new Error("IndexedDB transaction failed")), {
      once: true,
    });
  });
}

function openContentDb() {
  const request = idbApi().open(CONTENT_DB, CONTENT_DB_VERSION);
  request.addEventListener("upgradeneeded", () => {
    const db = request.result;
    if (!db.objectStoreNames.contains("apps")) db.createObjectStore("apps", { keyPath: "appId" });
    if (!db.objectStoreNames.contains("revisions")) {
      const store = db.createObjectStore("revisions", { keyPath: "key" });
      store.createIndex("byApp", "appId", { unique: false });
      store.createIndex("byDeliveryNonce", "deliveryNonce", { unique: true });
    } else {
      const store = request.transaction.objectStore("revisions");
      if (!store.indexNames.contains("byDeliveryNonce")) {
        store.createIndex("byDeliveryNonce", "deliveryNonce", { unique: true });
      }
    }
    if (!db.objectStoreNames.contains("editRequests")) {
      const store = db.createObjectStore("editRequests", { keyPath: "requestId" });
      store.createIndex("byApp", "appId", { unique: false });
      store.createIndex("byNonce", "nonce", { unique: true });
    } else {
      const store = request.transaction.objectStore("editRequests");
      if (!store.indexNames.contains("byNonce")) store.createIndex("byNonce", "nonce", { unique: true });
    }
  });
  return requestAsPromise(request);
}

function revisionKey(appId, revisionId) {
  return `${validateAppId(appId)}::${validateRevisionId(revisionId)}`;
}

function clonePackageForStorage(verifiedPackage) {
  return {
    approval: structuredClone(verifiedPackage.approval),
    envelope: structuredClone(verifiedPackage.envelope),
    revision: structuredClone(verifiedPackage.revision),
    manifest: structuredClone(verifiedPackage.manifest),
    files: verifiedPackage.files.map((file) => ({
      path: file.path,
      mime: file.mime,
      bytes: file.bytes instanceof Uint8Array ? file.bytes.slice() : new Uint8Array(file.bytes),
    })),
    compatible: Boolean(verifiedPackage.compatible),
    compatibilityReasons: structuredClone(verifiedPackage.compatibilityReasons || []),
    unsupportedCapabilities: structuredClone(verifiedPackage.unsupportedCapabilities || []),
    verifiedAt: verifiedPackage.verifiedAt || new Date().toISOString(),
  };
}

export class ContentStore {
  async saveVerifiedPackage(verifiedPackage, { activateInitial = true, localApproval } = {}) {
    consumeLocalReaderApproval(verifiedPackage, localApproval);
    const appId = validateAppId(verifiedPackage?.revision?.appId);
    const revisionId = validateRevisionId(verifiedPackage?.revision?.revisionId);
    const deliveryNonce = String(verifiedPackage?.envelope?.deliveryNonce || "");
    if (!deliveryNonce) throw new PackageValidationError("Verified package is missing a delivery nonce", "invalid_delivery");
    const db = await openContentDb();
    try {
      const tx = db.transaction(["apps", "revisions"], "readwrite");
      const apps = tx.objectStore("apps");
      const revisions = tx.objectStore("revisions");
      const existingApp = await requestAsPromise(apps.get(appId));
      if (
        existingApp &&
        (existingApp.projectId !== verifiedPackage.revision.projectId ||
          existingApp.dataNamespace !== verifiedPackage.manifest.data.namespace)
      ) {
        throw new PackageValidationError(
          "Verified revision does not preserve the installed app project and user-data namespace",
          "identity_mismatch"
        );
      }
      const existingRevision = await requestAsPromise(revisions.get(revisionKey(appId, revisionId)));
      if (existingRevision) {
        throw new PackageValidationError("This revision is already installed", "duplicate_revision");
      }
      const replay = await requestAsPromise(revisions.index("byDeliveryNonce").get(deliveryNonce));
      if (replay) throw new PackageValidationError("This delivery nonce was already received", "replayed_delivery");
      const record = {
        key: revisionKey(appId, revisionId),
        appId,
        projectId: verifiedPackage.revision.projectId,
        revisionId,
        deliveryNonce,
        installedAt: new Date().toISOString(),
        package: clonePackageForStorage(verifiedPackage),
      };
      revisions.put(record);
      apps.put({
        appId,
        projectId: verifiedPackage.revision.projectId,
        dataNamespace: verifiedPackage.manifest.data.namespace,
        name: verifiedPackage.manifest.displayName,
        activeRevisionId:
          existingApp?.activeRevisionId || (activateInitial ? revisionId : null),
        activationHistory:
          existingApp?.activationHistory || (activateInitial ? [revisionId] : []),
        updatedAt: new Date().toISOString(),
      });
      await transactionDone(tx);
      return record;
    } finally {
      db.close();
    }
  }

  async listApps() {
    const db = await openContentDb();
    try {
      const tx = db.transaction("apps", "readonly");
      const result = await requestAsPromise(tx.objectStore("apps").getAll());
      await transactionDone(tx);
      return result.sort((a, b) => a.name.localeCompare(b.name));
    } finally {
      db.close();
    }
  }

  async getApp(appId) {
    appId = validateAppId(appId);
    const db = await openContentDb();
    try {
      const tx = db.transaction("apps", "readonly");
      const result = await requestAsPromise(tx.objectStore("apps").get(appId));
      await transactionDone(tx);
      return result || null;
    } finally {
      db.close();
    }
  }

  async listRevisions(appId) {
    appId = validateAppId(appId);
    const db = await openContentDb();
    try {
      const tx = db.transaction("revisions", "readonly");
      const result = await requestAsPromise(tx.objectStore("revisions").index("byApp").getAll(appId));
      await transactionDone(tx);
      return result.sort((a, b) => b.installedAt.localeCompare(a.installedAt));
    } finally {
      db.close();
    }
  }

  async getRevision(appId, revisionId) {
    const key = revisionKey(appId, revisionId);
    const db = await openContentDb();
    try {
      const tx = db.transaction("revisions", "readonly");
      const result = await requestAsPromise(tx.objectStore("revisions").get(key));
      await transactionDone(tx);
      return result || null;
    } finally {
      db.close();
    }
  }

  async getActivePackage(appId) {
    const app = await this.getApp(appId);
    if (!app?.activeRevisionId) return null;
    const revision = await this.getRevision(app.appId, app.activeRevisionId);
    return revision?.package || null;
  }

  async setActiveRevision(appId, revisionId, { expectedCurrent = undefined } = {}) {
    appId = validateAppId(appId);
    revisionId = validateRevisionId(revisionId);
    const db = await openContentDb();
    try {
      const tx = db.transaction(["apps", "revisions"], "readwrite");
      const apps = tx.objectStore("apps");
      const revisions = tx.objectStore("revisions");
      const app = await requestAsPromise(apps.get(appId));
      if (!app) throw new PackageValidationError("App is not installed", "app_missing");
      if (expectedCurrent !== undefined && app.activeRevisionId !== expectedCurrent) {
        throw new PackageValidationError("Active revision changed before activation", "stale_active_revision");
      }
      const target = await requestAsPromise(revisions.get(revisionKey(appId, revisionId)));
      if (!target) throw new PackageValidationError("Target revision is not installed", "revision_missing");
      if (!target.package.compatible) {
        throw new PackageValidationError("Target revision is not compatible with this web shell", "unsupported_capability");
      }
      if (target.projectId !== app.projectId || target.package.manifest.data.namespace !== app.dataNamespace) {
        throw new PackageValidationError("Target revision does not preserve app identity and user data", "identity_mismatch");
      }
      app.activeRevisionId = revisionId;
      const history = Array.isArray(app.activationHistory) ? app.activationHistory : [];
      if (!history.includes(revisionId)) history.push(revisionId);
      app.activationHistory = history;
      app.updatedAt = new Date().toISOString();
      apps.put(app);
      await transactionDone(tx);
      return app;
    } finally {
      db.close();
    }
  }

  async usedDeliveryNonces() {
    const db = await openContentDb();
    try {
      const tx = db.transaction("revisions", "readonly");
      const records = await requestAsPromise(tx.objectStore("revisions").getAll());
      await transactionDone(tx);
      return new Set(records.map((record) => record.deliveryNonce).filter(Boolean));
    } finally {
      db.close();
    }
  }

  async saveEditRequest(request) {
    if (!request || typeof request !== "object") {
      throw new PackageValidationError("Edit request is invalid", "invalid_edit_request");
    }
    const requestId = String(request.requestId || "");
    const nonce = String(request.nonce || "");
    const appId = validateAppId(request.appId);
    const db = await openContentDb();
    try {
      const tx = db.transaction("editRequests", "readwrite");
      const store = tx.objectStore("editRequests");
      const existing = await requestAsPromise(store.get(requestId));
      if (existing) throw new PackageValidationError("Edit request ID was already used", "replayed_edit_request");
      const nonceReplay = await requestAsPromise(store.index("byNonce").get(nonce));
      if (nonceReplay) throw new PackageValidationError("Edit request nonce was already used", "replayed_edit_request");
      const record = { ...structuredClone(request), requestId, nonce, appId, savedAt: new Date().toISOString() };
      store.put(record);
      await transactionDone(tx);
      return record;
    } finally {
      db.close();
    }
  }

  async getEditRequest(requestId) {
    const id = String(requestId || "");
    if (!id) return null;
    const db = await openContentDb();
    try {
      const tx = db.transaction("editRequests", "readonly");
      const result = await requestAsPromise(tx.objectStore("editRequests").get(id));
      await transactionDone(tx);
      return result || null;
    } finally {
      db.close();
    }
  }

  async listEditRequests(appId) {
    appId = validateAppId(appId);
    const db = await openContentDb();
    try {
      const tx = db.transaction("editRequests", "readonly");
      const result = await requestAsPromise(tx.objectStore("editRequests").index("byApp").getAll(appId));
      await transactionDone(tx);
      return result.sort((a, b) => String(b.savedAt).localeCompare(String(a.savedAt)));
    } finally {
      db.close();
    }
  }

  async usedRequestNonces() {
    const db = await openContentDb();
    try {
      const tx = db.transaction("editRequests", "readonly");
      const records = await requestAsPromise(tx.objectStore("editRequests").getAll());
      await transactionDone(tx);
      return new Set(records.map((record) => record.nonce).filter(Boolean));
    } finally {
      db.close();
    }
  }
}

function validateUserKey(value) {
  const key = String(value || "").trim();
  if (!USER_KEY_PATTERN.test(key)) {
    throw new PackageValidationError("User-data key is invalid", "invalid_userdata_key");
  }
  return key;
}

function validateUserValue(value) {
  let json;
  try {
    json = JSON.stringify(value);
  } catch {
    throw new PackageValidationError("User-data value must be JSON serializable", "invalid_userdata_value");
  }
  if (json === undefined) {
    throw new PackageValidationError("User-data value must be JSON serializable", "invalid_userdata_value");
  }
  if (ENCODER.encode(json).byteLength > MAX_USER_VALUE_BYTES) {
    throw new PackageValidationError("User-data value is too large", "userdata_too_large");
  }
  return structuredClone(value);
}

function openUserDb(appId, projectId, namespace) {
  const request = idbApi().open(userDataDatabaseName(appId, projectId, namespace), 1);
  request.addEventListener("upgradeneeded", () => {
    const db = request.result;
    if (!db.objectStoreNames.contains("values")) db.createObjectStore("values", { keyPath: "key" });
  });
  return requestAsPromise(request);
}

export class AppUserDataStore {
  constructor(appId, projectId, namespace) {
    this.appId = validateStableId(appId, "User-data app id");
    this.projectId = validateStableId(projectId, "User-data project id");
    this.namespace = validateStableId(namespace, "User-data namespace");
    this.databaseName = userDataDatabaseName(this.appId, this.projectId, this.namespace);
  }

  async get(key) {
    key = validateUserKey(key);
    const db = await openUserDb(this.appId, this.projectId, this.namespace);
    try {
      const tx = db.transaction("values", "readonly");
      const record = await requestAsPromise(tx.objectStore("values").get(key));
      await transactionDone(tx);
      return record ? structuredClone(record.value) : null;
    } finally {
      db.close();
    }
  }

  async set(key, value) {
    key = validateUserKey(key);
    value = validateUserValue(value);
    const db = await openUserDb(this.appId, this.projectId, this.namespace);
    try {
      const tx = db.transaction("values", "readwrite");
      tx.objectStore("values").put({ key, value, updatedAt: new Date().toISOString() });
      await transactionDone(tx);
      return value;
    } finally {
      db.close();
    }
  }

  async remove(key) {
    key = validateUserKey(key);
    const db = await openUserDb(this.appId, this.projectId, this.namespace);
    try {
      const tx = db.transaction("values", "readwrite");
      tx.objectStore("values").delete(key);
      await transactionDone(tx);
    } finally {
      db.close();
    }
  }

  async list() {
    const db = await openUserDb(this.appId, this.projectId, this.namespace);
    try {
      const tx = db.transaction("values", "readonly");
      const records = await requestAsPromise(tx.objectStore("values").getAll());
      await transactionDone(tx);
      return records.map((record) => ({ key: record.key, value: structuredClone(record.value) }));
    } finally {
      db.close();
    }
  }
}

export const storageInternals = Object.freeze({
  contentDatabaseName: CONTENT_DB,
  contentDatabaseVersion: CONTENT_DB_VERSION,
  userDataDatabaseName,
});

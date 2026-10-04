import { randomBytes } from "node:crypto";
import {
  chmod,
  mkdir,
  open,
  readFile,
  rename,
  stat,
  unlink,
} from "node:fs/promises";
import { dirname, isAbsolute } from "node:path";

const STORE_KIND = "iris.mobile-shell.desktop-receipts";
const STORE_VERSION = 1;
const STORE_KEYS = ["deliveries", "kind", "requests", "version"];
const REQUEST_KEYS = ["acceptedAt", "appId", "baseRevisionId", "nonce", "projectId", "requestId"];
const DELIVERY_KEYS = [
  "appId",
  "baseRevisionId",
  "deliveryNonce",
  "envelopeId",
  "issuedAt",
  "projectId",
  "revisionId",
];

function exactKeys(value, keys) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

function canonicalIso(value) {
  if (typeof value !== "string") return false;
  const parsed = new Date(value);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString() === value;
}

function emptyStore() {
  return {
    kind: STORE_KIND,
    version: STORE_VERSION,
    requests: [],
    deliveries: [],
  };
}

function validateStore(value) {
  if (!exactKeys(value, STORE_KEYS)) throw new Error("receipt store has an invalid top-level shape");
  if (value.kind !== STORE_KIND || value.version !== STORE_VERSION) {
    throw new Error("receipt store version is unsupported");
  }
  if (!Array.isArray(value.requests) || !Array.isArray(value.deliveries)) {
    throw new Error("receipt store arrays are invalid");
  }

  const requestNonces = new Set();
  for (const row of value.requests) {
    if (!exactKeys(row, REQUEST_KEYS)) throw new Error("receipt store request row is invalid");
    if (
      !row.requestId || !row.nonce || !row.appId || !row.projectId || !canonicalIso(row.acceptedAt)
      || (row.baseRevisionId !== null && typeof row.baseRevisionId !== "string")
    ) {
      throw new Error("receipt store request row contains invalid values");
    }
    if (requestNonces.has(row.nonce)) throw new Error("receipt store contains a duplicate request nonce");
    requestNonces.add(row.nonce);
  }

  const deliveryNonces = new Set();
  for (const row of value.deliveries) {
    if (!exactKeys(row, DELIVERY_KEYS)) throw new Error("receipt store delivery row is invalid");
    if (
      !row.deliveryNonce || !row.envelopeId || !row.appId || !row.projectId || !row.revisionId
      || !canonicalIso(row.issuedAt)
      || (row.baseRevisionId !== null && typeof row.baseRevisionId !== "string")
    ) {
      throw new Error("receipt store delivery row contains invalid values");
    }
    if (deliveryNonces.has(row.deliveryNonce)) throw new Error("receipt store contains a duplicate delivery nonce");
    deliveryNonces.add(row.deliveryNonce);
  }
  return value;
}

async function pathExists(path) {
  try {
    await stat(path);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

export class ReceiptReplayError extends Error {
  constructor(message, code) {
    super(message);
    this.name = "ReceiptReplayError";
    this.code = code;
  }
}

export class DurableReceiptStore {
  constructor(filePath) {
    if (typeof filePath !== "string" || !isAbsolute(filePath)) {
      throw new TypeError("receipt store path must be an absolute caller-selected path");
    }
    this.filePath = filePath;
    this.lockPath = `${filePath}.lock`;
  }

  async read() {
    try {
      const text = await readFile(this.filePath, "utf8");
      return validateStore(JSON.parse(text));
    } catch (error) {
      if (error?.code === "ENOENT") return emptyStore();
      if (error instanceof SyntaxError) throw new Error("receipt store is not valid JSON");
      throw error;
    }
  }

  async hasAcceptedRequest(request) {
    const store = await this.read();
    return store.requests.some((row) => (
      row.requestId === request.requestId
      && row.nonce === request.nonce
      && row.appId === request.appId
      && row.projectId === request.projectId
      && row.baseRevisionId === request.baseRevisionId
    ));
  }

  async hasRequestNonce(nonce) {
    const store = await this.read();
    return store.requests.some((row) => row.nonce === nonce);
  }

  async hasDeliveryNonce(nonce) {
    const store = await this.read();
    return store.deliveries.some((row) => row.deliveryNonce === nonce);
  }

  async usedDeliveryNonces() {
    const store = await this.read();
    return new Set(store.deliveries.map((row) => row.deliveryNonce));
  }

  async claimRequest(request, acceptedAt = new Date().toISOString()) {
    return this.#mutate((store) => {
      if (store.requests.some((row) => row.nonce === request.nonce)) {
        throw new ReceiptReplayError("edit request nonce was already accepted", "replayed_request");
      }
      store.requests.push({
        requestId: request.requestId,
        nonce: request.nonce,
        appId: request.appId,
        projectId: request.projectId,
        baseRevisionId: request.baseRevisionId,
        acceptedAt,
      });
      return store.requests.at(-1);
    });
  }

  async claimDelivery(envelope) {
    return this.#mutate((store) => {
      if (store.deliveries.some((row) => row.deliveryNonce === envelope.deliveryNonce)) {
        throw new ReceiptReplayError("delivery nonce was already issued", "replayed_delivery");
      }
      store.deliveries.push({
        envelopeId: envelope.envelopeId,
        deliveryNonce: envelope.deliveryNonce,
        appId: envelope.appId,
        projectId: envelope.projectId,
        baseRevisionId: envelope.baseRevisionId,
        revisionId: envelope.revisionId,
        issuedAt: envelope.issuedAt,
      });
      return store.deliveries.at(-1);
    });
  }

  async #mutate(mutator) {
    await mkdir(dirname(this.filePath), { recursive: true, mode: 0o700 });
    let lockHandle;
    try {
      lockHandle = await open(this.lockPath, "wx", 0o600);
    } catch (error) {
      if (error?.code === "EEXIST") throw new Error("receipt store is busy");
      throw error;
    }

    try {
      const store = await this.read();
      const result = mutator(store);
      validateStore(store);
      await this.#writeAtomically(store);
      return result;
    } finally {
      await lockHandle?.close().catch(() => {});
      await unlink(this.lockPath).catch((error) => {
        if (error?.code !== "ENOENT") throw error;
      });
    }
  }

  async #writeAtomically(store) {
    const tempPath = `${this.filePath}.tmp-${process.pid}-${randomBytes(6).toString("hex")}`;
    let handle;
    try {
      handle = await open(tempPath, "wx", 0o600);
      await handle.writeFile(`${JSON.stringify(store, null, 2)}\n`, "utf8");
      await handle.sync();
      await handle.close();
      handle = undefined;
      await rename(tempPath, this.filePath);
      await chmod(this.filePath, 0o600);
      if (await pathExists(dirname(this.filePath))) {
        const directory = await open(dirname(this.filePath), "r");
        try {
          await directory.sync();
        } finally {
          await directory.close();
        }
      }
    } finally {
      await handle?.close().catch(() => {});
      await unlink(tempPath).catch((error) => {
        if (error?.code !== "ENOENT") throw error;
      });
    }
  }
}


(function installIrisPackagedAPI(global) {
  "use strict";

  const API_VERSION = 1;
  const LIMITS = Object.freeze({
    maxActiveRequests: 4,
    maxRetainedRequests: 64,
    maxOperations: 32,
    maxRequestIdLength: 128,
    maxOperationCodeLength: 64,
    maxInputBytes: 16 * 1024,
    maxOutputBytes: 32 * 1024,
    maxSchemaDepth: 8,
    maxObjectProperties: 32,
    maxArrayItems: 64,
    maxStringLength: 4096,
    defaultDeadlineMs: 15000,
    maxDeadlineMs: 30000,
  });
  const REQUEST_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
  const OPERATION_CODE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
  const CONTEXT_ID = /^[a-z0-9][a-z0-9._-]{0,127}$/;
  const REVISION_ID = /^rev-sha256:[0-9a-f]{64}$/;
  const ALLOWED_REQUEST_KEYS = new Set(["requestId", "operationCode", "input", "deadlineMs"]);
  const encoder = new TextEncoder();

  class IrisPackagedAPIError extends Error {
    constructor(code, message) {
      super(message);
      this.name = "IrisPackagedAPIError";
      Object.defineProperty(this, "code", { value: code, enumerable: true });
    }
  }

  function fail(code, message) {
    throw new IrisPackagedAPIError(code, message);
  }

  function typedError(error, code, message) {
    return error instanceof IrisPackagedAPIError
      ? error
      : new IrisPackagedAPIError(code, message);
  }

  function isPlainObject(value) {
    if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
    const prototype = Object.getPrototypeOf(value);
    return prototype === null || prototype === Object.prototype;
  }

  function exactKeys(value, allowed, code, label) {
    if (!isPlainObject(value)) fail(code, `${label} must be an object`);
    for (const key of Object.keys(value)) {
      if (!allowed.has(key)) fail(code, `${label} contains unsupported field ${key}`);
    }
  }

  function canonicalJSONString(value) {
    if (value === null || typeof value !== "object") return JSON.stringify(value);
    if (Array.isArray(value)) return `[${value.map(canonicalJSONString).join(",")}]`;
    const keys = Object.keys(value).sort();
    return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJSONString(value[key])}`).join(",")}}`;
  }

  function utf8Length(value) {
    return encoder.encode(value).byteLength;
  }

  function cloneJSON(value, byteLimit, code, label) {
    let canonical;
    try {
      canonical = canonicalJSONString(value);
    } catch (_) {
      fail(code, `${label} is not canonical JSON data`);
    }
    if (typeof canonical !== "string") fail(code, `${label} is not JSON data`);
    if (utf8Length(canonical) > byteLimit) fail(code, `${label} exceeds byte limit`);
    try {
      return { value: JSON.parse(canonical), canonical };
    } catch (_) {
      fail(code, `${label} is not JSON data`);
    }
  }

  function deepFreeze(value) {
    if (value && typeof value === "object" && !Object.isFrozen(value)) {
      Object.freeze(value);
      for (const key of Object.keys(value)) deepFreeze(value[key]);
    }
    return value;
  }

  function validateSchema(schema, depth = 0) {
    if (depth > LIMITS.maxSchemaDepth) fail("invalid_configuration", "operation schema is too deep");
    if (!isPlainObject(schema) || typeof schema.type !== "string") {
      fail("invalid_configuration", "operation schema must declare a type");
    }
    switch (schema.type) {
      case "string": {
        exactKeys(schema, new Set(["type", "minLength", "maxLength"]), "invalid_configuration", "string schema");
        if (!Number.isSafeInteger(schema.maxLength) || schema.maxLength < 0 || schema.maxLength > LIMITS.maxStringLength) {
          fail("invalid_configuration", "string schema requires a bounded maxLength");
        }
        const minimum = schema.minLength === undefined ? 0 : schema.minLength;
        if (!Number.isSafeInteger(minimum) || minimum < 0 || minimum > schema.maxLength) {
          fail("invalid_configuration", "string schema minLength is invalid");
        }
        break;
      }
      case "integer":
      case "number": {
        exactKeys(schema, new Set(["type", "minimum", "maximum"]), "invalid_configuration", "number schema");
        if (!Number.isFinite(schema.minimum) || !Number.isFinite(schema.maximum) || schema.minimum > schema.maximum) {
          fail("invalid_configuration", "number schema requires finite minimum and maximum");
        }
        break;
      }
      case "boolean":
      case "null":
        exactKeys(schema, new Set(["type"]), "invalid_configuration", `${schema.type} schema`);
        break;
      case "array": {
        exactKeys(schema, new Set(["type", "items", "maxItems"]), "invalid_configuration", "array schema");
        if (!Number.isSafeInteger(schema.maxItems) || schema.maxItems < 0 || schema.maxItems > LIMITS.maxArrayItems) {
          fail("invalid_configuration", "array schema requires a bounded maxItems");
        }
        validateSchema(schema.items, depth + 1);
        break;
      }
      case "object": {
        exactKeys(
          schema,
          new Set(["type", "properties", "required", "additionalProperties"]),
          "invalid_configuration",
          "object schema"
        );
        if (!isPlainObject(schema.properties)) fail("invalid_configuration", "object schema properties are required");
        const keys = Object.keys(schema.properties);
        if (keys.length > LIMITS.maxObjectProperties) fail("invalid_configuration", "object schema has too many properties");
        if (schema.additionalProperties !== false) fail("invalid_configuration", "object schema must reject additional properties");
        if (!Array.isArray(schema.required)) fail("invalid_configuration", "object schema required must be an array");
        const required = new Set();
        for (const key of schema.required) {
          if (typeof key !== "string" || !Object.prototype.hasOwnProperty.call(schema.properties, key) || required.has(key)) {
            fail("invalid_configuration", "object schema required keys are invalid");
          }
          required.add(key);
        }
        for (const key of keys) validateSchema(schema.properties[key], depth + 1);
        break;
      }
      default:
        fail("invalid_configuration", `unsupported schema type ${schema.type}`);
    }
    return schema;
  }

  function validateValue(value, schema, code, path = "$") {
    switch (schema.type) {
      case "string": {
        if (typeof value !== "string" || value.length < (schema.minLength ?? 0) || value.length > schema.maxLength) {
          fail(code, `${path} must be a bounded string`);
        }
        return;
      }
      case "integer":
        if (!Number.isSafeInteger(value) || value < schema.minimum || value > schema.maximum) {
          fail(code, `${path} must be a bounded integer`);
        }
        return;
      case "number":
        if (typeof value !== "number" || !Number.isFinite(value) || value < schema.minimum || value > schema.maximum) {
          fail(code, `${path} must be a bounded number`);
        }
        return;
      case "boolean":
        if (typeof value !== "boolean") fail(code, `${path} must be a boolean`);
        return;
      case "null":
        if (value !== null) fail(code, `${path} must be null`);
        return;
      case "array":
        if (!Array.isArray(value) || value.length > schema.maxItems) fail(code, `${path} must be a bounded array`);
        value.forEach((item, index) => validateValue(item, schema.items, code, `${path}[${index}]`));
        return;
      case "object": {
        if (!isPlainObject(value)) fail(code, `${path} must be an object`);
        const keys = Object.keys(value);
        if (keys.length > LIMITS.maxObjectProperties) fail(code, `${path} has too many properties`);
        for (const key of keys) {
          if (!Object.prototype.hasOwnProperty.call(schema.properties, key)) {
            fail(code, `${path}.${key} is not allowed`);
          }
        }
        for (const key of schema.required) {
          if (!Object.prototype.hasOwnProperty.call(value, key)) fail(code, `${path}.${key} is required`);
        }
        for (const key of keys) validateValue(value[key], schema.properties[key], code, `${path}.${key}`);
        return;
      }
      default:
        fail(code, `${path} uses an unsupported schema`);
    }
  }

  function validateContext(raw) {
    if (!isPlainObject(raw)) return null;
    const allowed = new Set(["appId", "projectId", "revisionId"]);
    try {
      exactKeys(raw, allowed, "invalid_configuration", "context");
      if (!CONTEXT_ID.test(raw.appId ?? "") || !CONTEXT_ID.test(raw.projectId ?? "") || !REVISION_ID.test(raw.revisionId ?? "")) {
        return null;
      }
      return deepFreeze({ appId: raw.appId, projectId: raw.projectId, revisionId: raw.revisionId });
    } catch (_) {
      return null;
    }
  }

  function validateOperations(raw) {
    if (!isPlainObject(raw)) return null;
    const codes = Object.keys(raw);
    if (codes.length < 1 || codes.length > LIMITS.maxOperations) return null;
    const result = new Map();
    try {
      for (const code of codes) {
        if (!OPERATION_CODE.test(code)) fail("invalid_configuration", "operation code is invalid");
        const descriptor = raw[code];
        exactKeys(descriptor, new Set(["input", "output"]), "invalid_configuration", `operation ${code}`);
        result.set(code, {
          input: validateSchema(descriptor.input),
          output: validateSchema(descriptor.output),
        });
      }
    } catch (_) {
      return null;
    }
    return result;
  }

  const bootstrap = isPlainObject(global.__IRIS_PACKAGED_API_BOOTSTRAP__)
    ? global.__IRIS_PACKAGED_API_BOOTSTRAP__
    : Object.create(null);
  try {
    delete global.__IRIS_PACKAGED_API_BOOTSTRAP__;
  } catch (_) {
    global.__IRIS_PACKAGED_API_BOOTSTRAP__ = undefined;
  }

  const context = validateContext(bootstrap.context);
  const operations = validateOperations(bootstrap.operations);
  const adapter = typeof bootstrap.adapter === "function" ? bootstrap.adapter : null;
  const configured = context !== null && operations !== null && adapter !== null;
  const requests = new Map();
  let activeRequests = 0;
  let closed = false;

  function errorPromise(code, message) {
    return Promise.reject(new IrisPackagedAPIError(code, message));
  }

  function status() {
    return deepFreeze({
      version: API_VERSION,
      status: closed ? "closed" : (configured ? "ready" : "not_configured"),
      context,
      activeRequests,
      retainedRequests: requests.size - activeRequests,
      limits: LIMITS,
      operations: configured ? Object.freeze(Array.from(operations.keys()).sort()) : Object.freeze([]),
    });
  }

  function settle(entry, kind, value) {
    if (entry.state !== "active") return false;
    entry.state = kind;
    activeRequests -= 1;
    if (entry.timer !== null) clearTimeout(entry.timer);
    entry.timer = null;
    entry.controller = null;
    const resolve = entry.resolve;
    const reject = entry.reject;
    entry.resolve = null;
    entry.reject = null;
    if (kind === "resolved") resolve(value);
    else reject(value);
    return true;
  }

  function perform(rawRequest) {
    let request;
    try {
      exactKeys(rawRequest, ALLOWED_REQUEST_KEYS, "invalid_request", "request");
      if (!REQUEST_ID.test(rawRequest.requestId ?? "")) fail("invalid_request", "requestId is invalid");
      if (!OPERATION_CODE.test(rawRequest.operationCode ?? "")) fail("invalid_request", "operationCode is invalid");
      if (!Object.prototype.hasOwnProperty.call(rawRequest, "input")) fail("invalid_request", "input is required");
      const deadlineMs = rawRequest.deadlineMs === undefined ? LIMITS.defaultDeadlineMs : rawRequest.deadlineMs;
      if (!Number.isSafeInteger(deadlineMs) || deadlineMs < 1 || deadlineMs > LIMITS.maxDeadlineMs) {
        fail("invalid_request", "deadlineMs is invalid");
      }
      request = { requestId: rawRequest.requestId, operationCode: rawRequest.operationCode, input: rawRequest.input, deadlineMs };
    } catch (error) {
      return Promise.reject(typedError(error, "invalid_request", "request validation failed"));
    }

    if (closed) return errorPromise("closed", "packaged API session is closed");
    if (!configured) return errorPromise("not_configured", "no packaged API adapter is configured");

    const descriptor = operations.get(request.operationCode);
    if (!descriptor) return errorPromise("operation_not_registered", "operation is not registered");

    let clonedInput;
    let fingerprint;
    try {
      validateValue(request.input, descriptor.input, "invalid_input");
      const cloned = cloneJSON(request.input, LIMITS.maxInputBytes, "invalid_input", "input");
      clonedInput = deepFreeze(cloned.value);
      fingerprint = `${request.operationCode}\n${request.deadlineMs}\n${cloned.canonical}`;
    } catch (error) {
      return Promise.reject(typedError(error, "invalid_input", "input validation failed"));
    }

    const existing = requests.get(request.requestId);
    if (existing) {
      if (existing.fingerprint !== fingerprint) {
        return errorPromise("conflicting_request_id", "requestId was already used for different request content");
      }
      return existing.promise;
    }
    if (requests.size >= LIMITS.maxRetainedRequests) {
      return errorPromise("retained_request_limit", "packaged API session retained-request limit reached");
    }
    if (activeRequests >= LIMITS.maxActiveRequests) {
      return errorPromise("active_request_limit", "packaged API active-request limit reached");
    }

    let resolvePromise;
    let rejectPromise;
    const promise = new Promise((resolve, reject) => {
      resolvePromise = resolve;
      rejectPromise = reject;
    });
    const controller = new AbortController();
    const entry = {
      fingerprint,
      promise,
      state: "active",
      resolve: resolvePromise,
      reject: rejectPromise,
      controller,
      timer: null,
    };
    requests.set(request.requestId, entry);
    activeRequests += 1;

    entry.timer = setTimeout(() => {
      if (entry.state !== "active") return;
      controller.abort("deadline");
      settle(entry, "rejected", new IrisPackagedAPIError("deadline_exceeded", "packaged API request deadline exceeded"));
    }, request.deadlineMs);

    const adapterRequest = Object.freeze({
      requestId: request.requestId,
      operationCode: request.operationCode,
      input: clonedInput,
      context,
      deadlineMs: request.deadlineMs,
      signal: controller.signal,
    });

    Promise.resolve()
      .then(() => {
        if (entry.state !== "active") return undefined;
        return adapter(adapterRequest);
      })
      .then((rawOutput) => {
        if (entry.state !== "active") return;
        try {
          validateValue(rawOutput, descriptor.output, "invalid_output");
          const cloned = cloneJSON(rawOutput, LIMITS.maxOutputBytes, "invalid_output", "output");
          settle(entry, "resolved", deepFreeze(cloned.value));
        } catch (error) {
          settle(entry, "rejected", typedError(error, "invalid_output", "output validation failed"));
        }
      }, () => {
        if (entry.state !== "active") return;
        settle(entry, "rejected", new IrisPackagedAPIError("adapter_failed", "packaged API adapter failed"));
      });

    return promise;
  }

  function cancel(requestId) {
    if (!REQUEST_ID.test(requestId ?? "")) fail("invalid_request", "requestId is invalid");
    const entry = requests.get(requestId);
    if (!entry || entry.state !== "active") return false;
    entry.controller.abort("cancelled");
    settle(entry, "rejected", new IrisPackagedAPIError("cancelled", "packaged API request was cancelled"));
    return true;
  }

  function close() {
    if (closed) return false;
    closed = true;
    for (const entry of requests.values()) {
      if (entry.state !== "active") continue;
      entry.controller.abort("closed");
      settle(entry, "rejected", new IrisPackagedAPIError("closed", "packaged API session closed"));
    }
    return true;
  }

  const api = Object.freeze({
    version: API_VERSION,
    context,
    limits: LIMITS,
    status,
    perform,
    cancel,
    close,
  });
  const root = Object.freeze({ v1: api });
  Object.defineProperty(global, "IrisPackagedAPI", {
    value: root,
    enumerable: true,
    writable: false,
    configurable: false,
  });
  const closeOnPageHide = () => { close(); };
  global.addEventListener?.("pagehide", closeOnPageHide, { once: true });
})(globalThis);

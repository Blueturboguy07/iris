import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const sdkURL = new URL("../../Sources/IrisMobileShellHost/Resources/iris-packaged-api.js", import.meta.url);
const sdkSource = await readFile(sdkURL, "utf8");
const offlineAdapterURL = new URL(
  "../../Sources/IrisMobileShellHost/Resources/Adapters/iris-packaged-api-offline-example.js",
  import.meta.url
);
const offlineAdapterSource = await readFile(offlineAdapterURL, "utf8");

const contextJSON = JSON.stringify({
  appId: "publik.test-app",
  projectId: "publik.test-project",
  revisionId: `rev-sha256:${"a".repeat(64)}`,
});

function bootstrapSource({ operations = "null", adapter = "null", extra = "" } = {}) {
  return `
    globalThis.__IRIS_PACKAGED_API_BOOTSTRAP__ = {
      context: ${contextJSON},
      operations: ${operations},
      adapter: ${adapter}
    };
    ${extra}
  `;
}

function session(source = `globalThis.__IRIS_PACKAGED_API_BOOTSTRAP__ = { context: ${contextJSON} };`) {
  const sandbox = {
    AbortController,
    AbortSignal,
    TextEncoder,
    setTimeout,
    clearTimeout,
  };
  const context = vm.createContext(sandbox);
  vm.runInContext(`${source}\n${sdkSource}`, context, { filename: "iris-packaged-api.js" });
  const perform = (request) => vm.runInContext(
    `globalThis.IrisPackagedAPI.v1.perform(${JSON.stringify(request)})`,
    context
  );
  return { context, api: context.IrisPackagedAPI.v1, perform };
}

async function rejectionCode(promise) {
  try {
    await promise;
    assert.fail("expected promise rejection");
  } catch (error) {
    return error.code;
  }
}

async function rejectionError(promise) {
  try {
    await promise;
    assert.fail("expected promise rejection");
  } catch (error) {
    return error;
  }
}

const echoOperations = `({
  "echo.text": {
    input: {
      type: "object",
      properties: { text: { type: "string", minLength: 1, maxLength: 32 } },
      required: ["text"],
      additionalProperties: false
    },
    output: {
      type: "object",
      properties: { text: { type: "string", minLength: 1, maxLength: 96 } },
      required: ["text"],
      additionalProperties: false
    }
  }
})`;

test("default client is frozen, context-only, and not configured", async () => {
  const { context, api, perform } = session();
  const status = await api.status();

  assert.equal(api.version, 1);
  assert.equal(status.status, "not_configured");
  assert.deepEqual(JSON.parse(JSON.stringify(status.context)), JSON.parse(contextJSON));
  assert.deepEqual(Array.from(status.operations), []);
  assert.equal(Object.isFrozen(api), true);
  assert.equal(Object.isFrozen(status.context), true);
  assert.equal(api.configure, undefined);
  assert.equal(api.register, undefined);
  assert.equal(context.__IRIS_PACKAGED_API_BOOTSTRAP__, undefined);
  assert.equal(
    await rejectionCode(perform({ requestId: "req-1", operationCode: "echo.text", input: { text: "hi" } })),
    "not_configured"
  );
});

test("registered operation receives only frozen typed input and verified launch context", async () => {
  const { context, api, perform } = session(bootstrapSource({
    operations: echoOperations,
    adapter: `async (request) => {
      globalThis.__observed = {
        requestId: request.requestId,
        operationCode: request.operationCode,
        context: request.context,
        frozenInput: Object.isFrozen(request.input),
        frozenContext: Object.isFrozen(request.context),
        hasSignal: request.signal instanceof AbortSignal,
        deadlineMs: request.deadlineMs
      };
      return { text: request.context.appId + ":" + request.input.text };
    }`,
  }));

  const status = await api.status();
  assert.equal(status.status, "ready");
  assert.deepEqual(Array.from(status.operations), ["echo.text"]);
  const output = await perform({
    requestId: "req-typed-1",
    operationCode: "echo.text",
    input: { text: "hello" },
    deadlineMs: 1000,
  });
  assert.deepEqual(JSON.parse(JSON.stringify(output)), { text: "publik.test-app:hello" });
  assert.equal(Object.isFrozen(output), true);
  assert.equal(context.__observed.requestId, "req-typed-1");
  assert.equal(context.__observed.operationCode, "echo.text");
  assert.equal(context.__observed.frozenInput, true);
  assert.equal(context.__observed.frozenContext, true);
  assert.equal(context.__observed.hasSignal, true);
  assert.equal(context.__observed.deadlineMs, 1000);
  assert.deepEqual(JSON.parse(JSON.stringify(context.__observed.context)), JSON.parse(contextJSON));
});

test("request, operation, input, output and configuration validation fail closed", async () => {
  const configuredSession = session(bootstrapSource({
    operations: echoOperations,
    adapter: `async (request) => request.operationCode === "echo.text" ? { text: request.input.text } : { text: "x" }`,
  }));
  const configured = configuredSession.api;
  const configuredPerform = configuredSession.perform;

  assert.equal(
    await rejectionCode(configuredPerform({ requestId: "req-extra", operationCode: "echo.text", input: { text: "x" }, url: "https://example.invalid" })),
    "invalid_request"
  );
  assert.equal(
    await rejectionCode(configuredPerform({ requestId: "req-extra-input", operationCode: "echo.text", input: { text: "x", other: true } })),
    "invalid_input"
  );
  assert.equal(
    await rejectionCode(configuredPerform({ requestId: "req-long", operationCode: "echo.text", input: { text: "x".repeat(33) } })),
    "invalid_input"
  );
  assert.equal(
    await rejectionCode(configuredPerform({ requestId: "req-op", operationCode: "unknown.op", input: {} })),
    "operation_not_registered"
  );
  assert.equal(
    await rejectionCode(configuredPerform({ requestId: "req-deadline", operationCode: "echo.text", input: { text: "x" }, deadlineMs: 30001 })),
    "invalid_request"
  );

  const badOutputSession = session(bootstrapSource({
    operations: echoOperations,
    adapter: `async () => ({ wrong: true })`,
  }));
  assert.equal(
    await rejectionCode(badOutputSession.perform({ requestId: "req-output", operationCode: "echo.text", input: { text: "x" } })),
    "invalid_output"
  );

  const invalidSchemaSession = session(bootstrapSource({
    operations: `({ "bad.op": { input: { type: "string" }, output: { type: "boolean" } } })`,
    adapter: `async () => true`,
  }));
  const invalidSchema = invalidSchemaSession.api;
  assert.equal((await invalidSchema.status()).status, "not_configured");
  assert.equal(
    await rejectionCode(invalidSchemaSession.perform({ requestId: "req-invalid-config", operationCode: "bad.op", input: "x" })),
    "not_configured"
  );
});

test("same request id is idempotent and conflicting content is rejected", async () => {
  const { context, api, perform } = session(bootstrapSource({
    operations: echoOperations,
    adapter: `async (request) => {
      globalThis.__calls = (globalThis.__calls || 0) + 1;
      return { text: request.input.text };
    }`,
  }));

  const request = { requestId: "req-idempotent", operationCode: "echo.text", input: { text: "same" }, deadlineMs: 1000 };
  const first = perform(request);
  const duplicate = perform({ requestId: "req-idempotent", operationCode: "echo.text", input: { text: "same" }, deadlineMs: 1000 });
  assert.strictEqual(first, duplicate);
  assert.deepEqual(JSON.parse(JSON.stringify(await first)), { text: "same" });
  assert.equal(context.__calls, 1);
  assert.strictEqual(perform(request), first);
  assert.equal(
    await rejectionCode(perform({ requestId: "req-idempotent", operationCode: "echo.text", input: { text: "different" }, deadlineMs: 1000 })),
    "conflicting_request_id"
  );
});

test("active requests are bounded and cancellation aborts then suppresses late completion", async () => {
  const { context, api, perform } = session(bootstrapSource({
    operations: echoOperations,
    adapter: `(request) => new Promise((resolve) => {
      globalThis.__pending = globalThis.__pending || {};
      globalThis.__pending[request.requestId] = { resolve, signal: request.signal };
    })`,
  }));

  const pending = [];
  for (let index = 0; index < 4; index += 1) {
    const promise = perform({ requestId: `active-${index}`, operationCode: "echo.text", input: { text: `v${index}` }, deadlineMs: 5000 });
    promise.catch(() => {});
    pending.push(promise);
  }
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal((await api.status()).activeRequests, 4);
  assert.equal(
    await rejectionCode(perform({ requestId: "active-4", operationCode: "echo.text", input: { text: "overflow" }, deadlineMs: 5000 })),
    "active_request_limit"
  );

  assert.equal(api.cancel("active-0"), true);
  assert.equal(context.__pending["active-0"].signal.aborted, true);
  assert.equal(await rejectionCode(pending[0]), "cancelled");
  context.__pending["active-0"].resolve({ text: "late-success" });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal((await api.status()).activeRequests, 3);
  assert.equal((await api.status()).retainedRequests, 1);

  const replacement = perform({ requestId: "replacement", operationCode: "echo.text", input: { text: "replacement" }, deadlineMs: 5000 });
  await new Promise((resolve) => setTimeout(resolve, 0));
  vm.runInContext(`globalThis.__pending.replacement.resolve({ text: "replacement" })`, context);
  assert.deepEqual(JSON.parse(JSON.stringify(await replacement)), { text: "replacement" });

  for (let index = 1; index < 4; index += 1) {
    api.cancel(`active-${index}`);
    assert.equal(await rejectionCode(pending[index]), "cancelled");
  }
});

test("deadline rejects once and a late adapter completion cannot revive the request", async () => {
  const { context, api, perform } = session(bootstrapSource({
    operations: echoOperations,
    adapter: `(request) => new Promise((resolve) => {
      globalThis.__deadlineResolve = resolve;
      globalThis.__deadlineSignal = request.signal;
    })`,
  }));

  const promise = perform({ requestId: "deadline-1", operationCode: "echo.text", input: { text: "wait" }, deadlineMs: 10 });
  assert.equal(await rejectionCode(promise), "deadline_exceeded");
  assert.equal(context.__deadlineSignal.aborted, true);
  context.__deadlineResolve({ text: "too-late" });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal((await api.status()).activeRequests, 0);
  assert.equal((await api.status()).retainedRequests, 1);
  assert.strictEqual(perform({ requestId: "deadline-1", operationCode: "echo.text", input: { text: "wait" }, deadlineMs: 10 }), promise);
  assert.equal(await rejectionCode(promise), "deadline_exceeded");
});

test("immediate cancel prevents adapter dispatch side effects", async () => {
  const { context, api, perform } = session(bootstrapSource({
    operations: echoOperations,
    adapter: `(request) => {
      globalThis.__immediateCancelDispatches = (globalThis.__immediateCancelDispatches || 0) + 1;
      return new Promise(() => {});
    }`,
  }));

  const promise = perform({
    requestId: "cancel-before-dispatch",
    operationCode: "echo.text",
    input: { text: "cancel" },
    deadlineMs: 5000,
  });
  assert.equal(api.cancel("cancel-before-dispatch"), true);
  assert.equal(await rejectionCode(promise), "cancelled");
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(context.__immediateCancelDispatches ?? 0, 0);
});

test("immediate close prevents adapter dispatch side effects", async () => {
  const { context, api, perform } = session(bootstrapSource({
    operations: echoOperations,
    adapter: `(request) => {
      globalThis.__immediateCloseDispatches = (globalThis.__immediateCloseDispatches || 0) + 1;
      return new Promise(() => {});
    }`,
  }));

  const promise = perform({
    requestId: "close-before-dispatch",
    operationCode: "echo.text",
    input: { text: "close" },
    deadlineMs: 5000,
  });
  assert.equal(api.close(), true);
  assert.equal(await rejectionCode(promise), "closed");
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(context.__immediateCloseDispatches ?? 0, 0);
});

test("input accessors are normalized to typed invalid_input errors", async () => {
  const { context } = session(bootstrapSource({
    operations: echoOperations,
    adapter: `async (request) => ({ text: request.input.text })`,
  }));
  const promise = vm.runInContext(`(() => {
    const input = {};
    Object.defineProperty(input, "text", {
      enumerable: true,
      get() { throw new Error("raw-input-secret"); }
    });
    return globalThis.IrisPackagedAPI.v1.perform({
      requestId: "getter-input",
      operationCode: "echo.text",
      input
    });
  })()`, context);
  const error = await rejectionError(promise);
  assert.equal(error.name, "IrisPackagedAPIError");
  assert.equal(error.code, "invalid_input");
  assert.doesNotMatch(error.message, /raw-input-secret/);
});

test("output accessors are normalized to typed invalid_output errors", async () => {
  const { perform } = session(bootstrapSource({
    operations: echoOperations,
    adapter: `async () => {
      const output = {};
      Object.defineProperty(output, "text", {
        enumerable: true,
        get() { throw new Error("raw-output-secret"); }
      });
      return output;
    }`,
  }));
  const error = await rejectionError(perform({
    requestId: "getter-output",
    operationCode: "echo.text",
    input: { text: "x" },
  }));
  assert.equal(error.name, "IrisPackagedAPIError");
  assert.equal(error.code, "invalid_output");
  assert.doesNotMatch(error.message, /raw-output-secret/);
});

test("session retention is bounded without losing same-id replay semantics", async () => {
  const { api, perform } = session(bootstrapSource({
    operations: echoOperations,
    adapter: `async (request) => ({ text: request.input.text })`,
  }));

  let first;
  for (let index = 0; index < api.limits.maxRetainedRequests; index += 1) {
    const promise = perform({ requestId: `retained-${index}`, operationCode: "echo.text", input: { text: `v${index}` } });
    if (index === 0) first = promise;
    await promise;
  }
  const status = await api.status();
  assert.equal(status.activeRequests, 0);
  assert.equal(status.retainedRequests, api.limits.maxRetainedRequests);
  assert.equal(
    await rejectionCode(perform({ requestId: "retained-overflow", operationCode: "echo.text", input: { text: "x" } })),
    "retained_request_limit"
  );
  assert.strictEqual(
    perform({ requestId: "retained-0", operationCode: "echo.text", input: { text: "v0" } }),
    first
  );
});

test("close aborts active work, rejects new work, and suppresses stale completions", async () => {
  const { context, api, perform } = session(bootstrapSource({
    operations: echoOperations,
    adapter: `(request) => new Promise((resolve) => {
      globalThis.__closePending = globalThis.__closePending || {};
      globalThis.__closePending[request.requestId] = { resolve, signal: request.signal };
    })`,
  }));

  const one = perform({ requestId: "close-1", operationCode: "echo.text", input: { text: "one" }, deadlineMs: 5000 });
  const two = perform({ requestId: "close-2", operationCode: "echo.text", input: { text: "two" }, deadlineMs: 5000 });
  one.catch(() => {});
  two.catch(() => {});
  await Promise.resolve();
  assert.equal(api.close(), true);
  assert.equal(api.close(), false);
  assert.equal(context.__closePending["close-1"].signal.aborted, true);
  assert.equal(context.__closePending["close-2"].signal.aborted, true);
  assert.equal(await rejectionCode(one), "closed");
  assert.equal(await rejectionCode(two), "closed");
  context.__closePending["close-1"].resolve({ text: "late" });
  context.__closePending["close-2"].resolve({ text: "late" });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal((await api.status()).status, "closed");
  assert.equal((await api.status()).activeRequests, 0);
  assert.equal(
    await rejectionCode(perform({ requestId: "close-new", operationCode: "echo.text", input: { text: "new" } })),
    "closed"
  );
});

test("canonical SDK contains no network, credential or native-message bridge surface", () => {
  assert.doesNotMatch(sdkSource, /\bfetch\s*\(/);
  assert.doesNotMatch(sdkSource, /\bWebSocket\b/);
  assert.doesNotMatch(sdkSource, /\bXMLHttpRequest\b/);
  assert.doesNotMatch(sdkSource, /messageHandlers|scriptMessage|WKScriptMessage/);
  assert.doesNotMatch(sdkSource, /api[_-]?key|bearer\s|authorization\s*:/i);
  assert.doesNotMatch(sdkSource, /https?:\/\//i);
});

test("bundled offline example configures only the typed echo operation and cannot replace verified context", async () => {
  const sandbox = { AbortController, AbortSignal, TextEncoder, setTimeout, clearTimeout };
  const context = vm.createContext(sandbox);
  vm.runInContext(`
    globalThis.__IRIS_PACKAGED_API_BOOTSTRAP__ = {};
    ${offlineAdapterSource}
    globalThis.__IRIS_PACKAGED_API_BOOTSTRAP__.context = {
      appId: "replacement",
      projectId: "replacement",
      revisionId: "rev-sha256:${"0".repeat(64)}"
    };
    Object.defineProperty(globalThis.__IRIS_PACKAGED_API_BOOTSTRAP__, "context", {
      value: Object.freeze(${contextJSON}),
      enumerable: true,
      writable: false,
      configurable: false
    });
    Object.freeze(globalThis.__IRIS_PACKAGED_API_BOOTSTRAP__);
    ${sdkSource}
  `, context, { filename: "iris-packaged-api-offline-example-composed.js" });

  const status = context.IrisPackagedAPI.v1.status();
  assert.equal(status.status, "ready");
  assert.deepEqual(Array.from(status.operations), ["offline.echo"]);
  assert.equal(context.__IRIS_PACKAGED_API_BOOTSTRAP__, undefined);
  assert.equal(Object.isFrozen(status.context), true);

  const output = await vm.runInContext(`globalThis.IrisPackagedAPI.v1.perform({
    requestId: "offline-example-1",
    operationCode: "offline.echo",
    input: { text: "local only" },
    deadlineMs: 1000
  })`, context);
  assert.deepEqual(JSON.parse(JSON.stringify(output)), {
    text: "local only",
    appId: "publik.test-app",
    projectId: "publik.test-project",
    revisionId: `rev-sha256:${"a".repeat(64)}`,
  });

  assert.doesNotMatch(offlineAdapterSource, /\bfetch\s*\(/);
  assert.doesNotMatch(offlineAdapterSource, /\bWebSocket\b|\bXMLHttpRequest\b/);
  assert.doesNotMatch(offlineAdapterSource, /messageHandlers|scriptMessage|WKScriptMessage/);
  assert.doesNotMatch(offlineAdapterSource, /https?:\/\//i);
});

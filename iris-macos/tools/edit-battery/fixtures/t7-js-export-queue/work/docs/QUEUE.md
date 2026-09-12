# Small export queue contract

Please add a small persistent queue behind the export status panel. A reader
can ask for an export, see it waiting, let the app process one export at a
time, cancel a waiting or running export, and retry an export that failed. If
the app stops while an export is running, the next queue instance must pick it
up. The worker is injected by the caller and must not know about storage or
the network.

## Boundaries and state

`ExportStore` takes an object with synchronous `getItem(key)` and
`setItem(key, value)` methods, plus an optional key. It stores JSON under the
default key `iris.export-queue.v1`. `load()` returns an empty version-1 state
when the key is absent or malformed. The state shape is:

```js
{ version: 1, nextId: 1, jobs: [] }
```

Each job has `id`, `payload`, `status`, `progress`, `attempts`, `result` and
`error`. Status is one of `queued`, `running`, `succeeded`, `failed` or
`cancelled`. A new job is assigned `export-1`, `export-2`, and so on from the
persisted `nextId`. Payloads and results are JSON-compatible values.

## Queue API

```js
const store = new ExportStore(storage);
const queue = new ExportQueue({ store, worker });
await queue.start();
const job = await queue.enqueue({ format: 'csv' });
await queue.cancel(job.id);       // queued or running
await queue.retry(job.id);        // failed only
await queue.shutdown();           // preserve a running job for restart
```

`worker(payload, { signal, report })` returns a promise for the export result.
`report(number)` persists a clamped 0..100 progress value for the running
job. The queue must invoke at most one worker at a time, in enqueue order. A
job becomes `running` and increments `attempts` before its worker is called.
It becomes `succeeded` with progress 100 and the returned `result` only after
the promise resolves. A thrown or rejected worker makes it `failed` with a
readable error string, while later queued jobs still run.

Cancelling a queued job marks it `cancelled` without invoking the worker.
Cancelling a running job marks it `cancelled`, aborts its signal, and ignores
any later worker resolution or rejection. Retrying a failed job clears its
old result and error, sets it to `queued`, and runs it again. Attempts count
worker starts, so a retry increases the count.

`start()` loads state before doing work. Any persisted `running` job is
recovered as `queued` with progress 0 and then follows normal FIFO order.
`shutdown()` stops starting work, aborts an active signal, and leaves an
active job persisted as `running` so a fresh queue can recover it. No method
may call `fetch`, reach a file path, or create a network client.

The queue exposes `snapshot()`, `getJob(id)`, `onChange(listener)` and
`waitForIdle()`. A change listener receives a snapshot after each persisted
state change. `waitForIdle()` resolves only when there is no queued or running
job.

## Status panel facade

`ExportController` wraps a started queue. `getViewState()` returns copied
data with `jobs` and `counts`. Each view job includes the original `id`,
`status`, `statusLabel`, `progress`, `attempts`, `result`, `error`,
`canCancel` and `canRetry`. Labels are `Waiting`, `Exporting`, `Ready`,
`Failed` and `Cancelled`. Counts use `waiting`, `running`, `succeeded`,
`failed` and `cancelled`. `requestExport`, `cancelExport` and `retryExport`
delegate to the queue. `subscribe(listener)` lets a UI redraw after changes
and returns an unsubscribe function.

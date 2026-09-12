'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { ExportStore } = require('./src/export-store.js');
const { ExportQueue } = require('./src/export-queue.js');
const { ExportController } = require('./src/export-controller.js');

class MemoryStorage {
  constructor() { this.values = new Map(); }
  getItem(key) { return this.values.has(key) ? this.values.get(key) : null; }
  setItem(key, value) { this.values.set(key, String(value)); }
}

function controlledWorker({ rejectOnAbort = false } = {}) {
  const calls = [];
  const worker = (payload, context) => new Promise((resolve, reject) => {
    const call = { payload, context, resolve, reject, aborted: false };
    calls.push(call);
    context.signal.addEventListener('abort', () => {
      call.aborted = true;
      if (rejectOnAbort) reject(new Error('aborted'));
    }, { once: true });
  });
  return { worker, calls };
}

function tick() {
  return new Promise((resolve) => setImmediate(resolve));
}

async function until(predicate, label) {
  const deadline = Date.now() + 800;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${label}`);
    await tick();
  }
}

function harness(worker, storage = new MemoryStorage()) {
  const store = new ExportStore(storage);
  const queue = new ExportQueue({ store, worker });
  return { storage, store, queue };
}

test('F2P persists a waiting export and starts only one worker', async () => {
  const controlled = controlledWorker();
  const { store, queue } = harness(controlled.worker);
  await queue.start();
  const first = await queue.enqueue({ name: 'one' });
  await until(() => controlled.calls.length === 1, 'first worker');
  const second = await queue.enqueue({ name: 'two' });
  await tick();
  const saved = store.load();
  assert.equal(controlled.calls.length, 1);
  assert.equal(saved.jobs.find((job) => job.id === first.id).status, 'running');
  assert.equal(saved.jobs.find((job) => job.id === second.id).status, 'queued');
  controlled.calls[0].resolve({ name: 'one' });
  await until(() => controlled.calls.length === 2, 'second worker');
  controlled.calls[1].resolve({ name: 'two' });
  await queue.waitForIdle();
});

test('F2P processes jobs FIFO and waits for the previous result', async () => {
  const controlled = controlledWorker();
  const { queue } = harness(controlled.worker);
  await queue.start();
  await queue.enqueue('first');
  await queue.enqueue('second');
  await until(() => controlled.calls.length > 0, 'first call');
  assert.deepEqual(controlled.calls.map((call) => call.payload), ['first']);
  controlled.calls[0].resolve('done:first');
  await until(() => controlled.calls.length === 2, 'second call');
  assert.equal(controlled.calls[1].payload, 'second');
  controlled.calls[1].resolve('done:second');
  await queue.waitForIdle();
});

test('F2P keeps later rows waiting in the status facade', async () => {
  const controlled = controlledWorker();
  const { queue } = harness(controlled.worker);
  const controller = new ExportController(queue);
  await controller.start();
  const first = await controller.requestExport({ name: 'one' });
  await until(() => controlled.calls.length === 1, 'running row');
  const second = await controller.requestExport({ name: 'two' });
  await tick();
  const rows = controller.getViewState().jobs;
  assert.deepEqual(rows.map((row) => row.id), [first.id, second.id]);
  assert.equal(rows[0].statusLabel, 'Exporting');
  assert.equal(rows[1].status, 'queued');
  assert.equal(rows[1].statusLabel, 'Waiting');
  assert.equal(rows[1].canCancel, true);
  controlled.calls[0].resolve('one');
  await until(() => controlled.calls.length === 2, 'next facade row');
  controlled.calls[1].resolve('two');
  await queue.waitForIdle();
});

test('F2P persists worker progress for the status panel', async () => {
  const controlled = controlledWorker();
  const { store, queue } = harness(controlled.worker);
  const controller = new ExportController(queue);
  await controller.start();
  const job = await controller.requestExport({ name: 'progress' });
  await until(() => controlled.calls.length === 1, 'progress worker');
  controlled.calls[0].context.report(37);
  assert.equal(store.load().jobs.find((row) => row.id === job.id).progress, 37);
  assert.equal(controller.getViewState().jobs[0].progress, 37);
  controlled.calls[0].resolve('ok');
  await queue.waitForIdle();
});

test('F2P clamps progress at both bounds before saving it', async () => {
  const controlled = controlledWorker();
  const { store, queue } = harness(controlled.worker);
  await queue.start();
  const job = await queue.enqueue({ name: 'bounds' });
  await until(() => controlled.calls.length === 1, 'bounds worker');
  controlled.calls[0].context.report(140);
  assert.equal(store.load().jobs[0].progress, 100);
  controlled.calls[0].context.report(-4);
  assert.equal(store.load().jobs[0].progress, 0);
  controlled.calls[0].context.report(Number.NaN);
  assert.equal(store.load().jobs[0].progress, 0);
  controlled.calls[0].resolve('ok');
  await queue.waitForIdle();
  assert.equal(queue.getJob(job.id).status, 'succeeded');
});

test('F2P records results in the same order the workers finish', async () => {
  const controlled = controlledWorker();
  const { store, queue } = harness(controlled.worker);
  await queue.start();
  const one = await queue.enqueue({ number: 1 });
  const two = await queue.enqueue({ number: 2 });
  await until(() => controlled.calls.length > 0, 'ordered worker');
  assert.equal(store.load().jobs.find((job) => job.id === two.id).status, 'queued');
  controlled.calls[0].resolve({ number: 1 });
  await until(() => controlled.calls.length === 2, 'ordered second worker');
  controlled.calls[1].resolve({ number: 2 });
  await queue.waitForIdle();
  assert.deepEqual(queue.snapshot().jobs.map((job) => job.result), [{ number: 1 }, { number: 2 }]);
  assert.equal(queue.getJob(one.id).attempts, 1);
});

test('F2P lets a later export run after an earlier failure', async () => {
  const controlled = controlledWorker();
  const { queue } = harness(controlled.worker);
  await queue.start();
  await queue.enqueue('bad');
  await queue.enqueue('good');
  await until(() => controlled.calls.length > 0, 'failure worker');
  assert.deepEqual(controlled.calls.map((call) => call.payload), ['bad']);
  controlled.calls[0].reject(new Error('disk full'));
  await until(() => controlled.calls.length === 2, 'post-failure worker');
  assert.equal(queue.snapshot().jobs[0].status, 'failed');
  assert.equal(queue.snapshot().jobs[0].error, 'disk full');
  controlled.calls[1].resolve('good');
  await queue.waitForIdle();
});

test('F2P retries a failed export without a manual queue restart', async () => {
  const controlled = controlledWorker();
  const { queue } = harness(controlled.worker);
  await queue.start();
  const job = await queue.enqueue('retry-me');
  await until(() => controlled.calls.length === 1, 'initial retry worker');
  controlled.calls[0].reject(new Error('temporary'));
  await queue.waitForIdle();
  assert.equal(queue.getJob(job.id).status, 'failed');
  assert.equal(await queue.retry(job.id), true);
  await until(() => controlled.calls.length === 2, 'retry worker');
  assert.equal(queue.getJob(job.id).attempts, 2);
  controlled.calls[1].resolve('recovered');
  await queue.waitForIdle();
  assert.deepEqual(queue.getJob(job.id).result, 'recovered');
});

test('F2P keeps attempt history and clears the old failure on retry', async () => {
  const controlled = controlledWorker();
  const { queue } = harness(controlled.worker);
  await queue.start();
  const job = await queue.enqueue('again');
  await until(() => controlled.calls.length === 1, 'attempt worker');
  controlled.calls[0].reject(new Error('temporary'));
  await queue.waitForIdle();
  await queue.retry(job.id);
  const queued = queue.getJob(job.id);
  assert.equal(queued.status, 'queued');
  assert.equal(queued.attempts, 1);
  assert.equal(queued.error, null);
  assert.equal(queued.result, null);
  await until(() => controlled.calls.length === 2, 'second attempt');
  controlled.calls[1].resolve('ok');
  await queue.waitForIdle();
});

test('F2P can cancel a waiting export before its worker starts', async () => {
  const controlled = controlledWorker();
  const { queue } = harness(controlled.worker);
  await queue.start();
  await queue.enqueue('active');
  await until(() => controlled.calls.length === 1, 'active worker');
  const waiting = await queue.enqueue('cancelled');
  await tick();
  assert.equal(queue.getJob(waiting.id).status, 'queued');
  assert.equal(await queue.cancel(waiting.id), true);
  assert.equal(queue.getJob(waiting.id).status, 'cancelled');
  assert.equal(controlled.calls.length, 1);
  controlled.calls[0].resolve('active');
  await queue.waitForIdle();
});

test('F2P aborts a running export when it is cancelled', async () => {
  const controlled = controlledWorker({ rejectOnAbort: true });
  const { store, queue } = harness(controlled.worker);
  await queue.start();
  const job = await queue.enqueue('stop');
  await until(() => controlled.calls.length === 1, 'cancel worker');
  assert.equal(await queue.cancel(job.id), true);
  await tick();
  assert.equal(controlled.calls[0].aborted, true);
  assert.equal(queue.getJob(job.id).status, 'cancelled');
  assert.equal(store.load().jobs[0].status, 'cancelled');
});

test('F2P ignores a late result after cancellation', async () => {
  const controlled = controlledWorker();
  const { store, queue } = harness(controlled.worker);
  await queue.start();
  const job = await queue.enqueue('late');
  await until(() => controlled.calls.length === 1, 'late worker');
  await queue.cancel(job.id);
  controlled.calls[0].resolve('must-not-appear');
  await tick();
  assert.equal(queue.getJob(job.id).status, 'cancelled');
  assert.equal(queue.getJob(job.id).result, null);
  assert.equal(store.load().jobs[0].status, 'cancelled');
});

test('F2P recovers a running export after a fresh queue starts', async () => {
  const storage = new MemoryStorage();
  const first = controlledWorker();
  const firstHarness = harness(first.worker, storage);
  await firstHarness.queue.start();
  const job = await firstHarness.queue.enqueue({ name: 'survive' });
  await until(() => first.calls.length === 1, 'old running worker');
  await firstHarness.queue.shutdown();
  assert.equal(firstHarness.store.load().jobs[0].status, 'running');

  const second = controlledWorker({ rejectOnAbort: true });
  const restarted = harness(second.worker, storage);
  await restarted.queue.start();
  await until(() => second.calls.length === 1, 'recovered worker');
  assert.equal(restarted.queue.getJob(job.id).status, 'running');
  assert.equal(restarted.queue.getJob(job.id).attempts, 2);
  second.calls[0].resolve('recovered');
  await restarted.queue.waitForIdle();
  assert.equal(restarted.queue.getJob(job.id).status, 'succeeded');
});

test('F2P recovers interrupted work before the already queued work', async () => {
  const storage = new MemoryStorage();
  const store = new ExportStore(storage);
  store.save({
    version: 1,
    nextId: 3,
    jobs: [
      { id: 'export-1', payload: 'interrupted', status: 'running', progress: 61, attempts: 1, result: null, error: null },
      { id: 'export-2', payload: 'waiting', status: 'queued', progress: 0, attempts: 0, result: null, error: null },
    ],
  });
  const controlled = controlledWorker();
  const { queue } = harness(controlled.worker, storage);
  await queue.start();
  await until(() => controlled.calls.length === 1, 'recovered first job');
  assert.equal(controlled.calls[0].payload, 'interrupted');
  assert.equal(queue.getJob('export-1').progress, 0);
  assert.equal(queue.getJob('export-2').status, 'queued');
  controlled.calls[0].resolve('first');
  await until(() => controlled.calls.length === 2, 'recovered queued job');
  assert.equal(controlled.calls[1].payload, 'waiting');
  controlled.calls[1].resolve('second');
  await queue.waitForIdle();
});

test('F2P keeps controller subscriptions and retry actions live', async () => {
  const controlled = controlledWorker();
  const { queue } = harness(controlled.worker);
  const controller = new ExportController(queue);
  await controller.start();
  const seen = [];
  const unsubscribe = controller.subscribe((view) => {
    seen.push(view.jobs.map((job) => job.status).join(','));
  });
  const job = await controller.requestExport('watch');
  await until(() => controlled.calls.length === 1, 'subscribed worker');
  controlled.calls[0].reject(new Error('retryable'));
  await queue.waitForIdle();
  assert.equal(controller.getViewState().jobs[0].canRetry, true);
  assert.equal(await controller.retryExport(job.id), true);
  await until(() => controlled.calls.length === 2, 'subscribed retry');
  controlled.calls[1].resolve('ready');
  await queue.waitForIdle();
  assert.equal(controller.getViewState().jobs[0].statusLabel, 'Ready');
  assert.equal(controller.getViewState().counts.succeeded, 1);
  assert.ok(seen.some((value) => value.includes('failed')));
  assert.ok(seen.some((value) => value.includes('succeeded')));
  unsubscribe();
});

test('P2P waits for the injected worker instead of fabricating completion', async () => {
  const controlled = controlledWorker();
  const { store, queue } = harness(controlled.worker);
  await queue.start();
  const job = await queue.enqueue('slow');
  await until(() => controlled.calls.length === 1, 'slow worker');
  await tick();
  assert.equal(queue.getJob(job.id).status, 'running');
  assert.equal(store.load().jobs[0].status, 'running');
  controlled.calls[0].resolve('real result');
  await queue.waitForIdle();
  assert.equal(queue.getJob(job.id).status, 'succeeded');
  assert.equal(queue.getJob(job.id).result, 'real result');
});

test('P2P passes the exact payload and control object to the worker', async () => {
  const controlled = controlledWorker();
  const { queue } = harness(controlled.worker);
  await queue.start();
  const payload = { format: 'csv', rows: [1, 2] };
  await queue.enqueue(payload);
  await until(() => controlled.calls.length === 1, 'payload worker');
  assert.deepEqual(controlled.calls[0].payload, payload);
  assert.equal(typeof controlled.calls[0].context.report, 'function');
  assert.equal(controlled.calls[0].context.signal.aborted, false);
  controlled.calls[0].context.report(20);
  controlled.calls[0].resolve('done');
  await queue.waitForIdle();
});

test('P2P malformed storage is safe and namespaced', async () => {
  const storage = new MemoryStorage();
  storage.setItem('iris.export-queue.v1', '{bad');
  storage.setItem('other-key', JSON.stringify({ should: 'stay' }));
  const store = new ExportStore(storage);
  assert.deepEqual(store.load(), { version: 1, nextId: 1, jobs: [] });
  assert.equal(storage.getItem('other-key'), JSON.stringify({ should: 'stay' }));
  const queue = new ExportQueue({ store, worker: async () => 'ok' });
  await queue.start();
  await queue.enqueue('fresh');
  await queue.waitForIdle();
  assert.deepEqual(JSON.parse(storage.getItem('other-key')), { should: 'stay' });
});

test('P2P terminal jobs cannot be cancelled or retried', async () => {
  const { queue } = harness(async () => 'done');
  await queue.start();
  const job = await queue.enqueue('terminal');
  await queue.waitForIdle();
  assert.equal(await queue.cancel(job.id), false);
  assert.equal(await queue.retry(job.id), false);
  assert.equal(queue.getJob(job.id).status, 'succeeded');
});

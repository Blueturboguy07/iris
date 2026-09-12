'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { ExportStore, normaliseState } = require('../src/export-store.js');
const { ExportQueue } = require('../src/export-queue.js');
const { ExportController, LABELS } = require('../src/export-controller.js');

class MemoryStorage {
  constructor() { this.values = new Map(); }
  getItem(key) { return this.values.has(key) ? this.values.get(key) : null; }
  setItem(key, value) { this.values.set(key, String(value)); }
}

test('the store uses the injected storage boundary', () => {
  const storage = new MemoryStorage();
  const store = new ExportStore(storage, 'fixture.queue');
  const state = { version: 1, nextId: 4, jobs: [] };
  store.save(state);
  assert.deepEqual(store.load(), state);
  assert.equal(storage.values.has('fixture.queue'), true);
});

test('malformed persisted values reset to an empty state', () => {
  assert.deepEqual(normaliseState('{not-json'), { version: 1, nextId: 1, jobs: [] });
  assert.deepEqual(normaliseState({ version: 9, jobs: [] }), { version: 1, nextId: 1, jobs: [] });
});

test('queue rejects missing boundaries', () => {
  assert.throws(() => new ExportStore(null), { name: 'TypeError' });
  assert.throws(() => new ExportQueue({ store: {}, worker: () => null }), { name: 'TypeError' });
  assert.throws(() => new ExportQueue({ store: { load() {}, save() {} }, worker: null }), { name: 'TypeError' });
});

test('a successful injected worker records its result', async () => {
  const store = new ExportStore(new MemoryStorage());
  const queue = new ExportQueue({ store, worker: async (payload) => ({ echoed: payload.value }) });
  await queue.start();
  const job = await queue.enqueue({ value: 7 });
  await queue.waitForIdle();
  assert.deepEqual(queue.getJob(job.id).result, { echoed: 7 });
  assert.equal(queue.getJob(job.id).status, 'succeeded');
});

test('controller exposes stable labels', () => {
  assert.deepEqual(LABELS, {
    queued: 'Waiting', running: 'Exporting', succeeded: 'Ready',
    failed: 'Failed', cancelled: 'Cancelled',
  });
  const queue = new ExportQueue({
    store: new ExportStore(new MemoryStorage()), worker: async () => 'ok',
  });
  const controller = new ExportController(queue);
  assert.deepEqual(controller.getViewState().counts, {
    waiting: 0, running: 0, succeeded: 0, failed: 0, cancelled: 0,
  });
});

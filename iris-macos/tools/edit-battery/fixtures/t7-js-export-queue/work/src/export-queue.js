'use strict';

const { emptyState } = require('./export-store.js');

const TERMINAL = new Set(['succeeded', 'failed', 'cancelled']);

function copy(value) {
  return JSON.parse(JSON.stringify(value));
}

function errorText(error) {
  return error instanceof Error ? error.message : String(error);
}

class ExportQueue {
  constructor({ store, worker }) {
    if (!store || typeof store.load !== 'function' || typeof store.save !== 'function') {
      throw new TypeError('store must provide load and save');
    }
    if (typeof worker !== 'function') {
      throw new TypeError('worker must be a function');
    }
    this.store = store;
    this.worker = worker;
    this.state = emptyState();
    this.listeners = new Set();
    this.active = new Map();
    this.started = false;
    this.closed = false;
    this.draining = false;
  }

  async start() {
    if (this.started) return this.snapshot();
    this.state = this.store.load();
    this.started = true;
    this.closed = false;
    this.persist();
    this.drain();
    return this.snapshot();
  }

  onChange(listener) {
    if (typeof listener !== 'function') throw new TypeError('listener must be a function');
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  snapshot() {
    return copy(this.state);
  }

  getJob(id) {
    const job = this.state.jobs.find((candidate) => candidate.id === id);
    return job ? copy(job) : undefined;
  }

  async enqueue(payload) {
    this.ensureStarted();
    const job = {
      id: `export-${this.state.nextId++}`,
      payload: copy(payload),
      status: 'queued',
      progress: 0,
      attempts: 0,
      result: null,
      error: null,
    };
    this.state.jobs.push(job);
    this.persist();
    this.drain();
    return copy(job);
  }

  async cancel(id) {
    this.ensureStarted();
    const job = this.state.jobs.find((candidate) => candidate.id === id);
    if (!job || TERMINAL.has(job.status)) return false;
    job.status = 'cancelled';
    job.progress = 0;
    this.persist();
    this.drain();
    return true;
  }

  async retry(id) {
    this.ensureStarted();
    const job = this.state.jobs.find((candidate) => candidate.id === id);
    if (!job || job.status !== 'failed') return false;
    job.status = 'queued';
    job.progress = 0;
    job.attempts = 0;
    job.result = null;
    job.error = null;
    this.persist();
    return true;
  }

  async shutdown() {
    if (!this.started) return this.snapshot();
    this.closed = true;
    this.started = false;
    this.persist();
    return this.snapshot();
  }

  async waitForIdle() {
    this.ensureStarted();
    if (this.isIdle()) return this.snapshot();
    return new Promise((resolve) => {
      const unsubscribe = this.onChange(() => {
        if (this.isIdle()) {
          unsubscribe();
          resolve(this.snapshot());
        }
      });
    });
  }

  ensureStarted() {
    if (!this.started || this.closed) throw new Error('queue is not started');
  }

  isIdle() {
    return this.active.size === 0 && !this.state.jobs.some((job) => job.status === 'queued' || job.status === 'running');
  }

  persist() {
    this.store.save(this.state);
    const snapshot = this.snapshot();
    for (const listener of this.listeners) {
      try { listener(snapshot); } catch (_error) { /* observers cannot stop the queue */ }
    }
  }

  drain() {
    if (!this.started || this.closed || this.draining) return;
    this.draining = true;
    Promise.resolve().then(async () => {
      while (this.started && !this.closed) {
        const job = this.state.jobs.find((candidate) => candidate.status === 'queued');
        if (!job) break;
        this.run(job);
      }
    }).finally(() => {
      this.draining = false;
      if (this.started && !this.closed && this.state.jobs.some((job) => job.status === 'queued')) {
        this.drain();
      }
    });
  }

  async run(job) {
    job.status = 'running';
    job.attempts += 1;
    this.persist();
    const controller = new AbortController();
    this.active.set(job.id, controller);
    try {
      const result = await this.worker(job.payload, {
        signal: controller.signal,
        report: (progress) => {
          if (job.status !== 'running' || !Number.isFinite(progress)) return;
          job.progress = Math.max(0, Math.min(100, progress));
        },
      });
      if (!this.closed) {
        job.status = 'succeeded';
        job.progress = 100;
        job.result = copy(result);
        this.persist();
      }
    } catch (error) {
      if (!this.closed) {
        job.status = 'failed';
        job.error = errorText(error);
        this.persist();
      }
    } finally {
      const wasActive = this.active.delete(job.id);
      if (wasActive && this.started && !this.closed) this.persist();
    }
  }
}

module.exports = { ExportQueue };

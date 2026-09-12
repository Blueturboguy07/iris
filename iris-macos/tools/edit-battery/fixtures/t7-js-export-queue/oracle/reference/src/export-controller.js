'use strict';

const LABELS = {
  queued: 'Waiting',
  running: 'Exporting',
  succeeded: 'Ready',
  failed: 'Failed',
  cancelled: 'Cancelled',
};

function copy(value) {
  return JSON.parse(JSON.stringify(value));
}

function viewFor(state) {
  const jobs = state.jobs.map((job) => ({
    id: job.id,
    status: job.status,
    statusLabel: LABELS[job.status] || job.status,
    progress: job.progress,
    attempts: job.attempts,
    result: job.result,
    error: job.error,
    canCancel: job.status === 'queued' || job.status === 'running',
    canRetry: job.status === 'failed',
  }));
  const counts = { waiting: 0, running: 0, succeeded: 0, failed: 0, cancelled: 0 };
  for (const job of jobs) {
    const key = job.status === 'queued' ? 'waiting' : job.status;
    if (Object.prototype.hasOwnProperty.call(counts, key)) counts[key] += 1;
  }
  return { jobs, counts };
}

class ExportController {
  constructor(queue) {
    if (!queue || typeof queue.start !== 'function' || typeof queue.onChange !== 'function') {
      throw new TypeError('queue must provide start and onChange');
    }
    this.queue = queue;
    this.view = viewFor(queue.snapshot());
    this.listeners = new Set();
    this.unsubscribeQueue = null;
  }

  async start() {
    if (!this.unsubscribeQueue) {
      this.unsubscribeQueue = this.queue.onChange((state) => this.publish(state));
    }
    await this.queue.start();
    this.view = viewFor(this.queue.snapshot());
    return this.getViewState();
  }

  getViewState() {
    return copy(this.view);
  }

  subscribe(listener) {
    if (typeof listener !== 'function') throw new TypeError('listener must be a function');
    this.listeners.add(listener);
    listener(this.getViewState());
    return () => this.listeners.delete(listener);
  }

  async requestExport(payload) { return this.queue.enqueue(payload); }
  async cancelExport(id) { return this.queue.cancel(id); }
  async retryExport(id) { return this.queue.retry(id); }

  dispose() {
    if (this.unsubscribeQueue) this.unsubscribeQueue();
    this.unsubscribeQueue = null;
    this.listeners.clear();
  }

  publish(state) {
    this.view = viewFor(state);
    for (const listener of this.listeners) listener(this.getViewState());
  }
}

module.exports = { ExportController, LABELS };

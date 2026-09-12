'use strict';

const VERSION = 1;

function copy(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

function emptyState() {
  return { version: VERSION, nextId: 1, jobs: [] };
}

function normaliseState(raw) {
  let parsed = raw;
  if (typeof raw === 'string') {
    try {
      parsed = JSON.parse(raw);
    } catch (_error) {
      return emptyState();
    }
  }
  if (!parsed || typeof parsed !== 'object' || parsed.version !== VERSION ||
      !Array.isArray(parsed.jobs)) {
    return emptyState();
  }
  const jobs = parsed.jobs.filter((job) => job && typeof job === 'object' &&
    typeof job.id === 'string').map((job) => ({
    id: job.id,
    payload: copy(job.payload),
    status: job.status,
    progress: Number.isFinite(job.progress) ? job.progress : 0,
    attempts: Number.isInteger(job.attempts) ? job.attempts : 0,
    result: copy(job.result),
    error: job.error == null ? null : String(job.error),
  }));
  const nextId = Number.isInteger(parsed.nextId) && parsed.nextId > 0
    ? parsed.nextId : 1;
  return { version: VERSION, nextId, jobs };
}

class ExportStore {
  constructor(storage, key = 'iris.export-queue.v1') {
    if (!storage || typeof storage.getItem !== 'function' ||
        typeof storage.setItem !== 'function') {
      throw new TypeError('storage must provide getItem and setItem');
    }
    this.storage = storage;
    this.key = key;
  }

  load() {
    return copy(normaliseState(this.storage.getItem(this.key)));
  }

  save(state) {
    const clean = normaliseState(state);
    this.storage.setItem(this.key, JSON.stringify(clean));
    return copy(clean);
  }
}

module.exports = { ExportStore, emptyState, normaliseState };

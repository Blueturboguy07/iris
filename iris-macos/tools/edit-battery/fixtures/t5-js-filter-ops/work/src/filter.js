'use strict';

const { OPERATORS } = require('./operators.js');

/**
 * Validate a filter object. Throws on anything malformed; returns the
 * registry entry for the operator when the filter is well formed.
 *
 * The rules, and the exact messages, are in docs/FILTERS.md.
 */
function validate(filter) {
  if (filter === null || typeof filter !== 'object') {
    throw new TypeError('filter must be an object');
  }
  if (typeof filter.field !== 'string' || filter.field.length === 0) {
    throw new TypeError('filter.field must be a non-empty string');
  }
  if (!Array.isArray(filter.args)) {
    throw new TypeError('filter.args must be an array');
  }

  const operator = Object.prototype.hasOwnProperty.call(OPERATORS, filter.op)
    ? OPERATORS[filter.op]
    : undefined;
  if (!operator) {
    throw new Error(`unknown operator: ${filter.op}`);
  }

  if (filter.args.length !== operator.arity) {
    throw new Error(
      `operator "${filter.op}" expects ${operator.arity} argument(s), got ${filter.args.length}`
    );
  }

  if (operator.argType === 'number') {
    for (const arg of filter.args) {
      if (typeof arg !== 'number' || !Number.isFinite(arg)) {
        throw new TypeError(`operator "${filter.op}" requires numeric arguments`);
      }
    }
  } else if (operator.argType === 'string') {
    for (const arg of filter.args) {
      if (typeof arg !== 'string') {
        throw new TypeError(`operator "${filter.op}" requires string arguments`);
      }
    }
  }

  if (typeof operator.check === 'function') {
    operator.check(filter.args);
  }

  return operator;
}

/**
 * Does one row satisfy one filter?
 *
 * Row data is never trusted: a missing, null or wrongly-typed field value
 * yields false rather than throwing. Only the filter itself can throw.
 */
function applyOne(row, filter) {
  const operator = validate(filter);
  if (row === null || typeof row !== 'object') {
    throw new TypeError('row must be an object');
  }

  const value = row[filter.field];
  if (value === undefined || value === null) {
    return false;
  }
  if (operator.argType === 'number' &&
      (typeof value !== 'number' || !Number.isFinite(value))) {
    return false;
  }

  return Boolean(operator.apply(value, filter.args));
}

/** Rows for which every filter holds. An empty filter list keeps everything. */
function applyAll(rows, filters) {
  if (!Array.isArray(rows)) {
    throw new TypeError('rows must be an array');
  }
  if (!Array.isArray(filters)) {
    throw new TypeError('filters must be an array');
  }
  for (const filter of filters) {
    validate(filter);
  }
  return rows.filter((row) => filters.every((filter) => applyOne(row, filter)));
}

module.exports = { validate, applyOne, applyAll };

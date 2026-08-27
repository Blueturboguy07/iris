'use strict';
// Held-out oracle for t5-js-filter-ops (feature task).
// Dropped into a pristine copy at grade time; the agent never sees it.
//   run: node --test oracle.test.js
// Every assertion below is stated in docs/FILTERS.md, which IS in the repo.

const test = require('node:test');
const assert = require('node:assert/strict');

const { validate, applyOne, applyAll } = require('./src/filter.js');
const { OPERATORS, operatorNames } = require('./src/operators.js');

const ROWS = [
  { name: 'ana', team: 'infra', age: 31, score: 0 },
  { name: 'bo', team: 'billing', age: 24, score: -5 },
  { name: 'cy', team: 'infra', age: 47, score: 12.5 },
  { name: 'di', team: null, age: null, score: 'n/a' },
  { name: 'ed', team: 'infra' },
];

// ---------------- F2P: the three new operators ----------------------------

test('F2P gt is strict and numeric', () => {
  assert.equal(applyOne(ROWS[0], { field: 'age', op: 'gt', args: [30] }), true);
  assert.equal(applyOne(ROWS[0], { field: 'age', op: 'gt', args: [31] }), false);
  assert.equal(applyOne(ROWS[0], { field: 'age', op: 'gt', args: [32] }), false);
  assert.equal(applyOne(ROWS[1], { field: 'score', op: 'gt', args: [-6] }), true);
  assert.equal(applyOne(ROWS[2], { field: 'score', op: 'gt', args: [12] }), true);
  assert.equal(applyOne(ROWS[2], { field: 'score', op: 'gt', args: [12.5] }), false);
});

test('F2P lt is strict and numeric', () => {
  assert.equal(applyOne(ROWS[1], { field: 'age', op: 'lt', args: [25] }), true);
  assert.equal(applyOne(ROWS[1], { field: 'age', op: 'lt', args: [24] }), false);
  assert.equal(applyOne(ROWS[1], { field: 'score', op: 'lt', args: [0] }), true);
  assert.equal(applyOne(ROWS[0], { field: 'score', op: 'lt', args: [0] }), false);
});

test('F2P between is inclusive on both ends', () => {
  const f = (lo, hi) => ({ field: 'age', op: 'between', args: [lo, hi] });
  assert.equal(applyOne(ROWS[0], f(31, 31)), true);
  assert.equal(applyOne(ROWS[0], f(31, 40)), true);
  assert.equal(applyOne(ROWS[0], f(20, 31)), true);
  assert.equal(applyOne(ROWS[0], f(32, 40)), false);
  assert.equal(applyOne(ROWS[0], f(20, 30)), false);
  assert.equal(applyOne(ROWS[1], f(24, 47)), true);
  assert.equal(applyOne(ROWS[2], f(24, 47)), true);
});

test('F2P new operators follow the row-data rules', () => {
  for (const op of ['gt', 'lt']) {
    // null / missing field -> false, never a throw
    assert.equal(applyOne(ROWS[3], { field: 'age', op, args: [1] }), false);
    assert.equal(applyOne(ROWS[4], { field: 'age', op, args: [1] }), false);
    // non-numeric field value -> false, never a throw
    assert.equal(applyOne(ROWS[3], { field: 'score', op, args: [1] }), false);
    assert.equal(applyOne(ROWS[0], { field: 'name', op, args: [1] }), false);
  }
  assert.equal(applyOne(ROWS[3], { field: 'age', op: 'between', args: [0, 100] }), false);
  assert.equal(applyOne(ROWS[4], { field: 'age', op: 'between', args: [0, 100] }), false);
  assert.equal(applyOne(ROWS[3], { field: 'score', op: 'between', args: [0, 100] }), false);
  assert.equal(applyOne(ROWS[0], { field: 'name', op: 'between', args: [0, 100] }), false);
});

test('F2P new operators declare the documented arity', () => {
  assert.throws(
    () => validate({ field: 'age', op: 'gt', args: [1, 2] }),
    { message: 'operator "gt" expects 1 argument(s), got 2' }
  );
  assert.throws(
    () => validate({ field: 'age', op: 'lt', args: [] }),
    { message: 'operator "lt" expects 1 argument(s), got 0' }
  );
  assert.throws(
    () => validate({ field: 'age', op: 'between', args: [1] }),
    { message: 'operator "between" expects 2 argument(s), got 1' }
  );
  assert.throws(
    () => validate({ field: 'age', op: 'between', args: [1, 2, 3] }),
    { message: 'operator "between" expects 2 argument(s), got 3' }
  );
});

test('F2P new operators type-check their arguments as numeric', () => {
  for (const bad of ['30', null, undefined, NaN, Infinity, -Infinity, {}, [30]]) {
    for (const op of ['gt', 'lt']) {
      assert.throws(
        () => validate({ field: 'age', op, args: [bad] }),
        { name: 'TypeError', message: `operator "${op}" requires numeric arguments` },
        `${op} should reject ${String(bad)}`
      );
    }
    assert.throws(
      () => validate({ field: 'age', op: 'between', args: [bad, 10] }),
      { name: 'TypeError', message: 'operator "between" requires numeric arguments' }
    );
    assert.throws(
      () => validate({ field: 'age', op: 'between', args: [0, bad] }),
      { name: 'TypeError', message: 'operator "between" requires numeric arguments' }
    );
  }
});

test('F2P between rejects a reversed range', () => {
  assert.throws(
    () => validate({ field: 'age', op: 'between', args: [10, 5] }),
    { message: 'operator "between" requires args[0] <= args[1]' }
  );
  // equal bounds are a legal, single-value range
  assert.doesNotThrow(() => validate({ field: 'age', op: 'between', args: [5, 5] }));
  assert.doesNotThrow(() => validate({ field: 'age', op: 'between', args: [-5, 5] }));
});

test('F2P the new operators are registry entries, not special cases', () => {
  for (const op of ['gt', 'lt', 'between']) {
    assert.ok(Object.prototype.hasOwnProperty.call(OPERATORS, op),
      `${op} must be in the operator registry`);
    assert.equal(typeof OPERATORS[op].apply, 'function');
    assert.equal(OPERATORS[op].argType, 'number');
  }
  assert.equal(OPERATORS.gt.arity, 1);
  assert.equal(OPERATORS.lt.arity, 1);
  assert.equal(OPERATORS.between.arity, 2);
  assert.deepEqual(operatorNames(), ['between', 'contains', 'eq', 'gt', 'lt']);
});

test('F2P the new operators compose through applyAll', () => {
  const kept = applyAll(ROWS, [
    { field: 'team', op: 'eq', args: ['infra'] },
    { field: 'age', op: 'gt', args: [30] },
    { field: 'age', op: 'lt', args: [50] },
  ]);
  assert.deepEqual(kept.map((r) => r.name), ['ana', 'cy']);

  const banded = applyAll(ROWS, [{ field: 'age', op: 'between', args: [24, 31] }]);
  assert.deepEqual(banded.map((r) => r.name), ['ana', 'bo']);

  assert.throws(
    () => applyAll(ROWS, [{ field: 'age', op: 'between', args: [9, 1] }]),
    { message: 'operator "between" requires args[0] <= args[1]' }
  );
});

test('F2P a sweep of numeric boundaries', () => {
  const rows = [];
  for (let n = -5; n <= 5; n++) rows.push({ v: n });
  for (let bound = -6; bound <= 6; bound++) {
    assert.deepEqual(
      applyAll(rows, [{ field: 'v', op: 'gt', args: [bound] }]).map((r) => r.v),
      rows.map((r) => r.v).filter((v) => v > bound)
    );
    assert.deepEqual(
      applyAll(rows, [{ field: 'v', op: 'lt', args: [bound] }]).map((r) => r.v),
      rows.map((r) => r.v).filter((v) => v < bound)
    );
  }
  for (let lo = -6; lo <= 6; lo++) {
    for (let hi = lo; hi <= 6; hi++) {
      assert.deepEqual(
        applyAll(rows, [{ field: 'v', op: 'between', args: [lo, hi] }]).map((r) => r.v),
        rows.map((r) => r.v).filter((v) => v >= lo && v <= hi),
        `between(${lo}, ${hi})`
      );
    }
  }
});

// ---------------- P2P: nothing that already worked may change --------------

test('P2P eq is unchanged', () => {
  assert.equal(applyOne(ROWS[0], { field: 'team', op: 'eq', args: ['infra'] }), true);
  assert.equal(applyOne(ROWS[1], { field: 'team', op: 'eq', args: ['infra'] }), false);
  assert.equal(applyOne(ROWS[0], { field: 'age', op: 'eq', args: ['31'] }), false);
  assert.equal(applyOne(ROWS[0], { field: 'age', op: 'eq', args: [31] }), true);
});

test('P2P contains is unchanged', () => {
  assert.equal(applyOne(ROWS[1], { field: 'team', op: 'contains', args: ['bill'] }), true);
  assert.equal(applyOne(ROWS[0], { field: 'team', op: 'contains', args: ['bill'] }), false);
  assert.throws(
    () => validate({ field: 'team', op: 'contains', args: [7] }),
    { name: 'TypeError', message: 'operator "contains" requires string arguments' }
  );
});

test('P2P null and missing fields are still false', () => {
  assert.equal(applyOne(ROWS[3], { field: 'team', op: 'eq', args: ['infra'] }), false);
  assert.equal(applyOne(ROWS[3], { field: 'nope', op: 'contains', args: ['x'] }), false);
});

test('P2P malformed filters still throw the same way', () => {
  assert.throws(() => validate({ field: 'age', op: 'nope', args: [1] }),
    { message: 'unknown operator: nope' });
  assert.throws(() => validate({ field: 'team', op: 'eq', args: [] }),
    { message: 'operator "eq" expects 1 argument(s), got 0' });
  assert.throws(() => validate({ field: '', op: 'eq', args: [1] }),
    { name: 'TypeError', message: 'filter.field must be a non-empty string' });
  assert.throws(() => validate({ field: 'a', op: 'eq', args: 'x' }),
    { name: 'TypeError', message: 'filter.args must be an array' });
  assert.throws(() => validate(null), { name: 'TypeError' });
  assert.throws(() => applyAll('x', []), { name: 'TypeError' });
  assert.throws(() => applyAll([], 'x'), { name: 'TypeError' });
});

test('P2P applyAll still ands and still keeps everything on an empty list', () => {
  const kept = applyAll(ROWS, [
    { field: 'team', op: 'eq', args: ['infra'] },
    { field: 'name', op: 'contains', args: ['a'] },
  ]);
  assert.deepEqual(kept.map((r) => r.name), ['ana']);
  assert.equal(applyAll(ROWS, []).length, ROWS.length);
});

test('P2P operatorNames is still sorted', () => {
  const names = operatorNames();
  assert.deepEqual(names, [...names].sort());
});

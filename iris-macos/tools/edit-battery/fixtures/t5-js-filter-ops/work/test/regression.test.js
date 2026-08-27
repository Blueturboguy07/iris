'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { validate, applyOne, applyAll } = require('../src/filter.js');
const { operatorNames } = require('../src/operators.js');

const ROWS = [
  { name: 'ana', team: 'infra', age: 31 },
  { name: 'bo', team: 'billing', age: 24 },
  { name: 'cy', team: 'infra', age: 47 },
  { name: 'di', team: null, age: null },
];

test('eq matches strictly', () => {
  assert.equal(applyOne(ROWS[0], { field: 'team', op: 'eq', args: ['infra'] }), true);
  assert.equal(applyOne(ROWS[1], { field: 'team', op: 'eq', args: ['infra'] }), false);
  assert.equal(applyOne(ROWS[0], { field: 'age', op: 'eq', args: ['31'] }), false);
});

test('contains matches substrings', () => {
  assert.equal(applyOne(ROWS[1], { field: 'team', op: 'contains', args: ['bill'] }), true);
  assert.equal(applyOne(ROWS[0], { field: 'team', op: 'contains', args: ['bill'] }), false);
});

test('a null or missing field is false, never a throw', () => {
  assert.equal(applyOne(ROWS[3], { field: 'team', op: 'eq', args: ['infra'] }), false);
  assert.equal(applyOne(ROWS[3], { field: 'nope', op: 'contains', args: ['x'] }), false);
});

test('unknown operators are rejected', () => {
  assert.throws(
    () => validate({ field: 'age', op: 'nope', args: [1] }),
    { message: 'unknown operator: nope' }
  );
});

test('wrong arity is rejected', () => {
  assert.throws(
    () => validate({ field: 'team', op: 'eq', args: [] }),
    { message: 'operator "eq" expects 1 argument(s), got 0' }
  );
});

test('string operators type-check their arguments', () => {
  assert.throws(
    () => validate({ field: 'team', op: 'contains', args: [7] }),
    { name: 'TypeError', message: 'operator "contains" requires string arguments' }
  );
});

test('malformed filters are rejected', () => {
  assert.throws(() => validate({ field: '', op: 'eq', args: [1] }),
    { name: 'TypeError', message: 'filter.field must be a non-empty string' });
  assert.throws(() => validate({ field: 'a', op: 'eq', args: 'x' }),
    { name: 'TypeError', message: 'filter.args must be an array' });
});

test('applyAll ands the filters together', () => {
  const kept = applyAll(ROWS, [
    { field: 'team', op: 'eq', args: ['infra'] },
    { field: 'name', op: 'contains', args: ['a'] },
  ]);
  assert.deepEqual(kept.map((row) => row.name), ['ana']);
  assert.equal(applyAll(ROWS, []).length, ROWS.length);
});

test('the registry exposes its names, sorted', () => {
  const names = operatorNames();
  assert.ok(names.includes('eq'));
  assert.ok(names.includes('contains'));
  assert.deepEqual(names, [...names].sort());
});

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { splitEvenly, sumCents, formatCents } = require('../src/money.js');

test('splits a total that divides exactly', () => {
  assert.deepEqual(splitEvenly(1000, 4), [250, 250, 250, 250]);
  assert.deepEqual(splitEvenly(9, 3), [3, 3, 3]);
});

test('a single part gets the whole total', () => {
  assert.deepEqual(splitEvenly(7, 1), [7]);
  assert.deepEqual(splitEvenly(-7, 1), [-7]);
});

test('zero splits into zeroes', () => {
  assert.deepEqual(splitEvenly(0, 3), [0, 0, 0]);
});

test('negative totals that divide exactly', () => {
  assert.deepEqual(splitEvenly(-1000, 4), [-250, -250, -250, -250]);
});

test('rejects a bad part count', () => {
  assert.throws(() => splitEvenly(100, 0), RangeError);
  assert.throws(() => splitEvenly(100, -2), RangeError);
  assert.throws(() => splitEvenly(100, 2.5), RangeError);
});

test('rejects a non-integer total', () => {
  assert.throws(() => splitEvenly(10.5, 2), TypeError);
  assert.throws(() => splitEvenly('100', 2), TypeError);
});

test('sumCents adds whole cents', () => {
  assert.equal(sumCents([1, 2, 3]), 6);
  assert.equal(sumCents([]), 0);
  assert.throws(() => sumCents([1.5]), TypeError);
});

test('formatCents renders a decimal string', () => {
  assert.equal(formatCents(1234), '12.34');
  assert.equal(formatCents(-1234), '-12.34');
  assert.equal(formatCents(5), '0.05');
});

'use strict';
// Held-out oracle for t2-js-money-split. Dropped into a pristine copy at
// grade time; the agent never sees this file.
//   run: node --test oracle.test.js
// F2P: "F2P ..." tests. P2P: "P2P ..." tests.

const test = require('node:test');
const assert = require('node:assert/strict');

const { splitEvenly, sumCents, formatCents } = require('./src/money.js');

// -------- F2P: the three documented guarantees, swept ----------------------

const TOTALS = [];
for (let t = -60; t <= 60; t++) TOTALS.push(t);
for (const t of [97, -97, 100, -100, 999, -999, 1000, -1000, 12345, -12345,
                 1000003, -1000003]) TOTALS.push(t);
const PARTS = [1, 2, 3, 4, 5, 6, 7, 11, 13, 97];

test('F2P conservation: the parts always sum to the total', () => {
  let checked = 0;
  for (const total of TOTALS) {
    for (const parts of PARTS) {
      const out = splitEvenly(total, parts);
      assert.equal(out.length, parts, `length for (${total}, ${parts})`);
      assert.equal(sumCents(out), total,
        `sum for (${total}, ${parts}) was ${sumCents(out)} from ${JSON.stringify(out)}`);
      checked++;
    }
  }
  assert.equal(checked, TOTALS.length * PARTS.length);
});

test('F2P fairness: largest and smallest differ by at most one cent', () => {
  for (const total of TOTALS) {
    for (const parts of PARTS) {
      const out = splitEvenly(total, parts);
      const max = Math.max(...out);
      const min = Math.min(...out);
      assert.ok(max - min <= 1,
        `spread ${max - min} for (${total}, ${parts}): ${JSON.stringify(out)}`);
    }
  }
});

test('F2P order: results are non-increasing', () => {
  for (const total of TOTALS) {
    for (const parts of PARTS) {
      const out = splitEvenly(total, parts);
      for (let i = 1; i < out.length; i++) {
        assert.ok(out[i - 1] >= out[i],
          `not non-increasing at ${i} for (${total}, ${parts}): ${JSON.stringify(out)}`);
      }
    }
  }
});

test('F2P every worked example in docs/MONEY.md', () => {
  assert.deepEqual(splitEvenly(1000, 4), [250, 250, 250, 250]);
  assert.deepEqual(splitEvenly(1000, 3), [334, 333, 333]);
  assert.deepEqual(splitEvenly(100, 3), [34, 33, 33]);
  assert.deepEqual(splitEvenly(-1000, 3), [-333, -333, -334]);
  assert.deepEqual(splitEvenly(-100, 3), [-33, -33, -34]);
  assert.deepEqual(splitEvenly(7, 1), [7]);
  assert.deepEqual(splitEvenly(0, 3), [0, 0, 0]);
});

test('F2P integrality: every part is a whole cent', () => {
  for (const total of TOTALS) {
    for (const parts of PARTS) {
      for (const cent of splitEvenly(total, parts)) {
        assert.ok(Number.isSafeInteger(cent),
          `non-integer ${cent} for (${total}, ${parts})`);
      }
    }
  }
});

// -------- P2P: green before the fix, must stay green -----------------------

test('P2P exact divisions are unchanged', () => {
  assert.deepEqual(splitEvenly(1000, 4), [250, 250, 250, 250]);
  assert.deepEqual(splitEvenly(9, 3), [3, 3, 3]);
  assert.deepEqual(splitEvenly(-1000, 4), [-250, -250, -250, -250]);
  assert.deepEqual(splitEvenly(-7, 1), [-7]);
});

test('P2P argument validation is unchanged', () => {
  assert.throws(() => splitEvenly(100, 0), RangeError);
  assert.throws(() => splitEvenly(100, -2), RangeError);
  assert.throws(() => splitEvenly(100, 2.5), RangeError);
  assert.throws(() => splitEvenly(100, '2'), RangeError);
  assert.throws(() => splitEvenly(10.5, 2), TypeError);
  assert.throws(() => splitEvenly('100', 2), TypeError);
  assert.throws(() => splitEvenly(NaN, 2), TypeError);
});

test('P2P sumCents is unchanged', () => {
  assert.equal(sumCents([1, 2, 3]), 6);
  assert.equal(sumCents([]), 0);
  assert.throws(() => sumCents([1.5]), TypeError);
});

test('P2P formatCents is unchanged', () => {
  assert.equal(formatCents(1234), '12.34');
  assert.equal(formatCents(-1234), '-12.34');
  assert.equal(formatCents(5), '0.05');
  assert.equal(formatCents(0), '0.00');
  assert.throws(() => formatCents(1.5), TypeError);
});

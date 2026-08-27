'use strict';

/**
 * Divide a whole-cent total into `parts` whole-cent amounts.
 *
 * The contract (see docs/MONEY.md) is:
 *   - the results sum to exactly `totalCents`,
 *   - the largest and smallest differ by at most one cent,
 *   - the results are in non-increasing order,
 *   - negative totals follow the same rules.
 *
 * @param {number} totalCents whole cents, may be negative
 * @param {number} parts      integer >= 1
 * @returns {number[]}
 */
function splitEvenly(totalCents, parts) {
  if (!Number.isSafeInteger(totalCents)) {
    throw new TypeError('totalCents must be a safe integer number of cents');
  }
  if (!Number.isInteger(parts) || parts < 1) {
    throw new RangeError('parts must be an integer >= 1');
  }

  const base = Math.trunc(totalCents / parts);
  const out = new Array(parts).fill(base);
  let remainder = totalCents - base * parts;
  const step = remainder > 0 ? 1 : -1;
  for (let k = 0; k < Math.abs(remainder); k++) {
    // A positive odd cent goes to the front so the array stays
    // non-increasing; a negative one goes to the back, for the same reason.
    const index = remainder > 0 ? k : parts - 1 - k;
    out[index] += step;
  }
  return out;
}

/**
 * Total of a list of whole-cent amounts.
 * @param {number[]} amounts
 * @returns {number}
 */
function sumCents(amounts) {
  let total = 0;
  for (const amount of amounts) {
    if (!Number.isSafeInteger(amount)) {
      throw new TypeError('every amount must be a safe integer number of cents');
    }
    total += amount;
  }
  return total;
}

/**
 * Render whole cents as a decimal string, e.g. -1234 -> "-12.34".
 * @param {number} cents
 * @returns {string}
 */
function formatCents(cents) {
  if (!Number.isSafeInteger(cents)) {
    throw new TypeError('cents must be a safe integer');
  }
  const sign = cents < 0 ? '-' : '';
  const magnitude = Math.abs(cents);
  const whole = Math.trunc(magnitude / 100);
  const fraction = String(magnitude % 100).padStart(2, '0');
  return `${sign}${whole}.${fraction}`;
}

module.exports = { splitEvenly, sumCents, formatCents };

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { verify, trustedKeyIds } = require('../src/license.js');
const tokens = require('./tokens.json');

test('a licence signed by a vendored key verifies', () => {
  const result = verify(tokens.valid_old);
  assert.equal(result.valid, true);
  assert.equal(result.reason, null);
  assert.equal(result.payload.kid, '2025-01');
  assert.equal(result.payload.seats, 25);
});

test('a tampered payload is rejected', () => {
  const result = verify(tokens.tampered_old);
  assert.equal(result.valid, false);
  assert.equal(result.reason, 'signature does not verify');
  assert.equal(result.payload, null);
});

test('an unknown key id is rejected', () => {
  const result = verify(tokens.unknown_kid);
  assert.equal(result.valid, false);
  assert.equal(result.reason, 'unknown key id: 2024-07');
});

test('malformed tokens are rejected', () => {
  for (const bad of [tokens.malformed, '', 'a.b.c', null, 42, 'onlyonesegment']) {
    assert.equal(verify(bad).valid, false);
  }
});

test('this build trusts exactly the vendored key ids', () => {
  assert.deepEqual(trustedKeyIds(), Object.keys(require('../keys/pubkeys.json')).sort());
});

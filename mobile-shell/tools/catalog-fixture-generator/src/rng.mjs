// Deterministic pseudo-random helpers for the catalog fixture generator.
//
// Every fixture set is derived only from a seed string plus the requested
// app count: the same seed and count always produce byte-identical output
// (this is exercised directly in test/generate.test.mjs). No system
// randomness (Math.random, crypto.randomBytes) is used anywhere here.

import { createHash } from "node:crypto";

/** Hashes an arbitrary string into a 32-bit unsigned integer, deterministically. */
function hashSeedToUint32(text) {
  const digest = createHash("sha256").update(String(text)).digest();
  return digest.readUInt32BE(0);
}

/**
 * A small, fast, deterministic PRNG (mulberry32). Good enough for picking
 * fixture shapes (names, categories, sizes); never used for anything
 * security-relevant.
 */
export function makeRng(seedText) {
  let state = hashSeedToUint32(seedText) >>> 0;
  return function next() {
    state |= 0;
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Returns a deterministic integer in [min, max] inclusive. */
export function rngInt(rng, min, max) {
  return min + Math.floor(rng() * (max - min + 1));
}

/** Returns a deterministic pick from an array. */
export function rngPick(rng, items) {
  return items[rngInt(rng, 0, items.length - 1)];
}

/** Deterministically shuffles a copy of the array (Fisher-Yates). */
export function rngShuffled(rng, items) {
  const copy = items.slice();
  for (let i = copy.length - 1; i > 0; i -= 1) {
    const j = rngInt(rng, 0, i);
    [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy;
}

/**
 * A deterministic hex token derived from (seed, ...parts), independent of
 * the RNG stream above so adding an unrelated random draw earlier in
 * generation never changes hashes downstream. Used for content hashes,
 * package hashes and icon hashes.
 */
export function deterministicHex(seed, ...parts) {
  return createHash("sha256").update([String(seed), ...parts.map(String)].join(":")).digest("hex");
}

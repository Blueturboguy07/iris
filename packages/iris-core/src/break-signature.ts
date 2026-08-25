/**
 * Groups crash and error reports that are really the same break.
 *
 * Three places need this answer and all three must agree exactly: publik's
 * server (which recomputes it and never trusts a client's clustering), the
 * Windows client, and the macOS client. When the copies disagree, one break
 * becomes several — or several collapse into one — and the pooled recipe that
 * fixes it stops matching the crash it was learned from.
 *
 * It lived in publik's `lib/break-signature.ts`, and `iris-windows` reached
 * across the repository boundary to import it, specifically so the Windows
 * implementation could be held to the real thing rather than to a copy that
 * could quietly drift. Splitting the clients out of publik broke that import
 * and took the check with it. This module is where it belongs instead: one
 * implementation, in the core both clients load.
 *
 * Kept free of `node:crypto` on purpose — see `computeBreakSignature`.
 */

const MAXIMUM_NORMALIZED_LENGTH = 300;

/**
 * Strips the parts of a message that differ between two occurrences of the
 * same bug: addresses, ids, paths, line numbers, timestamps. What survives is
 * the shape of the failure.
 *
 * The order of these replacements is load-bearing. Windows paths are matched
 * before POSIX ones because the POSIX pattern would otherwise eat the tail of
 * `C:\Users\x\y` and leave a stray drive letter behind.
 */
export function normalizeBreakMessage(message: string): string {
  return message
    .toLowerCase()
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g, "<uuid>")
    .replace(/0x[0-9a-f]+/g, "<addr>")
    .replace(/\b[0-9a-f]{7,}\b/g, "<hex>")
    .replace(/[a-z]:\\[^\s"']*/g, "<path>")
    .replace(/(?:\/[^\s"'/]+){2,}\/?/g, "<path>")
    .replace(/\d+/g, "<n>")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, MAXIMUM_NORMALIZED_LENGTH);
}

/**
 * The material a break signature is computed over, in the exact order and
 * separator the hash sees.
 *
 * Hashing is the one thing this module cannot do itself. `node:crypto` does
 * not exist in JavaScriptCore, and `crypto.subtle` is asynchronous, which
 * would make every caller async for one hash. So the core produces the
 * *material* and the host hashes it: Node's `createHash` on Windows,
 * CryptoKit's `SHA256` on macOS. Both are SHA-256 over the same UTF-8 bytes,
 * truncated to the same 32 hex characters, so the identity is identical.
 */
export function breakSignatureMaterial(input: {
  appSlug: string;
  frame?: string | null;
  message: string;
}): string {
  const frame = normalizeBreakMessage(input.frame ?? "");
  const message = normalizeBreakMessage(input.message);
  return `${input.appSlug}|${frame}|${message}`;
}

/** How much of the hex digest a signature keeps. */
export const BREAK_SIGNATURE_HEX_LENGTH = 32;

/**
 * A stable identity for one kind of break in one app, given a host that can
 * hash. `hashHex` must return a lowercase hex SHA-256 digest of the UTF-8
 * bytes of its argument.
 */
export function computeBreakSignature(
  input: { appSlug: string; frame?: string | null; message: string },
  hashHex: (material: string) => string
): string {
  return hashHex(breakSignatureMaterial(input)).slice(0, BREAK_SIGNATURE_HEX_LENGTH);
}

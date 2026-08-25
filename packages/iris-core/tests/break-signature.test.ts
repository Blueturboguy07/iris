/**
 * The conformance suite for break-signature normalization.
 *
 * These cases are the contract. Every client is correct exactly insofar as it
 * produces these answers, and because all of them now run this one module,
 * they cannot disagree by construction — which is the whole point of moving it
 * here. Before the split, `iris-windows` asserted parity by importing publik's
 * copy across the repository boundary; the split broke that import and the
 * Windows typecheck with it.
 */

import { describe, expect, it } from "vitest";
import {
  BREAK_SIGNATURE_HEX_LENGTH,
  breakSignatureMaterial,
  computeBreakSignature,
  normalizeBreakMessage,
} from "../src/break-signature";

describe("normalizeBreakMessage", () => {
  it("erases the things that differ between two occurrences of one bug", () => {
    expect(normalizeBreakMessage("Crash at 0xDEADBEEF in frame 42")).toBe(
      "crash at <addr> in frame <n>"
    );
    expect(
      normalizeBreakMessage("session 3B87BBDA-920D-4358-BB1B-FF1D0EB16612 failed")
    ).toBe("session <uuid> failed");
    expect(normalizeBreakMessage("build a1b2c3d4e5f6789 broke")).toBe("build <hex> broke");
  });

  it("takes a Windows path whole, drive letter included", () => {
    // The POSIX pattern would otherwise eat the tail and leave "c:" behind,
    // which is why the Windows replacement runs first.
    expect(normalizeBreakMessage(String.raw`failed to open C:\Users\mann\app.log`)).toBe(
      "failed to open <path>"
    );
    expect(normalizeBreakMessage(String.raw`C:\a\b and /usr/local/bin/thing`)).toBe(
      "<path> and <path>"
    );
  });

  it("takes a POSIX path only when it has real depth", () => {
    expect(normalizeBreakMessage("open /usr/local/lib/libfoo.dylib")).toBe("open <path>");
    // A single segment is a word, not a path — "/tmp" must survive as itself.
    expect(normalizeBreakMessage("wrote /tmp")).toBe("wrote /tmp");
  });

  it("collapses whitespace and trims", () => {
    expect(normalizeBreakMessage("  a \n\t b  ")).toBe("a b");
  });

  it("caps the length so one enormous message cannot dominate a signature", () => {
    expect(normalizeBreakMessage("x".repeat(1000))).toHaveLength(300);
  });

  it("is idempotent — normalizing twice changes nothing", () => {
    const once = normalizeBreakMessage("Crash at 0xFF in C:\\a\\b at line 9");
    expect(normalizeBreakMessage(once)).toBe(once);
  });

  it("gives two occurrences of one bug the same shape", () => {
    const first = "Fatal at 0x1A2B in /Users/ana/app/main.swift line 42 (id 7f3a9c1)";
    const second = "Fatal at 0x99FF in /Users/ben/app/main.swift line 118 (id 2b8e4d0)";
    expect(normalizeBreakMessage(first)).toBe(normalizeBreakMessage(second));
  });

  it("keeps genuinely different failures apart", () => {
    expect(normalizeBreakMessage("index out of range")).not.toBe(
      normalizeBreakMessage("unexpectedly found nil")
    );
  });
});

describe("breakSignatureMaterial", () => {
  it("orders the fields the way the hash sees them", () => {
    expect(
      breakSignatureMaterial({ appSlug: "cue", frame: "main", message: "boom at 0x1" })
    ).toBe("cue|main|boom at <addr>");
  });

  it("treats a missing frame as empty rather than as the string 'null'", () => {
    expect(breakSignatureMaterial({ appSlug: "cue", message: "boom" })).toBe("cue||boom");
    expect(breakSignatureMaterial({ appSlug: "cue", frame: null, message: "boom" })).toBe(
      "cue||boom"
    );
  });

  it("normalizes the frame too, so an address in it cannot split a break", () => {
    const a = breakSignatureMaterial({ appSlug: "cue", frame: "f 0xAA", message: "m" });
    const b = breakSignatureMaterial({ appSlug: "cue", frame: "f 0xBB", message: "m" });
    expect(a).toBe(b);
  });

  it("keeps two apps apart even when they break identically", () => {
    expect(breakSignatureMaterial({ appSlug: "cue", message: "m" })).not.toBe(
      breakSignatureMaterial({ appSlug: "lunara", message: "m" })
    );
  });
});

describe("computeBreakSignature", () => {
  // A stand-in for the host's hasher. The real ones are node:crypto on Windows
  // and CryptoKit on macOS; what this proves is the truncation and the
  // material, which are the parts the core owns.
  const fakeHash = (material: string) =>
    Array.from(material)
      .reduce((accumulator, character) => (accumulator * 31 + character.charCodeAt(0)) >>> 0, 7)
      .toString(16)
      .padStart(64, "0");

  it("truncates to the shared length", () => {
    const signature = computeBreakSignature({ appSlug: "cue", message: "boom" }, fakeHash);
    expect(signature).toHaveLength(BREAK_SIGNATURE_HEX_LENGTH);
  });

  it("hashes the material, not the raw input", () => {
    let seen = "";
    computeBreakSignature({ appSlug: "cue", message: "boom at 0x1" }, (material) => {
      seen = material;
      return "0".repeat(64);
    });
    expect(seen).toBe("cue||boom at <addr>");
  });
});

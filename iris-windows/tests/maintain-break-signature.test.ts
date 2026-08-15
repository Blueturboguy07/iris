import { describe, expect, it } from "vitest";

import {
  WINDOWS_SIGNATURE_ALGO_VERSION,
  electronRendererGoneSignature,
  hangSignature,
  launchFailureSignature,
  nativeCrashSignature,
  normalizeMessage,
  normalizeSymbol,
  outOfMemorySignature,
  parseWerReportForSignature,
  rustPanicSignature,
  truncatedSha256,
  type BreakAppStack,
  type BreakSignature,
  type ParsedWindowsCrash,
} from "../src/services/maintain/break-signature";
// The real web-side normalizer — decision #0.4 in the porting spec.
// `services/maintain/break-signature.ts`'s `normalizeMessage` is a duplicated,
// self-contained port of this exact function; this import exists ONLY so the
// two can be asserted byte-identical below, never as a runtime dependency of
// the production module itself.
import { normalizeBreakMessage } from "../../lib/break-signature";
import { buildWerReportFixtureText } from "./fixtures/wer-report-fixture";

const SIGNATURE_ID_PATTERN = /^[0-9a-f]{32}$/;

/** Every signature-producing function must carry Windows' own algo version
 *  and a well-formed 32-hex-char id — asserted once, reused everywhere. */
function expectWellFormedSignature(signature: BreakSignature): void {
  expect(signature.algoVersion).toBe(WINDOWS_SIGNATURE_ALGO_VERSION);
  expect(signature.signatureId).toMatch(SIGNATURE_ID_PATTERN);
}

describe("WINDOWS_SIGNATURE_ALGO_VERSION", () => {
  it("starts its own counter at 1, independent of Swift's", () => {
    // Not "the same value as Swift's signatureAlgoVersion" — that would be
    // asserting a coincidence, not the decision. This just pins Windows' own
    // counter so a future bump is intentional and visible in a diff.
    expect(WINDOWS_SIGNATURE_ALGO_VERSION).toBe(1);
  });
});

describe("normalizeSymbol", () => {
  it("replaces a hex address with <x>", () => {
    expect(normalizeSymbol("MyApp!DoWork+0x1a2b")).toBe("MyApp!DoWork+<x>");
  });

  it("replaces a trailing ' + <offset>' with <x>, consuming the separator too", () => {
    // The pattern is `\+ [0-9]+$`, so the "+ " is part of the match, not just
    // the digits — the space before "<x>" is what is left over from
    // "DoWork ", not from the replacement.
    expect(normalizeSymbol("MyApp!DoWork + 42")).toBe("MyApp!DoWork <x>");
  });

  it("replaces a Rust v0 generic hash — including its leading '::' — with <x>", () => {
    expect(normalizeSymbol("core::panicking::panic::hb3d2f1a9c8e7d6f5")).toBe("core::panicking::panic<x>");
  });

  it("replaces mangling residue ($ + 8-or-more pure hex digits) with <x>", () => {
    expect(normalizeSymbol("_ZN4core9panicking5panic$1234abcd12")).toBe("_ZN4core9panicking5panic<x>");
  });

  it("leaves '$' + a residue shorter than 8 hex digits untouched", () => {
    // Exercises the `{8,}` lower bound: this string has a non-hex character
    // ('h' is outside 0-9a-f) three characters into the run, so nothing here
    // ever reaches 8 consecutive hex digits after the '$'.
    expect(normalizeSymbol("_ZN4core9panicking5panic$17h1234abcd")).toBe(
      "_ZN4core9panicking5panic$17h1234abcd"
    );
  });

  it("preserves closure nesting and argument labels — those distinguish real call sites", () => {
    expect(normalizeSymbol("closure #1 in MyApp.doWork(withValue:)")).toBe(
      "closure #1 in MyApp.doWork(withValue:)"
    );
  });

  it("trims surrounding whitespace", () => {
    expect(normalizeSymbol("  MyApp!DoWork  ")).toBe("MyApp!DoWork");
  });
});

describe("normalizeMessage", () => {
  it("lowercases the message", () => {
    expect(normalizeMessage("Access Violation")).toBe("access violation");
  });

  it("replaces a UUID with <uuid>", () => {
    expect(normalizeMessage("session 3f2a9c1e-8b4d-4e6a-9c2f-1a2b3c4d5e6f failed")).toBe(
      "session <uuid> failed"
    );
  });

  it("replaces a 0x-prefixed address with <addr>", () => {
    expect(normalizeMessage("fault at 0xdeadbeef")).toBe("fault at <addr>");
  });

  it("replaces a bare long hex run with <hex>", () => {
    expect(normalizeMessage("handle abcdef1234567 leaked")).toBe("handle <hex> leaked");
  });

  it("replaces a Windows path with <path>, before the POSIX pattern can eat its tail", () => {
    expect(normalizeMessage(String.raw`could not read C:\Users\alice\AppData\Local\cue\config.json`)).toBe(
      "could not read <path>"
    );
  });

  it("replaces a POSIX-shaped path with <path>", () => {
    expect(normalizeMessage("could not read /home/alice/.config/cue/config.json")).toBe("could not read <path>");
  });

  it("replaces bare numbers with <n>", () => {
    expect(normalizeMessage("retry attempt 3 of 5")).toBe("retry attempt <n> of <n>");
  });

  it("collapses whitespace runs to one space", () => {
    expect(normalizeMessage("too   many\n\nspaces")).toBe("too many spaces");
  });

  it("truncates to 300 characters", () => {
    const longMessage = "failure ".repeat(100);
    const normalized = normalizeMessage(longMessage);
    expect(normalized.length).toBeLessThanOrEqual(300);
  });
});

describe("normalizeMessage parity with lib/break-signature.ts (decision #0.4)", () => {
  // The whole reason `normalizeMessage` is duplicated rather than imported:
  // Windows and web must bucket the same message identically. This vector
  // table is what makes that a tested guarantee instead of a hope — any edit
  // to either normalizer that breaks parity fails right here.
  const vectors: readonly string[] = [
    "Access Violation",
    "session 3f2a9c1e-8b4d-4e6a-9c2f-1a2b3c4d5e6f failed at 0xdeadbeef",
    String.raw`could not read C:\Users\alice\AppData\Local\cue\config.json`,
    "could not read /home/alice/.config/cue/config.json",
    "retry attempt 3 of 5, waited 120000ms",
    "  too   many\n\nspaces  and\tTABS  ",
    "handle abcdef1234567 leaked near module deadbeef00",
    "",
    "no volatile parts here at all",
    "failure ".repeat(100),
  ];

  it.each(vectors)("normalizes %j identically on both sides", (message) => {
    expect(normalizeMessage(message)).toBe(normalizeBreakMessage(message));
  });
});

describe("parseWerReportForSignature", () => {
  it("reads the Sig[N] identity fields out of a realistic Report.wer fixture", () => {
    const parsed = parseWerReportForSignature(buildWerReportFixtureText());
    expect(parsed).toEqual<ParsedWindowsCrash>({
      appName: "cue.exe",
      appPath: "C:\\Program Files\\cue\\cue.exe",
      appVersion: "1.4.2.0",
      exceptionCode: "c0000005",
      faultingModuleName: "KERNELBASE.dll",
      faultingModuleVersion: "10.0.19041.3636",
      faultingOffset: "0001a2b3",
      reportId: "3f2a9c1e-8b4d-4e6a-9c2f-1a2b3c4d5e6f",
    });
  });

  it("normalizes a 0x-prefixed, mixed-case exception code and offset", () => {
    const parsed = parseWerReportForSignature(
      buildWerReportFixtureText({ exceptionCode: "0xC0000005", exceptionOffset: "0X1A2B3C" })
    );
    expect(parsed.exceptionCode).toBe("c0000005");
    expect(parsed.faultingOffset).toBe("1a2b3c");
  });

  it("never reads past the first bracketed section header", () => {
    // The fixture's [dynamic data] section deliberately contains a poisoned
    // "Sig[6].Value=00000000-poison" line. If the parser kept reading after
    // the section header, exceptionCode would come back "00000000-poison"
    // instead of the real value from above the section — this is the
    // regression test for that.
    const parsed = parseWerReportForSignature(buildWerReportFixtureText());
    expect(parsed.exceptionCode).toBe("c0000005");
  });

  it("leaves a field undefined when its Sig[N] pair is absent from the report", () => {
    const textWithoutOffset = buildWerReportFixtureText()
      .split("\r\n")
      .filter((line) => !line.startsWith("Sig[7]"))
      .join("\r\n");
    const parsed = parseWerReportForSignature(textWithoutOffset);
    expect(parsed.faultingOffset).toBeUndefined();
    // Everything else in the same report is still read normally.
    expect(parsed.faultingModuleName).toBe("KERNELBASE.dll");
  });

  it("falls back to a placeholder app name for text with no recognizable fields", () => {
    const parsed = parseWerReportForSignature("this is not a WER report at all\njust some text");
    expect(parsed.appName).toBe("unknown.exe");
    expect(parsed.exceptionCode).toBeUndefined();
    expect(parsed.faultingModuleName).toBeUndefined();
  });

  it("handles an empty string without throwing", () => {
    expect(() => parseWerReportForSignature("")).not.toThrow();
    expect(parseWerReportForSignature("").appName).toBe("unknown.exe");
  });
});

describe("nativeCrashSignature", () => {
  const appStack: BreakAppStack = "electron";

  it("is deterministic for the same parsed crash", () => {
    const parsed = parseWerReportForSignature(buildWerReportFixtureText());
    const first = nativeCrashSignature(parsed, "cue", appStack);
    const second = nativeCrashSignature(parsed, "cue", appStack);
    expect(first.signatureId).toBe(second.signatureId);
  });

  it("is well-formed", () => {
    const parsed = parseWerReportForSignature(buildWerReportFixtureText());
    expectWellFormedSignature(nativeCrashSignature(parsed, "cue", appStack));
  });

  it("carries kind native-crash and exactly one synthetic frame with sourceFile null", () => {
    const parsed = parseWerReportForSignature(buildWerReportFixtureText());
    const signature = nativeCrashSignature(parsed, "cue", appStack);
    expect(signature.kind).toBe("native-crash");
    expect(signature.topFrames).toHaveLength(1);
    expect(signature.topFrames[0]?.sourceFile).toBeNull();
  });

  it("marks the frame as an application frame only when the fault module is the app's own exe", () => {
    // Fault module is KERNELBASE.dll, a system DLL — not cue.exe.
    const systemFaultParsed = parseWerReportForSignature(buildWerReportFixtureText());
    expect(nativeCrashSignature(systemFaultParsed, "cue", appStack).topFrames[0]?.isApplicationFrame).toBe(false);

    // Fault module matches the app's own reported name.
    const ownModuleParsed = parseWerReportForSignature(
      buildWerReportFixtureText({ faultModuleName: "cue.exe" })
    );
    expect(nativeCrashSignature(ownModuleParsed, "cue", appStack).topFrames[0]?.isApplicationFrame).toBe(true);
  });

  it("sets fingerprintLoose to the module name alone", () => {
    const parsed = parseWerReportForSignature(buildWerReportFixtureText());
    const signature = nativeCrashSignature(parsed, "cue", appStack);
    expect(signature.fingerprintLoose).toBe("KERNELBASE.dll");
  });

  it("builds the composite as appSlug|appStack|exceptionCode|module!offset:<offset>", () => {
    const parsed = parseWerReportForSignature(buildWerReportFixtureText());
    const signature = nativeCrashSignature(parsed, "cue", appStack);
    expect(signature.protoSignature).toBe("cue|electron|c0000005|KERNELBASE.dll!offset:0001a2b3");
  });

  it("buckets a different exception code separately", () => {
    const parsedA = parseWerReportForSignature(buildWerReportFixtureText({ exceptionCode: "c0000005" }));
    const parsedB = parseWerReportForSignature(buildWerReportFixtureText({ exceptionCode: "c0000094" }));
    const signatureA = nativeCrashSignature(parsedA, "cue", appStack);
    const signatureB = nativeCrashSignature(parsedB, "cue", appStack);
    expect(signatureA.signatureId).not.toBe(signatureB.signatureId);
  });

  it("falls back to UNKNOWN_EXCEPTION when the report carries no exception code", () => {
    const parsed: ParsedWindowsCrash = { appName: "cue.exe" };
    const signature = nativeCrashSignature(parsed, "cue", appStack);
    expect(signature.protoSignature).toContain("UNKNOWN_EXCEPTION");
    expectWellFormedSignature(signature);
  });

  it("still produces a well-formed signature from a maximally degenerate report", () => {
    const parsed: ParsedWindowsCrash = { appName: "unknown.exe" };
    const signature = nativeCrashSignature(parsed, "cue", appStack);
    expectWellFormedSignature(signature);
    expect(signature.topFrames).toHaveLength(1);
    expect(signature.fingerprintLoose).toBe("unknown-module");
  });
});

describe("hangSignature", () => {
  it("uses main-thread when no blocked frame is known", () => {
    const signature = hangSignature("cue", "electron", null);
    expect(signature.fingerprintLoose).toBe("main-thread");
    expectWellFormedSignature(signature);
  });

  it("normalizes the blocked frame through normalizeSymbol", () => {
    const signature = hangSignature("cue", "electron", "MainWindow::onPaint + 0x18");
    expect(signature.fingerprintLoose).toBe("MainWindow::onPaint + <x>");
  });

  it("is deterministic and kind hang", () => {
    const first = hangSignature("cue", "tauri", "renderLoop");
    const second = hangSignature("cue", "tauri", "renderLoop");
    expect(first.signatureId).toBe(second.signatureId);
    expect(first.kind).toBe("hang");
  });
});

describe("rustPanicSignature", () => {
  it("parses the old-style panic message and location", () => {
    // Rust panic locations from the `file!()` macro are always forward-slash,
    // even in a build produced on Windows — Cargo embeds the crate-relative
    // path, not an OS path — so the location regex (ported verbatim from
    // Swift's `[\w./-]+`, which does not include a backslash) never needs to
    // handle one here.
    const stderr = "thread 'main' panicked at 'index out of bounds', src/main.rs:42:5";
    const signature = rustPanicSignature("openascii", "tauri", stderr);
    expect(signature.fingerprintLoose).toBe("index out of bounds");
    expect(signature.protoSignature).toContain("src/main.rs");
  });

  it("parses the new-style panic message and location", () => {
    const stderr = "thread 'main' panicked at src/lib.rs:10:1:\nsomething broke here";
    const signature = rustPanicSignature("openascii", "tauri", stderr);
    expect(signature.fingerprintLoose).toBe("something broke here");
    expect(signature.protoSignature).toContain("src/lib.rs");
  });

  it("falls back to unknown.rs when no rust location is present", () => {
    const signature = rustPanicSignature("openascii", "tauri", "totally unstructured crash text");
    expect(signature.protoSignature).toContain("unknown.rs");
    expectWellFormedSignature(signature);
  });

  it("is kind rust-panic and well-formed", () => {
    const signature = rustPanicSignature("openascii", "tauri", "panicked at 'oops', src/f.rs:1:2");
    expect(signature.kind).toBe("rust-panic");
    expectWellFormedSignature(signature);
  });
});

describe("electronRendererGoneSignature", () => {
  it.each(["crashed", "oom", "killed", "launch-failed"] as const)(
    "produces a well-formed signature for reason %s",
    (reason) => {
      const signature = electronRendererGoneSignature("cue", reason);
      expect(signature.kind).toBe("js-exception");
      expect(signature.appStack).toBe("electron");
      expectWellFormedSignature(signature);
      expect(signature.fingerprintStrict).toBe(signature.fingerprintLoose);
    }
  );

  it("distinguishes different renderer-gone reasons", () => {
    const crashed = electronRendererGoneSignature("cue", "crashed");
    const oom = electronRendererGoneSignature("cue", "oom");
    expect(crashed.signatureId).not.toBe(oom.signatureId);
  });
});

describe("outOfMemorySignature", () => {
  it("has no stack and a constant oom fingerprint", () => {
    const signature = outOfMemorySignature("cue", "electron");
    expect(signature.topFrames).toHaveLength(0);
    expect(signature.fingerprintStrict).toBe("oom");
    expect(signature.fingerprintLoose).toBe("oom");
    expect(signature.kind).toBe("oom");
    expectWellFormedSignature(signature);
  });

  it("distinguishes app stacks, since the composite includes it", () => {
    const electron = outOfMemorySignature("cue", "electron");
    const tauri = outOfMemorySignature("cue", "tauri");
    expect(electron.signatureId).not.toBe(tauri.signatureId);
  });
});

describe("launchFailureSignature", () => {
  it("normalizes the reason and keeps the daemon out of fingerprintLoose", () => {
    const signature = launchFailureSignature(
      "cue",
      "electron",
      "cue.exe",
      String.raw`could not start: C:\Users\alice\AppData\Local\cue\cue.exe missing`
    );
    expect(signature.fingerprintLoose).toBe("launch|cue.exe");
    expect(signature.fingerprintStrict).toBe("launch|cue.exe|could not start: <path> missing");
  });

  it("is kind launch-failure and well-formed", () => {
    const signature = launchFailureSignature("cue", "electron", "cue.exe", "exit code 1");
    expect(signature.kind).toBe("launch-failure");
    expectWellFormedSignature(signature);
  });
});

describe("BreakAppStack keeps swift-macos in its union (decision #0.2)", () => {
  it("accepts swift-macos as shared wire vocabulary, even though Windows never emits it", () => {
    const signature = outOfMemorySignature("cue", "swift-macos");
    expect(signature.appStack).toBe("swift-macos");
    expectWellFormedSignature(signature);
  });
});

describe("truncatedSha256", () => {
  it("returns 32 lowercase hex characters", () => {
    expect(truncatedSha256("anything")).toMatch(SIGNATURE_ID_PATTERN);
  });

  it("is deterministic", () => {
    expect(truncatedSha256("same input")).toBe(truncatedSha256("same input"));
  });

  it("differs for different composites", () => {
    expect(truncatedSha256("composite a")).not.toBe(truncatedSha256("composite b"));
  });
});

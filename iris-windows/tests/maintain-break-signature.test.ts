import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
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
  WINDOWS_SIGNATURE_ALGO_VERSION,
  type BreakAppStack,
} from "../src/services/maintain/break-signature";
// The one file in this suite allowed to import outside `iris-windows/` — see
// the porting spec §0/§3 and `tsconfig.json`'s `rootDir: ".."`, changed
// specifically to permit this line. It proves `normalizeMessage` above stays
// byte-identical to the web repo's real `normalizeBreakMessage`, not to a
// copy of it that could quietly drift.
import { normalizeBreakMessage } from "../../lib/break-signature";
import {
  buildAppCrashWerText,
  CUE_APPCRASH_WER_FIXTURE,
  CUE_APPCRASH_WER_FIXTURE_FOREIGN_MODULE,
  CUE_APPCRASH_WER_FIXTURE_HEX_PREFIXED,
  EMPTY_WER_FIXTURE,
  MINIMAL_WER_FIXTURE_WITH_FLAT_APPNAME_ONLY,
  REORDERED_SIG_FIELDS_WER_FIXTURE,
} from "./fixtures/wer-signature-fixture";

const TAURI: BreakAppStack = "tauri";
const ELECTRON: BreakAppStack = "electron";

describe("normalizeSymbol", () => {
  it("replaces a hex address with the placeholder", () => {
    expect(normalizeSymbol("cue::render_frame + 0x1a2b3c")).toBe("cue::render_frame + <x>");
  });

  it("replaces a trailing offset", () => {
    expect(normalizeSymbol("cue::render_frame + 42")).toBe("cue::render_frame <x>");
  });

  it("replaces a Rust v0/legacy generic-instantiation hash, consuming the leading '::'", () => {
    expect(normalizeSymbol("cue::render::h9f8e7d6c5b4a3210")).toBe("cue::render<x>");
  });

  it("replaces mangling residue", () => {
    expect(normalizeSymbol("_ZN3cue6render$abcdef1234E")).toBe("_ZN3cue6render<x>E");
  });

  it("trims surrounding whitespace but does not touch closure nesting or argument labels", () => {
    // Deliberately NOT stripped: closure nesting and argument labels — see
    // the function's own doc comment for why they distinguish genuinely
    // different call sites.
    expect(normalizeSymbol("  cue::save(path:) closure #1  ")).toBe("cue::save(path:) closure #1");
  });

  it("leaves a plain symbol with no volatile parts untouched", () => {
    expect(normalizeSymbol("cue::main")).toBe("cue::main");
  });
});

describe("normalizeMessage", () => {
  it("lowercases", () => {
    expect(normalizeMessage("Access Violation")).toBe("access violation");
  });

  it("replaces a uuid", () => {
    expect(normalizeMessage("session a1b2c3d4-e5f6-7890-abcd-ef1234567890 failed")).toBe(
      "session <uuid> failed",
    );
  });

  it("replaces a 0x-prefixed address", () => {
    expect(normalizeMessage("fault at 0x00007ff6a1b2c3d4")).toBe("fault at <addr>");
  });

  it("replaces a bare hex run of 7+ characters", () => {
    expect(normalizeMessage("thread id abcdef1")).toBe("thread id <hex>");
  });

  it("replaces a Windows path before it can fall into the posix path pattern", () => {
    expect(normalizeMessage(String.raw`failed to write C:\Users\alice\AppData\Local\cue\log.txt`)).toBe(
      "failed to write <path>",
    );
  });

  it("replaces a posix-shaped path", () => {
    expect(normalizeMessage("failed to read /home/alice/.config/cue/settings.json")).toBe(
      "failed to read <path>",
    );
  });

  it("replaces bare numbers", () => {
    expect(normalizeMessage("retry 3 of 5 after 1200ms")).toBe("retry <n> of <n> after <n>ms");
  });

  it("collapses whitespace runs and trims", () => {
    expect(normalizeMessage("  too    many     spaces  ")).toBe("too many spaces");
  });

  it("caps normalized output at 300 characters", () => {
    const longMessage = "x".repeat(500);
    const normalized = normalizeMessage(longMessage);
    expect(normalized.length).toBe(300);
  });
});

describe("normalizeMessage parity with lib/break-signature.ts's normalizeBreakMessage", () => {
  // The actual cross-client parity requirement (porting spec §3): the pool
  // splits the same break into two buckets if these two normalizers ever
  // disagree, because the web listing pages and the Windows client both
  // compute a signature client-side before ever talking to the server. This
  // table is deliberately not a set of hand-computed expected strings — it
  // asserts the two implementations produce IDENTICAL output on the same
  // input, which is the property that actually matters here.
  const sharedVectorTable: readonly string[] = [
    "",
    "Access Violation",
    "session a1b2c3d4-e5f6-7890-abcd-ef1234567890 failed at 0x00007ff6a1b2c3d4",
    String.raw`failed to write C:\Users\alice\AppData\Local\cue\log.txt`,
    "failed to read /home/alice/.config/cue/settings.json",
    "retry 3 of 5 after 1200ms, thread abcdef1",
    "  too    many     spaces  ",
    "MIXED Case Message With 123 Numbers And UUID a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "x".repeat(500),
    "no volatile parts here at all",
    String.raw`nested C:\Users\bob\proj\src\main.rs panicked, see /var/log/cue/crash-2024.log for 0xdeadbeef`,
  ];

  it.each(sharedVectorTable)("normalizes %j identically on both sides", (rawMessage) => {
    expect(normalizeMessage(rawMessage)).toBe(normalizeBreakMessage(rawMessage));
  });
});

describe("truncatedSha256", () => {
  it("returns 32 lowercase hex characters", () => {
    const hash = truncatedSha256("cue|electron|native-crash|cue.exe!offset:<x>");
    expect(hash).toMatch(/^[0-9a-f]{32}$/);
  });

  it("is deterministic for the same input", () => {
    expect(truncatedSha256("same composite")).toBe(truncatedSha256("same composite"));
  });

  it("differs for a different input", () => {
    expect(truncatedSha256("composite a")).not.toBe(truncatedSha256("composite b"));
  });
});

describe("parseWerReportForSignature", () => {
  it("reads every Sig[] identity field out of a fully-populated report", () => {
    const parsed = parseWerReportForSignature(CUE_APPCRASH_WER_FIXTURE);
    expect(parsed.appName).toBe("cue.exe");
    expect(parsed.appVersion).toBe("0.2.3.0");
    expect(parsed.faultingModuleName).toBe("cue.exe");
    expect(parsed.faultingModuleVersion).toBe("0.2.3.0");
    expect(parsed.exceptionCode).toBe("c0000005");
    expect(parsed.faultingOffset).toBe("0000000000012345");
    expect(parsed.reportId).toBe("a1b2c3d4-1234-5678-9abc-def012345678");
    expect(parsed.appPath).toBe("C:\\Users\\test\\AppData\\Local\\Programs\\cue\\cue.exe");
  });

  it("stops reading at the first bracketed section header", () => {
    // The fixture appends a fake Sig[99] pair after `[dynamic data]` whose
    // values would fail every other assertion in this describe block if the
    // parser kept reading past the section header.
    const parsed = parseWerReportForSignature(CUE_APPCRASH_WER_FIXTURE);
    expect(parsed.faultingModuleName).not.toBe("Should Never Be Read");
  });

  it("normalizes an upper-case 0x-prefixed hex field to the same value as the unprefixed lower-case spelling", () => {
    const prefixed = parseWerReportForSignature(CUE_APPCRASH_WER_FIXTURE_HEX_PREFIXED);
    const unprefixed = parseWerReportForSignature(CUE_APPCRASH_WER_FIXTURE);
    expect(prefixed.exceptionCode).toBe(unprefixed.exceptionCode);
    expect(prefixed.faultingOffset).toBe(unprefixed.faultingOffset);
    expect(prefixed.exceptionCode).toBe("c0000005");
  });

  it("collects a Sig[N] pair regardless of whether Value or Name arrives first", () => {
    const parsed = parseWerReportForSignature(REORDERED_SIG_FIELDS_WER_FIXTURE);
    expect(parsed.appName).toBe("cue.exe");
    expect(parsed.exceptionCode).toBe("c0000005");
  });

  it("falls back to the flat AppName field when the Sig[] block is entirely absent", () => {
    const parsed = parseWerReportForSignature(MINIMAL_WER_FIXTURE_WITH_FLAT_APPNAME_ONLY);
    expect(parsed.appName).toBe("fallback-app.exe");
    expect(parsed.faultingModuleName).toBeUndefined();
    expect(parsed.exceptionCode).toBeUndefined();
  });

  it("falls back to unknown.exe and undefined fields when nothing at all is present", () => {
    const parsed = parseWerReportForSignature(EMPTY_WER_FIXTURE);
    expect(parsed.appName).toBe("unknown.exe");
    expect(parsed.appVersion).toBeUndefined();
    expect(parsed.faultingModuleName).toBeUndefined();
    expect(parsed.exceptionCode).toBeUndefined();
    expect(parsed.reportId).toBeUndefined();
  });

  it("ignores a blank line and a malformed line with no '=' separator", () => {
    const text = ["Version=1", "", "this line has no separator", "Sig[0].Name=Application Name", "Sig[0].Value=cue.exe"].join(
      "\r\n",
    );
    const parsed = parseWerReportForSignature(text);
    expect(parsed.appName).toBe("cue.exe");
  });

  it("round-trips through buildAppCrashWerText for an app whose name has no matching fault module", () => {
    const text = buildAppCrashWerText({ applicationName: "other.exe", faultModuleName: "ntdll.dll" });
    const parsed = parseWerReportForSignature(text);
    expect(parsed.appName).toBe("other.exe");
    expect(parsed.faultingModuleName).toBe("ntdll.dll");
  });
});

describe("nativeCrashSignature", () => {
  it("builds exactly one synthetic frame from the fault module and offset", () => {
    const parsed = parseWerReportForSignature(CUE_APPCRASH_WER_FIXTURE);
    const signature = nativeCrashSignature(parsed, "cue", ELECTRON);
    expect(signature.kind).toBe("native-crash");
    expect(signature.algoVersion).toBe(WINDOWS_SIGNATURE_ALGO_VERSION);
    expect(signature.appSlug).toBe("cue");
    expect(signature.appStack).toBe(ELECTRON);
    expect(signature.topFrames).toHaveLength(1);
    expect(signature.topFrames[0]?.module).toBe("cue.exe");
    expect(signature.topFrames[0]?.sourceFile).toBeNull();
    expect(signature.topFrames[0]?.function).toContain("offset:");
  });

  it("marks the frame as an application frame when the fault module matches the app name", () => {
    const parsed = parseWerReportForSignature(CUE_APPCRASH_WER_FIXTURE);
    const signature = nativeCrashSignature(parsed, "cue", ELECTRON);
    expect(signature.topFrames[0]?.isApplicationFrame).toBe(true);
  });

  it("marks the frame as NOT an application frame when the crash is inside a system module", () => {
    const parsed = parseWerReportForSignature(CUE_APPCRASH_WER_FIXTURE_FOREIGN_MODULE);
    const signature = nativeCrashSignature(parsed, "cue", ELECTRON);
    expect(signature.topFrames[0]?.isApplicationFrame).toBe(false);
    expect(signature.topFrames[0]?.module).toBe("KERNELBASE.dll");
  });

  it("falls back to UNKNOWN_EXCEPTION and unknown-module when the report has neither", () => {
    const parsed = parseWerReportForSignature(EMPTY_WER_FIXTURE);
    const signature = nativeCrashSignature(parsed, "cue", ELECTRON);
    expect(signature.protoSignature).toContain("UNKNOWN_EXCEPTION");
    expect(signature.topFrames[0]?.module).toBe("unknown-module");
    expect(signature.fingerprintLoose).toBe("unknown-module");
  });

  it("is deterministic: the same crash on the same app produces the same signatureId", () => {
    const parsed = parseWerReportForSignature(CUE_APPCRASH_WER_FIXTURE);
    const first = nativeCrashSignature(parsed, "cue", ELECTRON);
    const second = nativeCrashSignature(parsed, "cue", ELECTRON);
    expect(first.signatureId).toBe(second.signatureId);
    expect(first.fingerprintStrict).toBe(second.fingerprintStrict);
  });

  it("gives the hex-prefixed and unprefixed fixtures the same signatureId, since normalizeHexField equalizes them", () => {
    const prefixed = nativeCrashSignature(parseWerReportForSignature(CUE_APPCRASH_WER_FIXTURE_HEX_PREFIXED), "cue", ELECTRON);
    // Build a comparable unprefixed report with the same app/module/offset as
    // the hex-prefixed fixture (CUE_APPCRASH_WER_FIXTURE has an extra
    // Application Version field the hex-prefixed one omits, which would
    // otherwise make this comparison compare two different reports).
    const unprefixedEquivalent = nativeCrashSignature(
      parseWerReportForSignature(
        buildAppCrashWerText({
          applicationName: "cue.exe",
          faultModuleName: "cue.exe",
          exceptionCode: "c0000005",
          exceptionOffset: "0000000000012345",
          reportIdentifier: "a1b2c3d4-1234-5678-9abc-def012345678",
        }),
      ),
      "cue",
      ELECTRON,
    );
    expect(prefixed.signatureId).toBe(unprefixedEquivalent.signatureId);
  });

  it("gives two different apps different signatures for the identical crash shape", () => {
    const parsed = parseWerReportForSignature(CUE_APPCRASH_WER_FIXTURE);
    const cueSignature = nativeCrashSignature(parsed, "cue", ELECTRON);
    const otherAppSignature = nativeCrashSignature(parsed, "some-other-app", ELECTRON);
    expect(cueSignature.signatureId).not.toBe(otherAppSignature.signatureId);
  });

  it("uses the fault module name alone as fingerprintLoose, the honest Windows analog of function-only", () => {
    const parsed = parseWerReportForSignature(CUE_APPCRASH_WER_FIXTURE_FOREIGN_MODULE);
    const signature = nativeCrashSignature(parsed, "cue", ELECTRON);
    expect(signature.fingerprintLoose).toBe("KERNELBASE.dll");
  });
});

describe("hangSignature", () => {
  it("uses main-thread as the frame when no blocked frame is known", () => {
    const signature = hangSignature("cue", ELECTRON, null);
    expect(signature.kind).toBe("hang");
    expect(signature.fingerprintLoose).toBe("main-thread");
    expect(signature.topFrames).toEqual([]);
  });

  it("normalizes a known blocked frame through normalizeSymbol", () => {
    const signature = hangSignature("cue", ELECTRON, "cue::wait_for(ms: 0x1a2b3c)");
    expect(signature.fingerprintLoose).toBe("cue::wait_for(ms: <x>)");
  });

  it("differs from a native-crash signature for the same app, since kind rides in the composite", () => {
    const parsed = parseWerReportForSignature(CUE_APPCRASH_WER_FIXTURE);
    const crashSignature = nativeCrashSignature(parsed, "cue", ELECTRON);
    const hangSig = hangSignature("cue", ELECTRON, null);
    expect(hangSig.signatureId).not.toBe(crashSignature.signatureId);
  });
});

describe("rustPanicSignature", () => {
  it("parses the old-style panic format (quoted message, trailing location)", () => {
    const stderr = "thread 'main' panicked at 'index out of bounds: the len is 3 but the index is 5', src/main.rs:42:9";
    const signature = rustPanicSignature("cue", TAURI, stderr);
    expect(signature.kind).toBe("rust-panic");
    expect(signature.fingerprintStrict).toContain("src/main.rs");
    expect(signature.fingerprintLoose).toBe("index out of bounds: the len is <n> but the index is <n>");
  });

  it("parses the new-style panic format (location first, message on the next line)", () => {
    const stderr = "thread 'main' panicked at src/lib.rs:17:5:\nassertion failed: cache.is_some()";
    const signature = rustPanicSignature("cue", TAURI, stderr);
    expect(signature.fingerprintStrict).toContain("src/lib.rs");
    expect(signature.fingerprintLoose).toBe("assertion failed: cache.is_some()");
  });

  it("falls back to unknown.rs when no file:line location is present", () => {
    const signature = rustPanicSignature("cue", TAURI, "something went very wrong with no location");
    expect(signature.fingerprintStrict).toContain("unknown.rs");
  });

  it("normalizes volatile parts of the panic message", () => {
    const stderr = "panicked at src/db.rs:9:1:\nfailed to open /home/alice/.cue/db-a1b2c3d4-e5f6-7890-abcd-ef1234567890.sqlite";
    const signature = rustPanicSignature("cue", TAURI, stderr);
    expect(signature.fingerprintLoose).toBe("failed to open <path>");
  });
});

describe("electronRendererGoneSignature", () => {
  it("is categorical: no topFrames, and the reason carries the identity", () => {
    const signature = electronRendererGoneSignature("cue", "crashed");
    expect(signature.kind).toBe("js-exception");
    expect(signature.appStack).toBe("electron");
    expect(signature.topFrames).toEqual([]);
    expect(signature.fingerprintLoose).toBe("renderer-gone|crashed");
  });

  it("normalizes the reason like any other message", () => {
    const signature = electronRendererGoneSignature("cue", "OOM after 12345ms");
    expect(signature.fingerprintLoose).toBe("renderer-gone|oom after <n>ms");
  });

  it.each(["crashed", "oom", "killed", "launch-failed"])("distinguishes Chromium's own reason %s from the others", (reason) => {
    const signature = electronRendererGoneSignature("cue", reason);
    const otherReasons = ["crashed", "oom", "killed", "launch-failed"].filter((candidate) => candidate !== reason);
    for (const otherReason of otherReasons) {
      expect(signature.signatureId).not.toBe(electronRendererGoneSignature("cue", otherReason).signatureId);
    }
  });
});

describe("outOfMemorySignature", () => {
  it("has no stack and a fixed categorical identity", () => {
    const signature = outOfMemorySignature("cue", ELECTRON);
    expect(signature.kind).toBe("oom");
    expect(signature.topFrames).toEqual([]);
    expect(signature.fingerprintStrict).toBe("oom");
    expect(signature.fingerprintLoose).toBe("oom");
  });

  it("still distinguishes apps and stacks, since both ride in the composite", () => {
    const cueSignature = outOfMemorySignature("cue", ELECTRON);
    const otherAppSignature = outOfMemorySignature("other-app", ELECTRON);
    const otherStackSignature = outOfMemorySignature("cue", TAURI);
    expect(cueSignature.signatureId).not.toBe(otherAppSignature.signatureId);
    expect(cueSignature.signatureId).not.toBe(otherStackSignature.signatureId);
  });
});

describe("launchFailureSignature", () => {
  it("carries the daemon (exe name) and the normalized reason", () => {
    const signature = launchFailureSignature("cue", ELECTRON, "cue.exe", "spawn ENOENT");
    expect(signature.kind).toBe("launch-failure");
    expect(signature.fingerprintStrict).toBe("launch|cue.exe|spawn enoent");
    expect(signature.fingerprintLoose).toBe("launch|cue.exe");
  });

  it("normalizes the reason the same way every other kind does", () => {
    const signature = launchFailureSignature(
      "cue",
      ELECTRON,
      "cue.exe",
      String.raw`spawn C:\Users\alice\AppData\Local\Programs\cue\cue.exe ENOENT`,
    );
    expect(signature.fingerprintStrict).toBe("launch|cue.exe|spawn <path> enoent");
  });

  it("fingerprintLoose absorbs a changed reason but not a changed daemon", () => {
    const first = launchFailureSignature("cue", ELECTRON, "cue.exe", "spawn ENOENT");
    const second = launchFailureSignature("cue", ELECTRON, "cue.exe", "permission denied");
    expect(first.fingerprintLoose).toBe(second.fingerprintLoose);

    const differentDaemon = launchFailureSignature("cue", ELECTRON, "cue-helper.exe", "spawn ENOENT");
    expect(first.fingerprintLoose).not.toBe(differentDaemon.fingerprintLoose);
  });
});

describe("BreakAppStack wire vocabulary", () => {
  it("keeps swift-macos in the union even though this client never emits it", () => {
    // A compile-time assertion as much as a runtime one: if `BreakAppStack`
    // ever drops this member, this line stops compiling. See the module
    // header for why dropping it would make the type lie about what the
    // server's `signatures.app_stack` check constraint accepts.
    const swiftMacOsStack: BreakAppStack = "swift-macos";
    const signature = outOfMemorySignature("some-app", swiftMacOsStack);
    expect(signature.appStack).toBe("swift-macos");
  });
});

// ---------------------------------------------------------------------------
// DETECTION, against real `Report.wer` files on disk — the Windows analog of
// the Swift maintain-mode test harness's D1–D3
// (`iris-macos/tools/maintain-test-harness/main.swift`, which reads
// `swift-crash-A.ips` / `swift-crash-different-bug.ips` off disk the same
// way). `wer-signature-fixture.ts`'s `buildAppCrashWerText` helper already
// exercises the parser thoroughly with in-memory strings (every field
// individually, malformed lines, reordered Sig[] pairs, …) — this block's
// job is narrower and complementary: prove the parser + signature builder
// behave correctly against REAL FILES read with `node:fs`, exactly the kind
// of artifact `crash-watcher.ts`'s sure path finds on a real machine, and
// walk through the harness's specific dedup/distinguish narrative using
// them.
//
// Fixture files use plain LF line endings (unlike `buildAppCrashWerText`,
// which deliberately renders CRLF — see that file's header). That CRLF
// property is already covered there; duplicating it here would test nothing
// new. `parseWerReportForSignature` splits on `/\r?\n/` and trims each line,
// so either ending parses identically — see its own header comment.
// ---------------------------------------------------------------------------

function readWerFixture(fileName: string): string {
  return readFileSync(join(__dirname, "fixtures", fileName), "utf-8");
}

describe("parseWerReportForSignature / nativeCrashSignature — against real .wer fixture files on disk", () => {
  it("parses a real Report.wer file and builds a correctly-kinded, 32-hex signature", () => {
    const parsed = parseWerReportForSignature(readWerFixture("crash-cue-bug-a.wer"));
    expect(parsed.appName).toBe("cue.exe");
    expect(parsed.faultingModuleName).toBe("cue.exe");
    expect(parsed.exceptionCode).toBe("c0000005");

    const signature = nativeCrashSignature(parsed, "cue", ELECTRON);
    expect(signature.kind).toBe("native-crash");
    expect(signature.signatureId).toMatch(/^[0-9a-f]{32}$/);
    expect(signature.topFrames).toHaveLength(1);
  });

  it(
    "the Windows analog of 'caller, not runtime': the identity names the module that actually " +
      "faulted, and tags whether that module is the app's own code or a system module — there is " +
      "no walked stack to skip past (WER gives one fault point, never a call stack; see the module " +
      "header's 'Windows has no .ips, no ReportCrash, no walked stack')",
    () => {
      const appFrame = nativeCrashSignature(parseWerReportForSignature(readWerFixture("crash-cue-bug-a.wer")), "cue", ELECTRON);
      expect(appFrame.topFrames[0].isApplicationFrame).toBe(true);
      expect(appFrame.topFrames[0].module).toBe("cue.exe");

      const systemModuleFrame = nativeCrashSignature(
        parseWerReportForSignature(readWerFixture("crash-cue-system-module.wer")),
        "cue",
        ELECTRON,
      );
      expect(systemModuleFrame.topFrames[0].isApplicationFrame).toBe(false);
      expect(systemModuleFrame.topFrames[0].module).toBe("ntdll.dll");
      // Both are still real, valid native-crash signatures for the same app —
      // the isApplicationFrame tag is metadata riding along, never a reason
      // to refuse to compute an identity.
      expect(systemModuleFrame.signatureId).toMatch(/^[0-9a-f]{32}$/);
      expect(appFrame.signatureId).not.toBe(systemModuleFrame.signatureId);
    },
  );

  it("dedups: two real captures of the SAME bug (identical module + exception code, different address/report id/timestamp) collapse to the same loose fingerprint and the same signatureId", () => {
    const first = nativeCrashSignature(parseWerReportForSignature(readWerFixture("crash-cue-bug-a.wer")), "cue", ELECTRON);
    const second = nativeCrashSignature(
      parseWerReportForSignature(readWerFixture("crash-cue-bug-a-recurrence.wer")),
      "cue",
      ELECTRON,
    );
    expect(first.fingerprintLoose).toBe(second.fingerprintLoose);
    // Windows has no symbol table on this client (see the module header): a
    // bare offset carries no diagnostic weight, so `normalizeSymbol` collapses
    // it to the same placeholder regardless of its actual value, and two
    // captures of the same underlying bug therefore land on the same
    // signatureId too, not merely the same loose fingerprint. This is the
    // documented, honest coarseness of a client with no walked stack — see
    // "uses the fault module name alone as fingerprintLoose" above.
    expect(first.signatureId).toBe(second.signatureId);
  });

  it("distinguishes a genuinely different real bug (different fault module AND exception code) with both a different signatureId and a different loose fingerprint", () => {
    const bugA = nativeCrashSignature(parseWerReportForSignature(readWerFixture("crash-cue-bug-a.wer")), "cue", ELECTRON);
    const differentBug = nativeCrashSignature(
      parseWerReportForSignature(readWerFixture("crash-cue-different-bug.wer")),
      "cue",
      ELECTRON,
    );
    expect(bugA.signatureId).not.toBe(differentBug.signatureId);
    expect(bugA.fingerprintLoose).not.toBe(differentBug.fingerprintLoose);
    expect(differentBug.topFrames[0].module).toBe("v8jsi.dll");
  });

  it("the same real crash text in a different app never shares a signature (identity always includes appSlug)", () => {
    const parsed = parseWerReportForSignature(readWerFixture("crash-cue-bug-a.wer"));
    const asCue = nativeCrashSignature(parsed, "cue", ELECTRON);
    const asLunara = nativeCrashSignature(parsed, "lunara", ELECTRON);
    expect(asCue.signatureId).not.toBe(asLunara.signatureId);
  });
});

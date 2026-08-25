/**
 * break-signature.ts
 *
 * Turns a Windows failure artifact into the identity maintain mode pools on: a
 * 32-hex signature plus two fingerprint tiers, computed entirely on this
 * machine, before anything is asked of a user, a server, or a model. The TS
 * analog of `BreakSignatureService.swift` (`iris-macos/leanring-buddy/`),
 * ported for BEHAVIOR parity, not literal translation — Windows has no `.ips`,
 * no `ReportCrash`, no walked stack, so the shapes here are the honest Windows
 * equivalents, not a reskin of the macOS ones.
 *
 * ## Two decisions this file assumes (see the porting spec §0)
 *
 * 1. `WINDOWS_SIGNATURE_ALGO_VERSION` is Windows' OWN counter, starting at 1.
 *    It is never compared to Swift's `signatureAlgoVersion` — the two clients'
 *    native-crash identity is fundamentally different (WER gives one fault
 *    point, never a walked stack), so there is nothing to keep in lockstep.
 * 2. `BreakAppStack` keeps `"swift-macos"` in its union even though this
 *    client never emits it. The type is shared wire vocabulary with the
 *    server's `signatures.app_stack` check constraint, not a per-client enum —
 *    dropping it here would make this file lie about what the column accepts.
 *
 * ## Message/symbol normalization
 *
 * `normalizeMessage` is a byte-for-byte port of `normalizeBreakMessage` in
 * `lib/break-signature.ts` (the web repo's shared TS normalizer) — same
 * patterns, same order, same 300-char cap. It is duplicated here on purpose
 * (per the porting spec §0.4 / §3): the shipped app stays self-contained,
 * matching every other file in `services/maintain/` (no module here imports
 * outside this package). The test suite (`tests/maintain-break-signature.test.ts`)
 * imports the real `lib/break-signature.ts` directly and asserts byte-identical
 * output over a shared vector table — THAT is what "reuse it for parity" cashes
 * out to without creating a cross-package runtime dependency. Any change to
 * either normalizer needs the matching change on the other side, or the pool
 * splits the same break into two buckets depending on which client saw it
 * first.
 *
 * `normalizeSymbol` is a straight, unchanged port of the Swift function of the
 * same name — it strips addresses, trailing offsets, and Rust/mangling
 * disambiguators from a symbol-shaped string.
 *
 * ## The Windows crash artifact this file parses
 *
 * A macOS crash report is two concatenated JSON blobs with a walked stack.
 * Windows' analog — a `Report.wer` file, written by Windows Error Reporting to
 * `%ProgramData%\Microsoft\Windows\WER\ReportArchive\<ReportName>\Report.wer`
 * — is a flat `Key=Value` bucket (the classic `AppCrash` shape: `Sig[0].Name=
 * Application Name`, `Sig[0].Value=cue.exe`, `Sig[3].Name=Fault Module Name`,
 * `Sig[6].Name=Exception Code`, …), followed by a `[dynamic data]` section of
 * opaque bucket bytes this file has no use for and does not read.
 *
 * `parseWerReportForSignature` reads only the flat `Key=Value` portion — it
 * stops at the first bracketed section header, which is exactly where the
 * fields this file cares about end. It is a NARROW parser scoped to what
 * `nativeCrashSignature` needs (identity fields only): the porting spec's
 * module list assigns the FULL parser — including the Event ID 1000
 * `EventData` XML variant used by the live crash watcher — to a separate
 * `wer-report.ts` module that is not part of this task. Whoever builds that
 * module can lean on this one's `ParsedWindowsCrash` shape or supersede it;
 * either way, this file stays correct and self-contained on its own.
 *
 * ## Why Windows' native-crash signature has "at most one synthetic frame"
 *
 * This is a deliberate parity BEHAVIOR, not a gap someone should "fix" by
 * inventing a stack Windows does not honestly have. A `.wer` report gives one
 * fault point — a module name and a byte offset into it — never a walked
 * stack of caller frames the way an `.ips` report's `threads[].frames` does.
 * `nativeCrashSignature` below therefore builds exactly one synthetic
 * `BreakSignatureFrame` out of the fault module and offset, with `sourceFile:
 * null` always (there is no source file at all, not even one Windows chooses
 * not to report), and `fingerprintLoose` falls back to the module name alone
 * — the honest Windows analog of "function only" when there is no function
 * to fall back to without a symbol server.
 */

import { createHash } from "node:crypto";
import { normalizeBreakMessage } from "@iris/core";

/** Which family of failure a signature identifies. Wire vocabulary shared
 *  with the server's `signatures.signature_kind` check constraint — keep
 *  these strings byte-identical to Swift's `BreakSignatureKind` raw values. */
export type BreakSignatureKind =
  | "native-crash"
  | "rust-panic"
  | "js-exception"
  | "hang"
  | "oom"
  | "launch-failure"
  | "log-pattern";

/** The stack an app is built on, from the catalog. Wire vocabulary shared
 *  with the server's `signatures.app_stack` check constraint — `"swift-macos"`
 *  stays in the union even though this client never emits it; see the file
 *  header for why dropping it would be a lie about what the column accepts. */
export type BreakAppStack = "tauri" | "electron" | "nextjs" | "swift-macos" | "other";

/** One frame of the faulting "stack" — on Windows, at most one synthetic
 *  frame built from a WER fault point, never a walked stack. See the file
 *  header for why. */
export interface BreakSignatureFrame {
  readonly module: string;
  readonly function: string;
  /** Basename only, never a full path — a full path would embed the OS
   *  account name. Always `null` on Windows: a `.wer` report carries no
   *  source file at all, not even one Windows chooses not to report. */
  readonly sourceFile: string | null;
  /** True when the frame resolves inside the app's own module rather than a
   *  system library or a language runtime. */
  readonly isApplicationFrame: boolean;
}

/** Everything maintain mode knows about one failure's identity. The fields
 *  map one-to-one onto the intake payload of `POST /api/iris/breaks`. */
export interface BreakSignature {
  /** sha256 of the normalized composite, truncated to 32 hex characters — the
   *  same shape `app_breaks.break_signature` already uses. */
  readonly signatureId: string;
  readonly appSlug: string;
  readonly appStack: BreakAppStack;
  readonly kind: BreakSignatureKind;
  readonly algoVersion: number;
  /** Exception/module + top frame: the tier that means "the same failure at
   *  the same place". */
  readonly fingerprintStrict: string;
  /** The loosest surviving identity — absorbs "same bug, offset moved a few
   *  bytes between builds" the way Swift's function-only tier absorbs "code
   *  moved a few lines". */
  readonly fingerprintLoose: string;
  /** The frames a human reads when reviewing what got pooled. */
  readonly topFrames: readonly BreakSignatureFrame[];
  /** The pre-hash composite, kept for debugging bucketing decisions. */
  readonly protoSignature: string;
}

/** The parsed shape of one Windows crash artifact — only the fields grouping
 *  needs, not the whole `Report.wer` format. Shared between this file's
 *  narrow `parseWerReportForSignature` and (per the porting spec) the future
 *  full parser in `wer-report.ts`, which reads the same fields out of the
 *  live Event ID 1000 XML variant instead of the archived file — so either
 *  parser can hand `nativeCrashSignature` an identical shape. */
export interface ParsedWindowsCrash {
  readonly appName: string;
  readonly appPath?: string;
  readonly appVersion?: string;
  /** Lowercase, unprefixed hex (`"c0000005"`, not `"0xC0000005"`) — see
   *  `normalizeHexField`. */
  readonly exceptionCode?: string;
  readonly faultingModuleName?: string;
  readonly faultingModuleVersion?: string;
  /** Lowercase, unprefixed hex byte offset into the faulting module. */
  readonly faultingOffset?: string;
  /** WER's own report GUID — the live watcher's dedupe key (porting spec
   *  §2.1's "one dedupe, by `ReportIdentifier`"). Not used by this file's own
   *  signature functions; carried through for whoever wires the watcher. */
  readonly reportId?: string;
}

/** Bumped only with a shadow-mode migration on the server. Never reuse a
 *  version number for a changed scheme. Windows' OWN counter — see the header
 *  comment; never compare this to Swift's `signatureAlgoVersion`. */
export const WINDOWS_SIGNATURE_ALGO_VERSION = 1;

const SIG_FIELD_PATTERN = /^Sig\[(\d+)\]\.(Name|Value)$/;

/** Normalizes a hex field Windows sometimes writes with a `0x` prefix and
 *  sometimes without, and in either upper or lower case, to one lowercase,
 *  unprefixed form — so `"0xC0000005"` and `"c0000005"` bucket identically. */
function normalizeHexField(rawValue: string): string {
  const trimmed = rawValue.trim();
  const lowered = trimmed.toLowerCase();
  return lowered.startsWith("0x") ? lowered.slice(2) : lowered;
}

/** One `Sig[N].Name`/`Sig[N].Value` pair, keyed by `N` while both halves are
 *  collected — a `Report.wer` file writes the name and the value as two
 *  separate lines that may arrive in either order. */
interface SigFieldEntry {
  name?: string;
  value?: string;
}

/**
 * Reads the flat `Key=Value` portion of a `Report.wer` file's text — the
 * classic Windows Error Reporting "AppCrash" bucket format — into the fields
 * `nativeCrashSignature` needs. Stops at the first bracketed section header
 * (real `Report.wer` files close with a `[dynamic data]` block of opaque
 * bucket bytes); nothing after that line is `Key=Value`, so parsing it would
 * misread binary-ish content as fields rather than skip it.
 *
 * Deliberately narrow: see the module header for why this is not the full
 * WER/event-log parser the porting spec assigns to `wer-report.ts`.
 */
export function parseWerReportForSignature(text: string): ParsedWindowsCrash {
  const flatFields = new Map<string, string>();
  const sigFieldsByIndex = new Map<number, SigFieldEntry>();

  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.length === 0) {
      continue;
    }
    if (/^\[.+\]$/.test(line)) {
      break;
    }
    const separatorIndex = line.indexOf("=");
    if (separatorIndex <= 0) {
      continue;
    }
    const key = line.slice(0, separatorIndex).trim();
    const value = line.slice(separatorIndex + 1).trim();

    const sigMatch = SIG_FIELD_PATTERN.exec(key);
    if (sigMatch !== null) {
      const sigIndex = Number.parseInt(sigMatch[1], 10);
      const entry = sigFieldsByIndex.get(sigIndex) ?? {};
      if (sigMatch[2] === "Name") {
        entry.name = value;
      } else {
        entry.value = value;
      }
      sigFieldsByIndex.set(sigIndex, entry);
      continue;
    }
    flatFields.set(key, value);
  }

  const sigFieldsByName = new Map<string, string>();
  for (const entry of sigFieldsByIndex.values()) {
    if (entry.name !== undefined && entry.value !== undefined) {
      sigFieldsByName.set(entry.name, entry.value);
    }
  }

  const appName = sigFieldsByName.get("Application Name") ?? flatFields.get("AppName") ?? "unknown.exe";
  const appPath = flatFields.get("AppPath");
  const appVersion = sigFieldsByName.get("Application Version");
  const faultingModuleName = sigFieldsByName.get("Fault Module Name");
  const faultingModuleVersion = sigFieldsByName.get("Fault Module Version");
  const exceptionCodeRaw = sigFieldsByName.get("Exception Code");
  const faultingOffsetRaw = sigFieldsByName.get("Exception Offset");
  const reportId = flatFields.get("ReportIdentifier");

  return {
    appName,
    appPath,
    appVersion,
    exceptionCode: exceptionCodeRaw === undefined ? undefined : normalizeHexField(exceptionCodeRaw),
    faultingModuleName,
    faultingModuleVersion,
    faultingOffset: faultingOffsetRaw === undefined ? undefined : normalizeHexField(faultingOffsetRaw),
    reportId,
  };
}

// ---------------------------------------------------------------------------
// Native-crash signature (the one kind Windows parses an artifact for).
// ---------------------------------------------------------------------------

/** Windows' variant of `BreakSignatureService.nativeCrashSignature`: at most
 *  one synthetic frame — a fault module and offset — never a walked stack.
 *  See the module header for why this is a deliberate parity behavior. */
export function nativeCrashSignature(
  parsedCrash: ParsedWindowsCrash,
  appSlug: string,
  appStack: BreakAppStack,
): BreakSignature {
  // Matches Swift's own fallback token for a missing exception type, kept
  // identical here for the same reason Swift chose it: categorical beats no
  // identity at all.
  const exceptionCode = parsedCrash.exceptionCode ?? "UNKNOWN_EXCEPTION";
  const module = parsedCrash.faultingModuleName ?? "unknown-module";

  // Every "function" that lands in a `BreakSignatureFrame` passes through
  // `normalizeSymbol`, exactly like Swift's `nativeCrashSignature` does for
  // every real frame — this keeps the two code paths structurally identical
  // rather than special-casing the Windows one.
  //
  // A WER fault offset is a bare byte offset into the faulting module with no
  // symbol attached, and `parseWerReportForSignature` has already stripped any
  // `0x` prefix via `normalizeHexField`. Present it back to `normalizeSymbol`
  // as the address it is — `0x`-prefixed — so its address rule collapses it to
  // the same `<x>` placeholder every macOS `0x` address in a real frame
  // collapses to. Without this, two captures of one bug whose offset merely
  // shifted between builds hash to two different signatureIds; with it they
  // land on one identity, which is the entire point of recognizing a
  // recurrence (see the same-bug dedup test). A missing offset stays a stable
  // literal token rather than becoming a bogus `0x`.
  const faultingOffset = parsedCrash.faultingOffset;
  const normalizedOffset = faultingOffset !== undefined ? normalizeSymbol(`0x${faultingOffset}`) : "unknown-offset";
  const functionDescriptor = `offset:${normalizedOffset}`;
  const isApplicationFrame = module === parsedCrash.appName;

  const frame: BreakSignatureFrame = {
    module,
    function: functionDescriptor,
    sourceFile: null,
    isApplicationFrame,
  };

  const composite = `${appSlug}|${appStack}|${exceptionCode}|${module}!${functionDescriptor}`;

  return {
    signatureId: truncatedSha256(composite),
    appSlug,
    appStack,
    kind: "native-crash",
    algoVersion: WINDOWS_SIGNATURE_ALGO_VERSION,
    // Swift's fingerprintStrict is "exceptionType|topFile|topFunction"; there
    // is no file on Windows, so the module — the one piece of "where" Windows
    // honestly has — stands in for it.
    fingerprintStrict: `${exceptionCode}|${module}|${functionDescriptor}`,
    // The honest Windows analog of "function only": there is no symbol to
    // fall back to without a symbol server, so the module name is the whole
    // of what survives a build that shifts the offset.
    fingerprintLoose: module,
    topFrames: [frame],
    protoSignature: composite,
  };
}

// ---------------------------------------------------------------------------
// Categorical signatures (no stack: the stack would be noise). Straight,
// unchanged ports of the Swift functions of the same name.
// ---------------------------------------------------------------------------

export function hangSignature(
  appSlug: string,
  appStack: BreakAppStack,
  blockedTopFrame: string | null,
): BreakSignature {
  const frame = blockedTopFrame !== null ? normalizeSymbol(blockedTopFrame) : "main-thread";
  const composite = `${appSlug}|${appStack}|hang|${frame}`;
  return {
    signatureId: truncatedSha256(composite),
    appSlug,
    appStack,
    kind: "hang",
    algoVersion: WINDOWS_SIGNATURE_ALGO_VERSION,
    fingerprintStrict: `hang|${frame}`,
    fingerprintLoose: frame,
    topFrames: [],
    protoSignature: composite,
  };
}

/**
 * A Rust panic, from a Tauri app's stderr (the loop's log tap, not a crash
 * artifact — a default Rust panic unwinds rather than crashing, so there is
 * no `.wer` report either). The message is normalized and the `file:line`
 * location kept as the anchor; the caller's location, never the panic
 * machinery, is the identity. Straight port of Swift's `rustPanicSignature`.
 */
export function rustPanicSignature(appSlug: string, appStack: BreakAppStack, panicStderr: string): BreakSignature {
  // Both formats: old `panicked at 'msg', src/f.rs:1:2` and new
  // `panicked at src/f.rs:1:2:\nmsg`. Pull a file:line and a message.
  const locationMatch = panicStderr.match(/[\w./-]+\.rs:\d+(?::\d+)?/);
  const location = locationMatch !== null ? locationMatch[0] : "unknown.rs";
  const fileOnly = location.split(":")[0] ?? "unknown.rs";

  const oldStyleMessageMatch = panicStderr.match(/(?<=panicked at ')[^']+/);
  const newStyleMessageMatch = panicStderr.match(/(?<=:\n)[^\n]+/);
  const rawMessage = oldStyleMessageMatch?.[0] ?? newStyleMessageMatch?.[0] ?? panicStderr;
  const message = normalizeMessage(rawMessage);

  const composite = `${appSlug}|${appStack}|rust-panic|${fileOnly}|${message}`;
  return {
    signatureId: truncatedSha256(composite),
    appSlug,
    appStack,
    kind: "rust-panic",
    algoVersion: WINDOWS_SIGNATURE_ALGO_VERSION,
    fingerprintStrict: `rust-panic|${fileOnly}|${message}`,
    fingerprintLoose: message,
    topFrames: [],
    protoSignature: composite,
  };
}

/**
 * An Electron renderer that went away. Categorical only — Chromium has
 * already bucketed it into one of its own reasons (`crashed`, `oom`,
 * `killed`, `launch-failed`, …); there is no stack worth hashing, and the
 * renderer-gone reason is the whole identity. Straight port of Swift's
 * `electronRendererGoneSignature`.
 */
export function electronRendererGoneSignature(appSlug: string, reason: string): BreakSignature {
  const normalizedReason = normalizeMessage(reason);
  const composite = `${appSlug}|electron|renderer-gone|${normalizedReason}`;
  return {
    signatureId: truncatedSha256(composite),
    appSlug,
    appStack: "electron",
    kind: "js-exception",
    algoVersion: WINDOWS_SIGNATURE_ALGO_VERSION,
    fingerprintStrict: `renderer-gone|${normalizedReason}`,
    fingerprintLoose: `renderer-gone|${normalizedReason}`,
    topFrames: [],
    protoSignature: composite,
  };
}

/**
 * Out of memory. Deliberately no stack — an OOM's "stack" is wherever the
 * last allocation happened to land, which is noise; the identity is just
 * "this app OOMs". Straight port of Swift's `outOfMemorySignature`.
 */
export function outOfMemorySignature(appSlug: string, appStack: BreakAppStack): BreakSignature {
  const composite = `${appSlug}|${appStack}|oom`;
  return {
    signatureId: truncatedSha256(composite),
    appSlug,
    appStack,
    kind: "oom",
    algoVersion: WINDOWS_SIGNATURE_ALGO_VERSION,
    fingerprintStrict: "oom",
    fingerprintLoose: "oom",
    topFrames: [],
    protoSignature: composite,
  };
}

/** Straight port of Swift's `launchFailureSignature`. `daemon` names what was
 *  being launched (an exe name, e.g.); `normalizedReason` is free text before
 *  normalization — this function normalizes it, matching the Swift call
 *  shape where the caller passes the raw reason through unmassaged. */
export function launchFailureSignature(
  appSlug: string,
  appStack: BreakAppStack,
  daemon: string,
  normalizedReason: string,
): BreakSignature {
  const reason = normalizeMessage(normalizedReason);
  const composite = `${appSlug}|${appStack}|launch|${daemon}|${reason}`;
  return {
    signatureId: truncatedSha256(composite),
    appSlug,
    appStack,
    kind: "launch-failure",
    algoVersion: WINDOWS_SIGNATURE_ALGO_VERSION,
    fingerprintStrict: `launch|${daemon}|${reason}`,
    fingerprintLoose: `launch|${daemon}`,
    topFrames: [],
    protoSignature: composite,
  };
}

// ---------------------------------------------------------------------------
// Normalization — see the module header for the parity requirement on
// `normalizeMessage`.
// ---------------------------------------------------------------------------

/**
 * Strips what varies between two hits of the same bug: hex addresses, Rust
 * generic-instantiation disambiguators, template noise, and trailing offsets.
 * Deliberately does NOT strip closure nesting or argument labels — those
 * distinguish genuinely different call sites. Unchanged port of Swift's
 * `normalizeSymbol`.
 */
export function normalizeSymbol(symbol: string): string {
  return symbol
    .replace(/0x[0-9a-fA-F]+/g, "<x>") // addresses
    .replace(/\+ [0-9]+$/, "<x>") // trailing offsets
    .replace(/::h[0-9a-f]{16}/g, "<x>") // Rust v0/legacy generic hashes
    .replace(/\$[0-9a-f]{8,}/g, "<x>") // mangling residue
    .trim();
}

/** The normalized-message cap, mirroring `MAX_NORMALIZED_LENGTH` in
 *  `lib/break-signature.ts` exactly — see the parity requirement above. */
const MAX_NORMALIZED_MESSAGE_LENGTH = 300;

/**
 * Message normalization for launch failures, rust panics, and renderer-gone
 * reasons: paths, UUIDs, and numbers become placeholders so the message's
 * shape, not its incidentals, is the identity. The patterns and their order
 * MIRROR `lib/break-signature.ts`'s `normalizeBreakMessage` byte-for-byte —
 * see the module header. Any change here changes there, with a test on both
 * sides (`tests/maintain-break-signature.test.ts`'s shared vector table).
 * Path replacement is also the mandatory redaction: every Windows path embeds
 * the account name (`C:\Users\<name>\...`).
 */
/**
 * Re-exported from `@iris/core` rather than implemented here.
 *
 * This was a byte-for-byte hand port of publik's `normalizeBreakMessage`, and
 * the suite asserted parity by importing publik's copy across the repository
 * boundary — a check that broke the moment the clients were split out. One
 * implementation in the core is what that check was trying to buy; now it is
 * true by construction instead of by assertion, and macOS gets the same answer
 * through JavaScriptCore.
 */
export const normalizeMessage = normalizeBreakMessage;

/** sha256 of the composite, truncated to 32 lowercase hex characters — the
 *  same shape `app_breaks.break_signature` already uses. Unchanged port of
 *  Swift's `truncatedSHA256`. */
export function truncatedSha256(composite: string): string {
  return createHash("sha256").update(composite, "utf8").digest("hex").slice(0, 32);
}

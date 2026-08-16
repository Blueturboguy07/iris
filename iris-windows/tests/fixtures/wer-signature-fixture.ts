/**
 * wer-signature-fixture.ts
 *
 * Small builder + a few ready-made `Report.wer` text blobs for exercising
 * `break-signature.ts`'s narrow `parseWerReportForSignature` parser in
 * `tests/maintain-break-signature.test.ts`.
 *
 * Scope note: this is deliberately NOT named `wer-report-fixture.ts` — the
 * porting spec (§1, §7) assigns that filename to the FULL WER/event-log
 * parser's own fixture set (`wer-report.ts`, a separate module outside this
 * task's scope). Reusing that name here would collide with whoever builds
 * that module next. This file's fixtures are scoped to the flat `Key=Value`
 * identity fields `parseWerReportForSignature` reads — realistic enough to
 * exercise that parser, not a full replica of every section a real
 * `Report.wer` carries (no `DynamicSig[]`, no `UI[]`, no `LoadedModule[]`
 * block — those are the full parser's problem, not this narrow one's).
 *
 * A real `Report.wer` is written by Windows Error Reporting to
 * `%ProgramData%\Microsoft\Windows\WER\ReportArchive\<ReportName>\Report.wer`
 * as a flat `Key=Value` bucket (the classic `AppCrash` shape:
 * `Sig[0].Name=Application Name`, `Sig[0].Value=cue.exe`, …), followed by a
 * `[dynamic data]` section of opaque bucket bytes. `buildAppCrashWerText`
 * renders that shape from a plain field map so a test can vary one field at a
 * time without hand-writing a multi-line string blob per case.
 */

/** The `Sig[N]` identity fields a real `AppCrash` `Report.wer` carries, in the
 *  order Windows itself writes them. Every field is optional so a test can
 *  omit one to prove the parser's fallbacks (`"unknown.exe"`, `undefined`, …)
 *  without constructing a whole fixture by hand. */
export interface AppCrashWerFields {
  readonly applicationName?: string;
  readonly applicationVersion?: string;
  readonly faultModuleName?: string;
  readonly faultModuleVersion?: string;
  /** Rendered exactly as given — pass `"c0000005"` or `"0xC0000005"` to
   *  exercise `normalizeHexField`'s two accepted shapes. */
  readonly exceptionCode?: string;
  readonly exceptionOffset?: string;
  readonly reportIdentifier?: string;
  readonly appPath?: string;
  /** Extra flat `Key=Value` lines to splice in verbatim before the `Sig[]`
   *  block — for a test that needs a field this builder does not name. */
  readonly extraFlatLines?: readonly string[];
  /** Appends a `[dynamic data]` section after the flat fields, matching a
   *  real `Report.wer`'s trailing opaque bucket-bytes block. Defaults to
   *  `true` so the common case proves the parser actually stops there rather
   *  than misreading it. */
  readonly includeDynamicDataSection?: boolean;
}

/**
 * Renders a realistic `AppCrash` `Report.wer` text blob (flat `Key=Value`
 * portion, `Sig[]` identity block, optional trailing `[dynamic data]`
 * section) from a plain field map. Every `Sig[]` entry is written as its own
 * `Sig[N].Name=`/`Sig[N].Value=` line pair, matching the real file format —
 * never a single combined line — so the fixture actually exercises the
 * parser's two-line collection logic instead of shortcutting it. Windows
 * writes `Report.wer` with CRLF line endings, so this builder does too.
 */
export function buildAppCrashWerText(fields: AppCrashWerFields = {}): string {
  const lines: string[] = ["Version=1", "EventType=APPCRASH", "ReportType=2", "Consent=1"];

  if (fields.reportIdentifier !== undefined) {
    lines.push(`ReportIdentifier=${fields.reportIdentifier}`);
  }
  if (fields.appPath !== undefined) {
    lines.push(`AppPath=${fields.appPath}`);
  }
  for (const extraLine of fields.extraFlatLines ?? []) {
    lines.push(extraLine);
  }

  let sigIndex = 0;
  const pushSigField = (name: string, value: string | undefined): void => {
    if (value === undefined) {
      return;
    }
    lines.push(`Sig[${sigIndex}].Name=${name}`);
    lines.push(`Sig[${sigIndex}].Value=${value}`);
    sigIndex += 1;
  };
  pushSigField("Application Name", fields.applicationName);
  pushSigField("Application Version", fields.applicationVersion);
  pushSigField("Fault Module Name", fields.faultModuleName);
  pushSigField("Fault Module Version", fields.faultModuleVersion);
  pushSigField("Exception Code", fields.exceptionCode);
  pushSigField("Exception Offset", fields.exceptionOffset);

  if (fields.includeDynamicDataSection ?? true) {
    lines.push("");
    lines.push("[dynamic data]");
    // Real dynamic-data bytes are opaque binary; a line that LOOKS like a
    // Key=Value pair here proves the parser really stops at the section
    // header rather than continuing to read past it.
    lines.push("Sig[99].Name=Should Never Be Read");
    lines.push("Sig[99].Value=Should Never Be Read");
  }

  return lines.join("\r\n");
}

/** A realistic, fully-populated crash report for a catalog app named `cue`,
 *  matching the module header's own doc-comment example
 *  (`Sig[0].Value=cue.exe`). The fault module matches the application name,
 *  so this is also the `isApplicationFrame: true` case. */
export const CUE_APPCRASH_WER_FIXTURE = buildAppCrashWerText({
  applicationName: "cue.exe",
  applicationVersion: "0.2.3.0",
  faultModuleName: "cue.exe",
  faultModuleVersion: "0.2.3.0",
  exceptionCode: "c0000005",
  exceptionOffset: "0000000000012345",
  reportIdentifier: "a1b2c3d4-1234-5678-9abc-def012345678",
  appPath: "C:\\Users\\test\\AppData\\Local\\Programs\\cue\\cue.exe",
});

/** The upper-case, `0x`-prefixed spelling Windows sometimes uses for the same
 *  two hex fields as `CUE_APPCRASH_WER_FIXTURE` — proves
 *  `parseWerReportForSignature` normalizes both spellings to the same
 *  lowercase, unprefixed value via `normalizeHexField`. */
export const CUE_APPCRASH_WER_FIXTURE_HEX_PREFIXED = buildAppCrashWerText({
  applicationName: "cue.exe",
  faultModuleName: "cue.exe",
  exceptionCode: "0xC0000005",
  exceptionOffset: "0X0000000000012345",
  reportIdentifier: "a1b2c3d4-1234-5678-9abc-def012345678",
});

/** A crash inside a system DLL rather than the app's own module — the
 *  `isApplicationFrame: false` case, since `Fault Module Name` differs from
 *  `Application Name`. */
export const CUE_APPCRASH_WER_FIXTURE_FOREIGN_MODULE = buildAppCrashWerText({
  applicationName: "cue.exe",
  faultModuleName: "KERNELBASE.dll",
  exceptionCode: "c0000005",
  exceptionOffset: "000000000004a1b0",
});

/** No `Sig[]` block at all — only the flat `AppName` fallback field. Proves
 *  the flat-field fallback (`flatFields.get("AppName")`) really does fire
 *  when the `Sig[]` identity block is entirely absent, which happens on a
 *  malformed or truncated report. */
export const MINIMAL_WER_FIXTURE_WITH_FLAT_APPNAME_ONLY = buildAppCrashWerText({
  extraFlatLines: ["AppName=fallback-app.exe"],
  includeDynamicDataSection: false,
});

/** The degenerate case: no identity fields anywhere, not even the flat
 *  `AppName` fallback — exercises `"unknown.exe"` and every other field
 *  coming back `undefined`. */
export const EMPTY_WER_FIXTURE = buildAppCrashWerText({ includeDynamicDataSection: false });

/** `Sig[N].Value` written before its matching `Sig[N].Name` — real
 *  `Report.wer` files do not guarantee line order within a pair, so the
 *  parser's two-line collection must not assume `Name` arrives first. Built
 *  by hand rather than through `buildAppCrashWerText` (which always writes
 *  `Name` first) specifically to cover the order the builder cannot produce. */
export const REORDERED_SIG_FIELDS_WER_FIXTURE = [
  "Version=1",
  "EventType=APPCRASH",
  "Sig[0].Value=cue.exe",
  "Sig[0].Name=Application Name",
  "Sig[1].Value=c0000005",
  "Sig[1].Name=Exception Code",
].join("\r\n");

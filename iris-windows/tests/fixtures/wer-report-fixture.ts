/**
 * wer-report-fixture.ts
 *
 * Builds realistic `Report.wer` text for `maintain-break-signature.test.ts` —
 * the classic Windows Error Reporting "AppCrash" bucket format
 * (`Sig[N].Name=`/`Sig[N].Value=` pairs, a handful of flat top-level keys,
 * then a `[dynamic data]` section of bytes no parser here is meant to read).
 * Hand-typing this shape inline in every test would bury the one or two
 * fields a given test actually varies under boilerplate every other test
 * repeats, so this fixture takes only the fields a test cares about and fills
 * in realistic defaults for the rest.
 *
 * Not a `*.test.ts` file itself (vitest's `include` is `tests/**\/*.test.ts`),
 * so this is a plain importable helper, not a suite of its own.
 */

export interface WerReportFixtureFields {
  readonly reportIdentifier: string;
  readonly applicationName: string;
  readonly applicationVersion: string;
  readonly faultModuleName: string;
  readonly faultModuleVersion: string;
  /** May carry a `0x` prefix and either case — real WER reports are
   *  inconsistent about both, and `parseWerReportForSignature` is expected to
   *  normalize it away regardless of which form a fixture uses. */
  readonly exceptionCode: string;
  readonly exceptionOffset: string;
  readonly appPath: string;
}

const DEFAULT_FIELDS: WerReportFixtureFields = {
  reportIdentifier: "3f2a9c1e-8b4d-4e6a-9c2f-1a2b3c4d5e6f",
  applicationName: "cue.exe",
  applicationVersion: "1.4.2.0",
  faultModuleName: "KERNELBASE.dll",
  faultModuleVersion: "10.0.19041.3636",
  exceptionCode: "c0000005",
  exceptionOffset: "0001a2b3",
  appPath: "C:\\Program Files\\cue\\cue.exe",
};

/**
 * Assembles one `Report.wer` file's text, in the real on-disk field order
 * (`Sig[N]` pairs, then flat keys, then the opaque `[dynamic data]` section),
 * with any subset of fields overridden. Every test that only cares about one
 * or two fields (e.g. "a report missing Exception Offset") calls this with
 * just those overrides rather than repeating the whole shape.
 */
export function buildWerReportFixtureText(overrides: Partial<WerReportFixtureFields> = {}): string {
  const fields: WerReportFixtureFields = { ...DEFAULT_FIELDS, ...overrides };

  return [
    "Version=1",
    "EventType=APPCRASH",
    "EventTime=133480012345678900",
    "ReportType=2",
    "Consent=1",
    `ReportIdentifier=${fields.reportIdentifier}`,
    "Sig[0].Name=Application Name",
    `Sig[0].Value=${fields.applicationName}`,
    "Sig[1].Name=Application Version",
    `Sig[1].Value=${fields.applicationVersion}`,
    "Sig[2].Name=Application Timestamp",
    "Sig[2].Value=5f4d3c2b",
    "Sig[3].Name=Fault Module Name",
    `Sig[3].Value=${fields.faultModuleName}`,
    "Sig[4].Name=Fault Module Version",
    `Sig[4].Value=${fields.faultModuleVersion}`,
    "Sig[5].Name=Fault Module Timestamp",
    "Sig[5].Value=abcdef12",
    "Sig[6].Name=Exception Code",
    `Sig[6].Value=${fields.exceptionCode}`,
    "Sig[7].Name=Exception Offset",
    `Sig[7].Value=${fields.exceptionOffset}`,
    "DynamicSig[1].Name=OS Version",
    "DynamicSig[1].Value=10.0.19045.2.0.0.256.48",
    "DynamicSig[2].Name=Locale ID",
    "DynamicSig[2].Value=1033",
    `UI[2]=${fields.applicationName} has stopped working`,
    "FriendlyEventName=Stopped working",
    "ConsentKey=APPCRASH",
    `AppName=${fields.applicationName}`,
    `AppPath=${fields.appPath}`,
    "",
    "[dynamic data]",
    // A poisoned `Sig[6].Value` line, keyed identically to the real one
    // above the section header. If a parser kept reading `Key=Value` pairs
    // past the section boundary instead of stopping there, this would
    // silently overwrite the real Exception Code with "00000000-poison" —
    // which is exactly what `parseWerReportForSignature`'s "never reads past
    // the first bracketed section header" test asserts does NOT happen. Real
    // `Report.wer` files carry opaque bucket bytes here, not text like this;
    // the fixture uses a colliding key on purpose, as the sharpest possible
    // regression test for the boundary.
    "Sig[6].Value=00000000-poison",
  ].join("\r\n");
}

/**
 * The shared consent file, as pure data — the Windows half of
 * `PublikConsentStore.swift`. `main/usage.ts` does the reading and writing of
 * `%LOCALAPPDATA%\publik\consent.json` (publik's docs/publik-sdk-convention.md
 * §4); everything that decides what goes in it lives here, tested.
 *
 *     {"telemetry": false, "install_id": "<uuid>", "updated_at": "…"}
 *
 * Iris owns the file; catalog apps only read it. What must survive every
 * write:
 *   - `telemetry` is crash telemetry and stays OPT-IN. Nothing here sets it
 *     true. A file Iris creates starts with `false`; an existing value is kept.
 *   - `install_id` is random, never a user or hardware id, and is also the
 *     capability that erases this install's history on the server.
 *   - Keys Iris does not know about are carried through untouched.
 *
 * The usage keys (founder, 2026-09-25: "default toggled on"):
 *   usage                   true/false; ABSENT until the disclosure has been
 *                           on screen — nothing is counted before then
 *   usage_disclosed_at      when the disclosure first appeared
 *   usage_choice_confirmed  true once Continue or Turn off was pressed
 */

export type ConsentDocument = Record<string, unknown>;

export type UsageSharingState = "notYetDisclosed" | "sharing" | "notSharing";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** A missing, unreadable or non-object file reads as empty. */
export function parseConsentDocument(fileText: string | null): ConsentDocument {
  if (!fileText) return {};
  try {
    const parsed: unknown = JSON.parse(fileText);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as ConsentDocument) : {};
  } catch {
    return {};
  }
}

export function usageSharingState(document: ConsentDocument): UsageSharingState {
  if (document.usage === true) return "sharing";
  if (document.usage === false) return "notSharing";
  return "notYetDisclosed";
}

export function usageDisclosureHasBeenShown(document: ConsentDocument): boolean {
  return typeof document.usage_disclosed_at === "string";
}

export function readerHasAnsweredTheUsageDisclosure(document: ConsentDocument): boolean {
  return document.usage_choice_confirmed === true;
}

export function crashTelemetryIsOn(document: ConsentDocument): boolean {
  return document.telemetry === true;
}

/** The stored install id when it is a well-formed UUID, else null. */
export function storedInstallIdentifier(document: ConsentDocument): string | null {
  const stored = document.install_id;
  return typeof stored === "string" && UUID_PATTERN.test(stored) ? stored.toLowerCase() : null;
}

/** Fills in what every written file must carry, keeping whatever is there. */
function withRequiredFields(document: ConsentDocument, mintInstallIdentifier: () => string, now: Date): ConsentDocument {
  return {
    ...document,
    telemetry: typeof document.telemetry === "boolean" ? document.telemetry : false,
    install_id: storedInstallIdentifier(document) ?? mintInstallIdentifier().toLowerCase(),
    updated_at: now.toISOString(),
  };
}

/** The install id is being read for the first time: mint it if needed. */
export function withInstallIdentifier(document: ConsentDocument, mintInstallIdentifier: () => string, now: Date): ConsentDocument {
  if (storedInstallIdentifier(document)) return document;
  return withRequiredFields(document, mintInstallIdentifier, now);
}

/**
 * The disclosure is on screen: from now the switch reads ON unless the reader
 * turns it off. A second call changes nothing — including a switch already off.
 */
export function withUsageDisclosureShown(document: ConsentDocument, mintInstallIdentifier: () => string, now: Date): ConsentDocument {
  if (usageDisclosureHasBeenShown(document)) return document;
  const next = withRequiredFields(document, mintInstallIdentifier, now);
  next.usage_disclosed_at = now.toISOString();
  if (typeof next.usage !== "boolean") next.usage = true;
  return next;
}

/** Continue, Turn off, or the settings switch. */
export function withUsageSharingChoice(
  document: ConsentDocument,
  sharingOn: boolean,
  mintInstallIdentifier: () => string,
  now: Date
): ConsentDocument {
  const next = withRequiredFields(document, mintInstallIdentifier, now);
  if (!usageDisclosureHasBeenShown(next)) next.usage_disclosed_at = now.toISOString();
  next.usage = sharingOn;
  next.usage_choice_confirmed = true;
  return next;
}

export function serializeConsentDocument(document: ConsentDocument): string {
  const sortedKeys = Object.keys(document).sort();
  const sorted: ConsentDocument = {};
  for (const key of sortedKeys) sorted[key] = document[key];
  return `${JSON.stringify(sorted, null, 2)}\n`;
}

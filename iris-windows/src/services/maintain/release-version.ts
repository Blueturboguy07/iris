/**
 * release-version.ts
 *
 * Straight, unchanged-semantics port of
 * `iris-macos/leanring-buddy/ReleaseVersionComparison.swift`. `replay-engine.ts`'s
 * `recipeApplicabilityMatches` needs this to decide whether a pooled recipe's
 * `app_version` range covers the machine attempting the replay — see that
 * file's header ("CROSS-MODULE CONTRACT") for the exact shape it was written
 * against, reproduced here so the two stay honest:
 *
 *   compareReleaseVersions(a, b): "older" | "same" | "newer" | "cannotBeCompared"
 *
 * This exists as its own module, with its own tests, because the obvious
 * shortcut is wrong in a way that actively harms people. Comparing two
 * version strings with `<` puts `v1.10.0` *before* `v1.9.0`, because "1"
 * sorts before "9" one character at a time. A recipe's applicability range
 * would then silently misjudge which installs it covers — offering a stale
 * patch to someone already past it, or withholding a good one from someone
 * still affected. Both are wrong, and the first one is actively harmful (it
 * would try to apply a patch that no longer matches the code).
 *
 * So the comparison is done properly: numerically, component by component,
 * tolerating the leading `v` that release tags carry, tolerating a different
 * number of components on each side (a missing component reads as zero, so
 * `1.2` and `1.2.0` compare equal), and applying the semver rule that a
 * pre-release sorts *below* the release it leads up to. Anything this cannot
 * read confidently returns `"cannotBeCompared"` rather than guessing a
 * direction — "I do not know" is a safe answer and a wrong direction is not.
 * `recipeApplicabilityMatches` treats `"cannotBeCompared"` as "outside the
 * range", the same fail-closed rule it applies to unreadable JSON.
 */

/** The result of comparing two release versions (or attempting to). Never a
 *  boolean and never a signed number — a discriminated string keeps callers
 *  from silently treating "I could not tell" as "equal" or "less than". */
export type ReleaseVersionComparisonResult = "older" | "same" | "newer" | "cannotBeCompared";

/** A successfully parsed version: numeric release components (`[1, 2, 0]` for
 *  `"1.2.0"`) plus, when present, the dot-separated pre-release identifiers
 *  (`["beta", "1"]` for `"-beta.1"`). Build metadata (`+...`) has no bearing
 *  on precedence per semver, so it is discarded during parsing and never
 *  appears here. */
export interface ParsedReleaseVersion {
  readonly numericComponents: number[];
  readonly preReleaseIdentifiers: string[];
}

/** How two already-parsed pre-release identifiers compare, before that is
 *  folded into the coarser `ReleaseVersionComparisonResult` the identifier
 *  loop as a whole reports. */
type IdentifierComparisonResult = "ascending" | "same" | "descending";

/** Deliberately checks ASCII `0`-`9` one character at a time rather than
 *  `/^\d+$/` (which, unanchored to ASCII, would accept Eastern Arabic and
 *  other non-ASCII decimal digits that `Number.parseInt` then reads
 *  differently than their glyphs suggest) — the same guard Swift's
 *  `isASCII && isNumber` check applies. */
function isAllAsciiDigits(value: string): boolean {
  if (value.length === 0) {
    return false;
  }
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    if (codeUnit < 0x30 || codeUnit > 0x39) {
      return false;
    }
  }
  return true;
}

/**
 * Reads a version string, or returns `undefined` when it is not a version at
 * all. Accepts: an optional leading `v`/`V` (release tags almost always
 * carry one), any number of numeric components, an optional
 * `-pre.release` suffix, and an optional `+buildmetadata` suffix — which
 * semver says has no effect on precedence, so it is discarded rather than
 * parsed. Rejects anything with a non-numeric release component (`1.x.3`,
 * `nightly`, `latest`) — a version that cannot be read is not a version that
 * can be ranked.
 */
export function parseReleaseVersion(rawVersionString: string): ParsedReleaseVersion | undefined {
  let remainingText = rawVersionString.trim();
  if (remainingText.length === 0) {
    return undefined;
  }

  // The leading `v` is dropped only when a digit follows it, so a tag
  // literally named "version" is still rejected rather than read as the
  // nonsense version "ersion".
  const firstCharacter = remainingText.charAt(0);
  if (firstCharacter === "v" || firstCharacter === "V") {
    const textAfterTheV = remainingText.slice(1);
    if (textAfterTheV.length > 0 && isAllAsciiDigits(textAfterTheV.charAt(0))) {
      remainingText = textAfterTheV;
    }
  }

  // Build metadata is explicitly ignored for precedence by the semver spec,
  // so `1.2.0+build.7` and `1.2.0` are the same release.
  const buildMetadataSeparatorIndex = remainingText.indexOf("+");
  if (buildMetadataSeparatorIndex !== -1) {
    remainingText = remainingText.slice(0, buildMetadataSeparatorIndex);
  }

  let numericPortion: string;
  let preReleaseIdentifiers: string[];

  const preReleaseSeparatorIndex = remainingText.indexOf("-");
  if (preReleaseSeparatorIndex !== -1) {
    numericPortion = remainingText.slice(0, preReleaseSeparatorIndex);
    const preReleasePortion = remainingText.slice(preReleaseSeparatorIndex + 1);

    // A trailing hyphen with nothing after it is malformed rather than "a
    // release with an empty pre-release".
    if (preReleasePortion.length === 0) {
      return undefined;
    }

    const identifiers = preReleasePortion.split(".");
    if (identifiers.some((identifier) => identifier.length === 0)) {
      return undefined;
    }
    preReleaseIdentifiers = identifiers;
  } else {
    numericPortion = remainingText;
    preReleaseIdentifiers = [];
  }

  const numericComponentStrings = numericPortion.split(".");
  const numericComponents: number[] = [];
  for (const numericComponentString of numericComponentStrings) {
    if (!isAllAsciiDigits(numericComponentString)) {
      return undefined;
    }
    numericComponents.push(Number.parseInt(numericComponentString, 10));
  }

  return { numericComponents, preReleaseIdentifiers };
}

/** Compares two already-parsed versions. `compareReleaseVersions` below is
 *  the entry point callers actually use; this is exposed too since
 *  `recipeApplicabilityMatches` and the test suite both find it useful to
 *  parse once and compare against several ranges without re-parsing. */
export function compareParsedReleaseVersions(
  leftVersion: ParsedReleaseVersion,
  rightVersion: ParsedReleaseVersion,
): "older" | "same" | "newer" {
  // A missing component is a zero, which is what makes `1.2` and `1.2.0` the
  // same release rather than two different ones.
  const comparedComponentCount = Math.max(
    leftVersion.numericComponents.length,
    rightVersion.numericComponents.length,
  );
  for (let componentIndex = 0; componentIndex < comparedComponentCount; componentIndex += 1) {
    const leftComponent =
      componentIndex < leftVersion.numericComponents.length
        ? leftVersion.numericComponents[componentIndex]
        : 0;
    const rightComponent =
      componentIndex < rightVersion.numericComponents.length
        ? rightVersion.numericComponents[componentIndex]
        : 0;
    if (leftComponent < rightComponent) {
      return "older";
    }
    if (leftComponent > rightComponent) {
      return "newer";
    }
  }
  return comparePreReleaseIdentifiers(leftVersion.preReleaseIdentifiers, rightVersion.preReleaseIdentifiers);
}

/** Compares two raw version strings. This is the only entry point most
 *  callers need; parsing is an implementation detail of it. Returns
 *  `"cannotBeCompared"` when either side fails to parse — never a guessed
 *  direction. */
export function compareReleaseVersions(
  leftRawVersionString: string,
  rightRawVersionString: string,
): ReleaseVersionComparisonResult {
  const leftVersion = parseReleaseVersion(leftRawVersionString);
  const rightVersion = parseReleaseVersion(rightRawVersionString);
  if (leftVersion === undefined || rightVersion === undefined) {
    return "cannotBeCompared";
  }
  return compareParsedReleaseVersions(leftVersion, rightVersion);
}

function comparePreReleaseIdentifiers(
  leftIdentifiers: string[],
  rightIdentifiers: string[],
): "older" | "same" | "newer" {
  if (leftIdentifiers.length === 0 && rightIdentifiers.length === 0) {
    return "same";
  }
  // A release with no pre-release identifiers outranks one that has them:
  // `1.2.0` is newer than `1.2.0-beta`.
  if (leftIdentifiers.length === 0) {
    return "newer";
  }
  if (rightIdentifiers.length === 0) {
    return "older";
  }

  const comparedIdentifierCount = Math.min(leftIdentifiers.length, rightIdentifiers.length);
  for (let identifierIndex = 0; identifierIndex < comparedIdentifierCount; identifierIndex += 1) {
    const comparison = compareOnePreReleaseIdentifier(
      leftIdentifiers[identifierIndex],
      rightIdentifiers[identifierIndex],
    );
    if (comparison === "ascending") {
      return "older";
    }
    if (comparison === "descending") {
      return "newer";
    }
    // "same" — keep comparing the remaining identifiers.
  }

  // Every shared identifier matched, so the one with more identifiers is the
  // later pre-release: `1.2.0-beta` comes before `1.2.0-beta.1`.
  if (leftIdentifiers.length < rightIdentifiers.length) {
    return "older";
  }
  if (leftIdentifiers.length > rightIdentifiers.length) {
    return "newer";
  }
  return "same";
}

function compareOnePreReleaseIdentifier(
  leftIdentifier: string,
  rightIdentifier: string,
): IdentifierComparisonResult {
  const leftNumericValue = numericValueOfIdentifier(leftIdentifier);
  const rightNumericValue = numericValueOfIdentifier(rightIdentifier);

  if (leftNumericValue !== undefined && rightNumericValue !== undefined) {
    if (leftNumericValue === rightNumericValue) {
      return "same";
    }
    return leftNumericValue < rightNumericValue ? "ascending" : "descending";
  }

  // Numeric identifiers always rank below alphanumeric ones.
  if (leftNumericValue !== undefined) {
    return "ascending";
  }
  if (rightNumericValue !== undefined) {
    return "descending";
  }

  return compareInAsciiOrder(leftIdentifier, rightIdentifier);
}

function numericValueOfIdentifier(identifier: string): number | undefined {
  return isAllAsciiDigits(identifier) ? Number.parseInt(identifier, 10) : undefined;
}

/** Semver asks for ASCII sort order specifically, so the comparison walks
 *  Unicode code points rather than using `String`'s locale-aware
 *  `localeCompare`, which would put "Beta" and "beta" in an order that
 *  depends on where the user's OS thinks it is. */
function compareInAsciiOrder(leftIdentifier: string, rightIdentifier: string): IdentifierComparisonResult {
  if (leftIdentifier === rightIdentifier) {
    return "same";
  }
  const leftCodePoints = Array.from(leftIdentifier, (character) => character.codePointAt(0) ?? 0);
  const rightCodePoints = Array.from(rightIdentifier, (character) => character.codePointAt(0) ?? 0);
  const comparedLength = Math.min(leftCodePoints.length, rightCodePoints.length);
  for (let index = 0; index < comparedLength; index += 1) {
    const leftCodePoint = leftCodePoints[index];
    const rightCodePoint = rightCodePoints[index];
    if (leftCodePoint < rightCodePoint) {
      return "ascending";
    }
    if (leftCodePoint > rightCodePoint) {
      return "descending";
    }
  }
  // Every shared code point matched (this is the "lexicographicallyPrecedes"
  // prefix case) — the shorter identifier sorts first.
  if (leftCodePoints.length < rightCodePoints.length) {
    return "ascending";
  }
  return "descending";
}

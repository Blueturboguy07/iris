import {
  validateAppStoreMetadataV1,
  validateCatalogAppPageV1,
  validateCatalogIndexEntryMatchesAppPage,
  validateCatalogIndexV2,
} from "../contracts/index.js";
import { SUPPORT_EMAIL } from "./site-content.mjs";

const PUBLIK_ORIGIN = "https://publikhq.com";
const PACKAGE_FORMAT = "iris.mobile-shell.package+json";
const PACKAGE_MEDIA_TYPE = "application/json";
const MAX_PACKAGE_BYTES = 48 * 1024 * 1024;
const STABLE_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,127}$/;
const SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;
const REVISION_ID_PATTERN = /^rev-sha256:[0-9a-f]{64}$/;
const APPLICATION_PREFIX_PATTERN = /^[A-Z0-9]{10}$/;
const BUNDLE_SEGMENT_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/;

export const IRIS_WEBSITE_CONTRACT = Object.freeze({
  origin: PUBLIK_ORIGIN,
  canonicalPathPrefix: "/iris/apps/",
  fallbackScheme: "iris-apps",
  fallbackHost: "install",
  aasaPath: "/.well-known/apple-app-site-association",
});

function requireStableId(value, label) {
  if (typeof value !== "string" || !STABLE_ID_PATTERN.test(value)) {
    throw new TypeError(`${label} is invalid`);
  }
  return value;
}

function requireDisplayName(value) {
  if (typeof value !== "string" || value.length < 1 || new TextEncoder().encode(value).byteLength > 256) {
    throw new TypeError("catalog app name is invalid");
  }
  return value;
}

function hasExplicitUserInfoOrPort(value) {
  const authority = /^[A-Za-z][A-Za-z0-9+.-]*:\/\/([^/?#]*)/.exec(value)?.[1];
  return authority?.includes("@") === true || authority?.includes(":") === true;
}

function validatePublikArtifactURL(value) {
  if (typeof value !== "string") throw new TypeError("mobileShell.downloadUrl is invalid");
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new TypeError("mobileShell.downloadUrl is invalid");
  }
  if (
    url.protocol !== "https:"
    || url.hostname !== "publikhq.com"
    || hasExplicitUserInfoOrPort(value)
    || url.port !== ""
    || url.username !== ""
    || url.password !== ""
    || url.hash !== ""
    || url.pathname === "/"
  ) {
    throw new TypeError("mobileShell.downloadUrl must be a direct https://publikhq.com URL");
  }
  return value;
}

function validateMobileShellDescriptor(descriptor) {
  if (!descriptor || typeof descriptor !== "object" || Array.isArray(descriptor)) {
    throw new TypeError("mobileShell descriptor is invalid");
  }
  if (descriptor.version !== 1) throw new TypeError("mobileShell.version is unsupported");
  if (descriptor.platform !== "ios") throw new TypeError("mobileShell.platform is unsupported");
  if (descriptor.packageFormat !== PACKAGE_FORMAT) throw new TypeError("mobileShell.packageFormat is unsupported");
  validatePublikArtifactURL(descriptor.downloadUrl);
  if (descriptor.mediaType !== PACKAGE_MEDIA_TYPE) throw new TypeError("mobileShell.mediaType is invalid");
  if (!Number.isSafeInteger(descriptor.byteCount) || descriptor.byteCount < 1 || descriptor.byteCount > MAX_PACKAGE_BYTES) {
    throw new TypeError("mobileShell.byteCount is invalid");
  }
  if (!SHA256_PATTERN.test(descriptor.packageSha256 ?? "")) throw new TypeError("mobileShell.packageSha256 is invalid");
  requireStableId(descriptor.appId, "mobileShell.appId");
  requireStableId(descriptor.projectId, "mobileShell.projectId");
  if (descriptor.baseRevisionId !== null && !REVISION_ID_PATTERN.test(descriptor.baseRevisionId ?? "")) {
    throw new TypeError("mobileShell.baseRevisionId is invalid");
  }
  if (!REVISION_ID_PATTERN.test(descriptor.revisionId ?? "")) throw new TypeError("mobileShell.revisionId is invalid");
  if (!SHA256_PATTERN.test(descriptor.contentHash ?? "")) throw new TypeError("mobileShell.contentHash is invalid");
  const expectedRevision = `rev-sha256:${descriptor.contentHash.slice("sha256:".length)}`;
  if (descriptor.revisionId !== expectedRevision) throw new TypeError("mobileShell revision/content binding is invalid");
  if (descriptor.appStoreMetadata !== undefined && descriptor.appStoreMetadata !== null) {
    const result = validateAppStoreMetadataV1(descriptor.appStoreMetadata);
    if (!result.ok) throw new TypeError(`mobileShell.appStoreMetadata is invalid: ${result.errors.join("; ")}`);
  }
  return descriptor;
}

/**
 * True only when a descriptor carries a validated Guideline 4.7 metadata
 * object (age rating, privacy summary/policy, support/report contact). A
 * descriptor with none is still an ordinary, fully installable v1 descriptor;
 * it is simply not ready for an App Store 4.7 listing (see
 * contracts/CONTRACT.md, "AppStoreMetadataV1").
 */
export function isReadyForAppStoreListing(descriptor) {
  if (!descriptor || descriptor.appStoreMetadata === undefined || descriptor.appStoreMetadata === null) return false;
  return validateAppStoreMetadataV1(descriptor.appStoreMetadata).ok;
}

function htmlEscape(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export function canonicalAppURL(slug) {
  return `${PUBLIK_ORIGIN}/iris/apps/${requireStableId(slug, "app slug")}`;
}

export function fallbackInstallURL(slug) {
  return `iris-apps://install/${requireStableId(slug, "app slug")}`;
}

export function parseAppIntentURL(value) {
  if (typeof value !== "string") throw new TypeError("app intent URL must be a string");
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new TypeError("app intent URL is invalid");
  }

  if (url.protocol === "https:") {
    const isHandoff = url.pathname.startsWith(IRIS_WEBSITE_CONTRACT.canonicalPathPrefix);
    const prefix = isHandoff ? IRIS_WEBSITE_CONTRACT.canonicalPathPrefix : "/";
    const slug = url.pathname.slice(prefix.length);
    requireStableId(slug, "app slug");
    const canonical = isHandoff ? canonicalAppURL(slug) : `${PUBLIK_ORIGIN}/${slug}`;
    if (value !== canonical) throw new TypeError("canonical app intent URL is not canonical");
    return Object.freeze({ kind: isHandoff ? "canonical" : "listing", slug, url: canonical });
  }

  if (url.protocol === `${IRIS_WEBSITE_CONTRACT.fallbackScheme}:`) {
    const slug = url.pathname.startsWith("/") ? url.pathname.slice(1) : url.pathname;
    requireStableId(slug, "app slug");
    const fallback = fallbackInstallURL(slug);
    if (value !== fallback) throw new TypeError("fallback app intent URL is not canonical");
    return Object.freeze({ kind: "fallback", slug, url: fallback });
  }

  throw new TypeError("app intent URL scheme is unsupported");
}

export function validateAppleDistributionURL(value) {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string") throw new TypeError("Iris distribution URL must be a string");
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new TypeError("Iris distribution URL is invalid");
  }
  if (
    url.protocol !== "https:"
    || hasExplicitUserInfoOrPort(value)
    || url.port !== ""
    || url.username !== ""
    || url.password !== ""
    || url.hash !== ""
    || url.search !== ""
  ) {
    throw new TypeError("Iris distribution URL must be a direct Apple HTTPS URL");
  }

  const appStorePath = /^\/(?:[a-z]{2}\/)?app\/(?:[^/?#]+\/)?id[0-9]+\/?$/;
  const testFlightPath = /^\/join\/[A-Za-z0-9]+\/?$/;
  const validAppStore = url.hostname === "apps.apple.com" && appStorePath.test(url.pathname);
  const validTestFlight = url.hostname === "testflight.apple.com" && testFlightPath.test(url.pathname) && url.search === "";
  if (!validAppStore && !validTestFlight) {
    throw new TypeError("Iris distribution URL must be an App Store app URL or TestFlight join URL");
  }
  return value;
}

/**
 * Adapts catalog v2 index pages plus per-app detail pages (apps/<slug>.json,
 * mobile-shell/contracts CatalogIndexV2 / CatalogAppPageV1) into the
 * `catalogRows` shape resolveCatalogHandoff/renderAppsIndexHTML/
 * renderCatalogHandoffHTML already expect ({slug, name, mobileShell}), so
 * this website's App Store/TestFlight join URL rule (validateAppleDistributionURL)
 * and the rest of the handoff pipeline are unchanged by the new catalog
 * format. Every index page and every referenced app page is re-validated
 * against the contracts here (fail closed on a malformed publish), and an
 * index entry with no matching app page is surfaced as "not available"
 * rather than thrown away or silently treated as installable.
 */
export function catalogRowsFromIndexV2({ indexPages, appPages }) {
  if (!Array.isArray(indexPages) || indexPages.length < 1) {
    throw new TypeError("indexPages must be a non-empty array of catalog v2 pages");
  }
  if (!(appPages instanceof Map)) throw new TypeError("appPages must be a Map<slug, CatalogAppPageV1>");

  // The pages must be one publish, in order: page n at position n-1, every
  // page agreeing on pageCount and generatedAt. A mix of two publishes (a
  // "torn" upload) is refused rather than shown as one catalog.
  indexPages.forEach((page, position) => {
    const result = validateCatalogIndexV2(page);
    if (!result.ok) throw new TypeError(`catalog index v2 page is invalid: ${result.errors.join("; ")}`);
    if (page.page !== position + 1) throw new TypeError(`catalog index page ${position + 1} is labelled page ${page.page}`);
    if (page.pageCount !== indexPages[0].pageCount || page.generatedAt !== indexPages[0].generatedAt) {
      throw new TypeError(`catalog index page ${page.page} belongs to a different publish than page 1`);
    }
  });
  if (indexPages.length !== indexPages[0].pageCount) {
    throw new TypeError(`catalog index has ${indexPages.length} pages but page 1 says ${indexPages[0].pageCount}`);
  }

  const rows = [];
  const seenSlugs = new Set();
  for (const page of indexPages) {
    for (const entry of page.apps) {
      if (seenSlugs.has(entry.slug)) throw new TypeError(`duplicate catalog app slug across pages: ${entry.slug}`);
      seenSlugs.add(entry.slug);

      // R2-CP-3 (round3-deferred/M-store-screens): index v2's optional
      // `latestRevisionId` passed through unchanged. `undefined` (a row
      // from a publish made before this field existed) and explicit `null`
      // both normalize to `null` here, so every row this function returns
      // has the same three-state shape regardless of which publish it came
      // from; nothing downstream (`resolveCatalogHandoff`,
      // `renderAppsIndexHTML`, `renderCatalogHandoffHTML`) reads it yet,
      // so this is additive only.
      const latestRevisionId = entry.latestRevisionId ?? null;

      const appPage = appPages.get(entry.slug);
      if (appPage === undefined || appPage === null) {
        rows.push({ slug: entry.slug, name: entry.name, mobileShell: null, latestRevisionId });
        continue;
      }
      const appPageResult = validateCatalogAppPageV1(appPage);
      if (!appPageResult.ok) {
        throw new TypeError(`catalog app page ${entry.slug} is invalid: ${appPageResult.errors.join("; ")}`);
      }
      // A row that disagrees with its own app page about the download size
      // or the reviewed age rating is not offered for install: the page
      // would promise something the install path does not deliver.
      const agreement = validateCatalogIndexEntryMatchesAppPage(entry, appPage);
      rows.push({ slug: entry.slug, name: entry.name, mobileShell: agreement.ok ? appPage.mobileShell : null, latestRevisionId });
    }
  }
  return rows;
}

/**
 * Loads a published catalog v2 directory (or site) into catalog rows.
 * `readJSON(path)` resolves the parsed JSON at a path relative to the
 * catalog root ("index.json", "index-2.json", "apps/<slug>.json"), or null
 * when the file does not exist. Page 1 decides how many pages to read; an
 * app page that does not exist makes that app "not available".
 */
export async function loadCatalogV2Rows({ readJSON }) {
  if (typeof readJSON !== "function") throw new TypeError("readJSON is required");
  const first = await readJSON("index.json");
  if (first === null || first === undefined) throw new TypeError("catalog index v2 is not published (index.json is missing)");
  const firstResult = validateCatalogIndexV2(first);
  if (!firstResult.ok) throw new TypeError(`catalog index v2 page is invalid: ${firstResult.errors.join("; ")}`);
  const indexPages = [first];
  for (let page = 2; page <= first.pageCount; page += 1) {
    const next = await readJSON(`index-${page}.json`);
    if (next === null || next === undefined) throw new TypeError(`catalog index page ${page} of ${first.pageCount} is missing`);
    indexPages.push(next);
  }
  const appPages = new Map();
  for (const page of indexPages) {
    for (const entry of Array.isArray(page?.apps) ? page.apps : []) {
      if (typeof entry?.slug !== "string" || !STABLE_ID_PATTERN.test(entry.slug)) continue;
      const appPage = await readJSON(`apps/${entry.slug}.json`);
      if (appPage !== null && appPage !== undefined) appPages.set(entry.slug, appPage);
    }
  }
  return catalogRowsFromIndexV2({ indexPages, appPages });
}

export function resolveCatalogHandoff(catalogRows, selectedSlug) {
  requireStableId(selectedSlug, "selected app slug");
  if (!Array.isArray(catalogRows)) throw new TypeError("catalog rows must be an array");

  let selected = null;
  const seen = new Set();
  for (const row of catalogRows) {
    if (!row || typeof row !== "object" || Array.isArray(row)) throw new TypeError("catalog row is invalid");
    const slug = requireStableId(row.slug, "catalog app slug");
    if (seen.has(slug)) throw new TypeError(`duplicate catalog app slug: ${slug}`);
    seen.add(slug);
    requireDisplayName(row.name);
    if (slug === selectedSlug) selected = row;
  }
  if (!selected) throw new TypeError("selected app is absent from the catalog");

  const canonicalURL = canonicalAppURL(selectedSlug);
  if (selected.mobileShell === null || selected.mobileShell === undefined) {
    return Object.freeze({
      slug: selectedSlug,
      name: selected.name,
      available: false,
      canonicalURL,
      fallbackURL: null,
      mobileShell: null,
      appStoreMetadata: null,
      listingReady: false,
    });
  }

  const mobileShell = validateMobileShellDescriptor(selected.mobileShell);
  return Object.freeze({
    slug: selectedSlug,
    name: selected.name,
    available: true,
    canonicalURL,
    fallbackURL: fallbackInstallURL(selectedSlug),
    mobileShell,
    appStoreMetadata: mobileShell.appStoreMetadata ?? null,
    listingReady: isReadyForAppStoreListing(mobileShell),
  });
}

// A person following the "Open in Iris" link when Iris Apps is not yet on
// this iPhone gets no visible feedback: a custom URL scheme that has no
// registered handler fails silently in Safari (no error, no navigation),
// which a blind test on a real page reported as "the only button did
// nothing, I have no way to get this app today". Until Iris Apps has a
// real App Store or TestFlight link (irisDistributionURL), that fallback
// link is kept (someone who already has Iris Apps installed can still use
// it) but it is never the only, or the first, tappable action on the page:
// the primary action is always something that visibly does something when
// tapped, even if that something is only "ask to be told when this is
// ready" (a mailto: link opens the phone's own Mail app immediately).
function notifyMeHref(appName) {
  const subject = encodeURIComponent(`Let me know when I can get ${appName}`);
  return `mailto:${SUPPORT_EMAIL}?subject=${subject}`;
}

export function renderCatalogHandoffHTML({ catalogRows, selectedSlug, irisDistributionURL = null }) {
  const handoff = resolveCatalogHandoff(catalogRows, selectedSlug);
  const distributionURL = validateAppleDistributionURL(irisDistributionURL);
  const name = htmlEscape(handoff.name);
  const canonicalURL = htmlEscape(handoff.canonicalURL);

  if (!handoff.available) {
    return `<section class="handoff" data-iris-handoff data-app-slug="${htmlEscape(handoff.slug)}" data-iris-available="false">\n`
      + `  <h2>${name} is not available in Iris yet</h2>\n`
      + "  <p>Publik has not published a catalog-bound Iris package for this app.</p>\n"
      + `  <p><a class="btn btn-secondary" data-selected-app-link href="${canonicalURL}">Keep this ${name} link</a></p>\n`
      + "</section>";
  }

  const fallbackURL = htmlEscape(handoff.fallbackURL);
  // Kept for someone who already has Iris Apps on this phone, but always
  // secondary text below the real primary action, never the page's only
  // tappable control (see the note above notifyMeHref).
  const alreadyHaveItHTML = `  <p class="hint">Already have Iris Apps installed? `
    + `<a data-action="open-in-iris" href="${fallbackURL}">Open in Iris</a>.</p>\n`;

  const primaryActionHTML = distributionURL
    ? `  <a class="btn btn-primary" data-action="install-iris" href="${htmlEscape(distributionURL)}">Install Iris</a>\n`
      + `  <p class="hint" data-selected-app-preserved>After installing Iris, return to <a href="${canonicalURL}">this ${name} page</a> to open the same app.</p>\n`
    : '  <p data-install-route="unavailable">Iris Apps is not on the App Store yet, so there is no download link on this page today.</p>\n'
      + `  <a class="btn btn-primary" data-action="notify-me" href="${htmlEscape(notifyMeHref(handoff.name))}">Email Publik to ask about Iris Apps</a>\n`;

  return `<section class="handoff" data-iris-handoff data-app-slug="${htmlEscape(handoff.slug)}" data-iris-available="true">\n`
    + `  <h2>Get ${name}</h2>\n`
    + primaryActionHTML
    + alreadyHaveItHTML
    + `  <p class="hint"><a data-selected-app-link href="${canonicalURL}">Keep this ${name} link</a></p>\n`
    // handoff.name (raw), not the HTML-escaped `name` used for this page's
    // own text/attributes above: appStoreMetadataBlock's mailto subject is
    // plain text, not HTML, so it must carry the real display name (fixed
    // during independent verification of unit m3-guideline47, regression
    // test in review47-report-subject-consistency.test.mjs; previously an
    // app named e.g. "Rock & Roll Tuner" produced a report email subject
    // reading literally "Report: Rock &amp; Roll Tuner").
    + appStoreMetadataBlock(handoff.appStoreMetadata, handoff.name)
    + "</section>";
}

// The metadata's own privacyPolicyUrl is an absolute production URL
// ("https://publikhq.com/iris/privacy"), which is exactly right as data
// (it is what goes into App Store Connect and into the catalog JSON), but
// wrong as a clickable link on this same site: an absolute link back to
// this site's own real hostname leaves whatever host is actually serving
// the current page (localhost while testing, a staging preview, even a
// mirror), the opposite of every other in-page navigation link, which is
// root-relative. A blind test caught this: tapping "Privacy policy" on a
// locally served app page left the local copy entirely and landed on the
// real internet's publikhq.com, which does not (yet) serve this content,
// showing that site's own unrelated 404 page. When the URL is this site's
// own origin, render it as the same root-relative path the header nav
// already uses for Privacy ("/iris/privacy"); an absolute URL to any other
// origin (not used today, but validated for) is left untouched.
function siteRelativeIfSameOrigin(url) {
  return url.startsWith(`${PUBLIK_ORIGIN}/`) ? url.slice(PUBLIK_ORIGIN.length) : url;
}

// Guideline 4.7.1 (privacy + report mechanism) and 4.7.5 (age rating) block.
// Empty string when a descriptor carries no AppStoreMetadataV1 yet, so an
// older descriptor's rendered page is byte-identical to before this feature.
function appStoreMetadataBlock(appStoreMetadata, escapedName) {
  if (!appStoreMetadata) {
    return '  <p data-app-store-listing-ready="false">Age rating and privacy information for this app have not been published yet.</p>\n';
  }
  const summary = htmlEscape(appStoreMetadata.privacySummary);
  const policyURL = htmlEscape(siteRelativeIfSameOrigin(appStoreMetadata.privacyPolicyUrl));
  const reportHref = contactHref(appStoreMetadata.reportContact, escapedName);
  return `  <div class="meta-block">\n`
    + `  <p data-app-store-listing-ready="true"><span class="age-rating-badge" data-age-rating="${appStoreMetadata.ageRating}">Age rating: ${appStoreMetadata.ageRating}+</span></p>\n`
    + `  <p data-privacy-summary>${summary}</p>\n`
    + `  <p><a data-privacy-policy-link href="${policyURL}">Privacy policy</a> &middot; `
    + `<a data-action="report-app" href="${htmlEscape(reportHref)}">Report this app</a></p>\n`
    + `  </div>\n`;
}

function contactHref(contact, escapedName) {
  if (contact.kind === "email") {
    return `mailto:${contact.value}?subject=${encodeURIComponent(`Report: ${escapedName}`)}`;
  }
  return contact.value;
}

/**
 * Guideline 4.7.4: "an index of software and metadata available in your
 * app. It must include universal links that lead to all of the software
 * offered in your app." This renders that index for the website; the
 * native shell's own in-app Browse index is a separate, native-rendered
 * surface (see native/Sources/IrisMobileShellHost/NativeShellCatalogView.swift).
 */
export function renderAppsIndexHTML({ catalogRows }) {
  if (!Array.isArray(catalogRows)) throw new TypeError("catalog rows must be an array");
  const seen = new Set();
  const items = [];
  for (const row of catalogRows) {
    if (!row || typeof row !== "object" || Array.isArray(row)) throw new TypeError("catalog row is invalid");
    const slug = requireStableId(row.slug, "catalog app slug");
    if (seen.has(slug)) throw new TypeError(`duplicate catalog app slug: ${slug}`);
    seen.add(slug);
    requireDisplayName(row.name);
    const handoff = resolveCatalogHandoff(catalogRows, slug);
    const name = htmlEscape(handoff.name);
    const link = htmlEscape(handoff.canonicalURL);
    const ageRating = handoff.appStoreMetadata
      ? `<span data-age-rating="${handoff.appStoreMetadata.ageRating}">${handoff.appStoreMetadata.ageRating}+</span>`
      : '<span data-age-rating-missing="true">Not rated yet</span>';
    items.push(
      `  <li data-app-slug="${htmlEscape(slug)}" data-listing-ready="${handoff.listingReady}">\n`
      + `    <a data-universal-link href="${link}">${name}</a>\n`
      + `    ${ageRating}\n`
      + "  </li>",
    );
  }
  return '<ul data-iris-apps-index>\n' + items.join("\n") + (items.length ? "\n" : "") + "</ul>";
}

export function validateApplicationIdentifier(applicationIdentifier) {
  if (typeof applicationIdentifier !== "string") {
    throw new TypeError("applicationIdentifier must be supplied");
  }
  const parts = applicationIdentifier.split(".");
  const prefix = parts.shift();
  if (!APPLICATION_PREFIX_PATTERN.test(prefix ?? "") || parts.length < 2 || !parts.every((part) => BUNDLE_SEGMENT_PATTERN.test(part))) {
    throw new TypeError("applicationIdentifier must be an exact Apple application identifier");
  }
  return applicationIdentifier;
}

export function generateAASA({ applicationIdentifier } = {}) {
  const appID = validateApplicationIdentifier(applicationIdentifier);
  return Object.freeze({
    applinks: Object.freeze({
      apps: Object.freeze([]),
      details: Object.freeze([
        Object.freeze({
          appID,
          paths: Object.freeze(["/iris/apps/*"]),
        }),
      ]),
    }),
  });
}

export function renderAASAJSON(options) {
  return `${JSON.stringify(generateAASA(options), null, 2)}\n`;
}

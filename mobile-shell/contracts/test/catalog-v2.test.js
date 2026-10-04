import assert from "node:assert/strict";
import test from "node:test";

import {
  APP_STORE_METADATA_KIND,
  DELIVERY_PACKAGE_FORMAT,
  catalogIndexEntryDataBytes,
  validateCatalogAppPageV1,
  validateCatalogIndexEntryMatchesAppPage,
  validateCatalogCategoriesV1,
  validateCatalogIndexV2,
} from "../index.js";

const HEX64 = "a".repeat(64);
const CONTENT_HASH = `sha256:${HEX64}`;
const REVISION_ID = `rev-sha256:${HEX64}`;

function indexApp(overrides = {}) {
  return {
    slug: "focus-timer",
    name: "Focus Timer",
    summary: "Simple timers for study and work",
    categoryIds: [3],
    iconHash: "a1b2c3d4e5f60718",
    iconURL: "https://publikhq.com/i/focus-timer.png",
    byteCount: 1048576,
    ageRating: 4,
    updatedAt: "2026-09-28",
    badges: [],
    placement: null,
    ...overrides,
  };
}

function indexPage(apps, overrides = {}) {
  return {
    version: 2,
    generatedAt: "2026-09-28T00:00:00.000Z",
    page: 1,
    pageCount: 1,
    apps,
    ...overrides,
  };
}

function mobileShell(overrides = {}) {
  return {
    version: 1,
    platform: "ios",
    packageFormat: DELIVERY_PACKAGE_FORMAT,
    downloadUrl: "https://publikhq.com/api/iris/mobile-shell/focus-timer/pkg.json",
    mediaType: "application/json",
    byteCount: 4096,
    packageSha256: `sha256:${"b".repeat(64)}`,
    appId: "publik.focus-timer",
    projectId: "publik.focus-timer.mobile",
    baseRevisionId: null,
    revisionId: REVISION_ID,
    contentHash: CONTENT_HASH,
    appStoreMetadata: null,
    ...overrides,
  };
}

function appPage(overrides = {}) {
  return {
    mobileShell: mobileShell(),
    description: "A simple focus timer for study and deep work sessions.",
    screenshots: [
      { url: "https://publikhq.com/shots/focus-timer/1.png", bytes: 128 * 1024 },
    ],
    permissions: [
      { capability: "native.haptics", label: "Vibrate when a timer ends" },
    ],
    privacySummary: "Focus Timer keeps your session history on this device only.",
    supportURL: "https://focus-timer.example/support",
    whatsNew: "Faster startup and a new sound.",
    ...overrides,
  };
}

// --- index v2 --------------------------------------------------------------

test("valid index v2 page round-trips", () => {
  const result = validateCatalogIndexV2(indexPage([indexApp()]));
  assert.equal(result.ok, true);
});

test("index v2 rejects unknown and missing top-level fields", () => {
  const withExtra = validateCatalogIndexV2({ ...indexPage([indexApp()]), extra: true });
  assert.equal(withExtra.ok, false);
  const { apps, ...missingApps } = indexPage([indexApp()]);
  assert.equal(validateCatalogIndexV2(missingApps).ok, false);
});

test("index v2 rejects more than 250 apps on one page (10,000-app catalog case)", () => {
  const tooMany = Array.from({ length: 251 }, (_, i) => indexApp({ slug: `app-${i}` }));
  assert.equal(validateCatalogIndexV2(indexPage(tooMany)).ok, false);

  // The literal scale the brief calls out: a naive 10,000-app single-page
  // index must be rejected by the same per-page limit, not accepted because
  // some other "total apps" check was skipped.
  const tenThousand = Array.from({ length: 10000 }, (_, i) => indexApp({ slug: `app-${i}` }));
  const result = validateCatalogIndexV2(indexPage(tenThousand, { pageCount: 40 }));
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((e) => e.includes("apps")));
});

test("exactly 250 apps on one page is accepted", () => {
  const apps = Array.from({ length: 250 }, (_, i) => indexApp({ slug: `app-${i}` }));
  assert.equal(validateCatalogIndexV2(indexPage(apps, { pageCount: 1 })).ok, true);
});

test("index v2 rejects a foreign icon host, including a lookalike domain", () => {
  const foreign = validateCatalogIndexV2(
    indexPage([indexApp({ iconURL: "https://publikhq.com.evil.example/i/x.png" })]),
  );
  assert.equal(foreign.ok, false);
  assert.ok(foreign.errors.some((e) => e.includes("iconURL")));

  const nonHttps = validateCatalogIndexV2(indexPage([indexApp({ iconURL: "http://publikhq.com/i/x.png" })]));
  assert.equal(nonHttps.ok, false);

  const withPort = validateCatalogIndexV2(indexPage([indexApp({ iconURL: "https://publikhq.com:8443/i/x.png" })]));
  assert.equal(withPort.ok, false);
});

test("index v2 rejects a path-traversal slug", () => {
  for (const slug of ["../../etc/passwd", "a/../../b", "..", "/etc/passwd", "app/slug"]) {
    const result = validateCatalogIndexV2(indexPage([indexApp({ slug })]));
    assert.equal(result.ok, false, `expected slug to be rejected: ${slug}`);
  }
});

test("index v2 rejects duplicate slugs on one page", () => {
  const result = validateCatalogIndexV2(indexPage([indexApp({ slug: "a" }), indexApp({ slug: "a" })]));
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((e) => e.includes("duplicate")));
});

// Hand count for indexApp() with an n-character ASCII summary, values only
// (the budget never counts field names):
//   "focus-timer" 13, "Focus Timer" 13, summary n+2, [3] 3,
//   "a1b2c3d4e5f60718" 18, "https://publikhq.com/i/focus-timer.png" 40,
//   1048576 7, 4 1, "2026-09-28" 12, [] 2, null 4,
//   10 commas + 2 brackets 12  =>  127 + n bytes.
// So a 73-character summary is exactly 200 bytes and 74 is 201.
test("index v2 enforces the 200-byte per-app budget at the exact boundary", () => {
  const at200 = indexApp({ summary: "s".repeat(73) });
  const at201 = indexApp({ summary: "s".repeat(74) });
  assert.equal(validateCatalogIndexV2(indexPage([at200])).ok, true, "200 bytes of values must be accepted");
  const over = validateCatalogIndexV2(indexPage([at201]));
  assert.equal(over.ok, false, "201 bytes of values must be rejected");
  assert.ok(over.errors.some((e) => e.includes("apps[0] uses 201 bytes") && e.includes("shorten")));
});

test("index v2 budget counts UTF-8 bytes, not characters", () => {
  // 24 euro signs are 72 bytes (3 each): 127 + 72 = 199, accepted.
  // 30 euro signs are only 30 characters (inside the 80-character summary
  // limit) but 90 bytes: 127 + 90 = 217, rejected.
  assert.equal(validateCatalogIndexV2(indexPage([indexApp({ summary: "\u20ac".repeat(24) })])).ok, true);
  const wide = validateCatalogIndexV2(indexPage([indexApp({ summary: "\u20ac".repeat(30) })]));
  assert.equal(wide.ok, false);
  assert.ok(wide.errors.some((e) => e.includes("uses 217 bytes")));
});

test("a row where every field is inside its own limit can still exceed the per-app budget", () => {
  const stuffed = indexApp({
    summary: "x".repeat(80),
    categoryIds: [1, 2, 3],
    badges: ["new", "updated"],
    placement: { featured: true, sponsored: true, label: "Sponsored by a partner" },
  });
  const result = validateCatalogIndexV2(indexPage([stuffed]));
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((e) => e.includes("shorten the summary or name")));
  // A realistic sponsored row (one badge, two categories, the plain
  // "Sponsored" label, a 39-character summary) fits: 197 bytes of values.
  const realistic = {
    ...stuffed,
    summary: "Plan study sessions and keep your focus",
    categoryIds: [1, 2],
    badges: ["updated"],
    placement: { featured: false, sponsored: true, label: "Sponsored" },
  };
  assert.equal(validateCatalogIndexV2(indexPage([realistic])).ok, true);
  // A multi-kilobyte summary is rejected by both the field limit and the budget.
  const absurd = validateCatalogIndexV2(indexPage([indexApp({ summary: "x".repeat(5000) })]));
  assert.equal(absurd.ok, false);
  assert.ok(absurd.errors.some((e) => e.includes("summary")));
});

test("a row that cannot be serialized is rejected instead of crashing the validator", () => {
  const result = validateCatalogIndexV2(indexPage([indexApp({ byteCount: 10n })]));
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((e) => e.includes("byteCount")));
});

test("index v2 rejects a download size the install path would refuse", () => {
  const limit = 48 * 1024 * 1024;
  assert.equal(validateCatalogIndexV2(indexPage([indexApp({ byteCount: limit })])).ok, true);
  const tooBig = validateCatalogIndexV2(indexPage([indexApp({ byteCount: limit + 1 })]));
  assert.equal(tooBig.ok, false);
  assert.ok(tooBig.errors.some((e) => e.includes("byteCount")));
  assert.equal(validateCatalogIndexV2(indexPage([indexApp({ byteCount: 0 })])).ok, false);
});

test("an index row must agree with its app page on size and reviewed age rating", () => {
  const page = appPage();
  const matching = indexApp({ byteCount: page.mobileShell.byteCount });
  assert.equal(validateCatalogIndexEntryMatchesAppPage(matching, page).ok, true);

  const wrongSize = validateCatalogIndexEntryMatchesAppPage(indexApp({ byteCount: 180 * 1024 * 1024 }), page);
  assert.equal(wrongSize.ok, false);
  assert.ok(wrongSize.errors.some((e) => e.includes("package size 4096")));

  const rated = appPage({
    mobileShell: mobileShell({
      appStoreMetadata: {
        kind: APP_STORE_METADATA_KIND,
        version: 1,
        ageRating: 16,
        privacySummary: "No data leaves this device.",
        privacyPolicyUrl: "https://publikhq.com/legal/privacy",
        supportContact: { kind: "email", value: "support@publikhq.com" },
        reportContact: { kind: "email", value: "report@publikhq.com" },
      },
    }),
  });
  const youngerInIndex = validateCatalogIndexEntryMatchesAppPage(
    indexApp({ byteCount: rated.mobileShell.byteCount, ageRating: 4 }),
    rated,
  );
  assert.equal(youngerInIndex.ok, false, "the store must not advertise 4+ for an app reviewed as 16+");
  assert.equal(
    validateCatalogIndexEntryMatchesAppPage(indexApp({ byteCount: rated.mobileShell.byteCount, ageRating: 16 }), rated).ok,
    true,
  );
});

test("index v2 rejects malformed categoryIds, ageRating, badges, iconHash", () => {
  assert.equal(validateCatalogIndexV2(indexPage([indexApp({ categoryIds: [] })])).ok, false);
  assert.equal(validateCatalogIndexV2(indexPage([indexApp({ categoryIds: [1, 1] })])).ok, false);
  assert.equal(validateCatalogIndexV2(indexPage([indexApp({ categoryIds: [1, 2, 3, 4] })])).ok, false);
  assert.equal(validateCatalogIndexV2(indexPage([indexApp({ ageRating: 21 })])).ok, false);
  assert.equal(validateCatalogIndexV2(indexPage([indexApp({ badges: ["exploit"] })])).ok, false);
  assert.equal(validateCatalogIndexV2(indexPage([indexApp({ badges: ["new", "new"] })])).ok, false);
  assert.equal(validateCatalogIndexV2(indexPage([indexApp({ iconHash: "not-hex!!" })])).ok, false);
  assert.equal(validateCatalogIndexV2(indexPage([indexApp({ iconHash: `sha256:${HEX64}` })])).ok, false);
});

test("index v2 requires a placement label exactly when featured or sponsored", () => {
  const missingLabel = indexApp({ placement: { featured: true, sponsored: false, label: "" } });
  assert.equal(validateCatalogIndexV2(indexPage([missingLabel])).ok, false);
  const withLabel = indexApp({ placement: { featured: true, sponsored: false, label: "Featured" } });
  assert.equal(validateCatalogIndexV2(indexPage([withLabel])).ok, true);
  const allFalseObject = indexApp({ placement: { featured: false, sponsored: false, label: "" } });
  assert.equal(validateCatalogIndexV2(indexPage([allFalseObject])).ok, false);
});

// R2-CP-3 (round3-deferred/M-store-screens): optional index-row
// `latestRevisionId`, so My apps can show "Update available" without
// fetching the app's own page. Backward compatible in both directions: a
// row with the key absent (an index published before this field existed)
// validates exactly as before, and a row that sets it must carry a real
// `rev-sha256:...` shape.
test("index v2 accepts a row with no latestRevisionId at all (backward compatible)", () => {
  const row = indexApp();
  assert.equal("latestRevisionId" in row, false);
  assert.equal(validateCatalogIndexV2(indexPage([row])).ok, true);
});

test("index v2 accepts latestRevisionId as null (not known yet)", () => {
  assert.equal(validateCatalogIndexV2(indexPage([indexApp({ latestRevisionId: null })])).ok, true);
});

test("index v2 accepts a real revision id in latestRevisionId", () => {
  const row = indexApp({ latestRevisionId: REVISION_ID });
  const result = validateCatalogIndexV2(indexPage([row]));
  assert.equal(result.ok, true, result.errors?.join("; "));
});

test("index v2 rejects an arbitrary string in latestRevisionId, not just a wrong shape", () => {
  for (const bad of ["not-a-revision-id", "rev-sha256:tooshort", `sha256:${HEX64}`, 12345, ""]) {
    assert.equal(
      validateCatalogIndexV2(indexPage([indexApp({ latestRevisionId: bad })])).ok,
      false,
      `latestRevisionId ${JSON.stringify(bad)} must be rejected`,
    );
  }
});

test("index v2 still rejects a genuinely unknown field alongside a valid latestRevisionId", () => {
  const row = indexApp({ latestRevisionId: REVISION_ID, notARealField: true });
  assert.equal(validateCatalogIndexV2(indexPage([row])).ok, false);
});

// RC-05 (round 6): optional index-row `publisher`, so the app page and the
// consent sheet can say who made the app. Backward compatible: absent is valid.
test("index v2 accepts a row with no publisher at all (older index)", () => {
  const row = indexApp();
  assert.equal("publisher" in row, false);
  assert.equal(validateCatalogIndexV2(indexPage([row])).ok, true);
});

test("index v2 accepts a plain publisher name", () => {
  for (const good of ["Publik", "Acme Studio Ltd.", "Zoë & Co", "A".repeat(80)]) {
    const result = validateCatalogIndexV2(indexPage([indexApp({ publisher: good })]));
    assert.equal(result.ok, true, `${good}: ${result.errors?.join("; ")}`);
  }
});

test("index v2 rejects a publisher that is blank, padded, too long, multi-line, markup or not a string", () => {
  for (const bad of ["", " ", " Publik", "Publik ", "A".repeat(81), "Pub\nlik", "Pub\tlik", "<b>Publik</b>", "Pub\u0000lik", "Pub\u200Elik\u0085", 7, null]) {
    assert.equal(
      validateCatalogIndexV2(indexPage([indexApp({ publisher: bad })])).ok,
      false,
      `publisher ${JSON.stringify(bad)} must be rejected`,
    );
  }
});

test("a publisher does not count toward the 200 byte row budget (an extra optional key)", () => {
  const plain = indexApp();
  const named = indexApp({ publisher: "Publik" });
  assert.equal(catalogIndexEntryDataBytes(named), catalogIndexEntryDataBytes(plain));
});

test("index v2 rejects page out of range for its own pageCount", () => {
  assert.equal(validateCatalogIndexV2(indexPage([indexApp()], { page: 2, pageCount: 1 })).ok, false);
  assert.equal(validateCatalogIndexV2(indexPage([indexApp()], { page: 0, pageCount: 1 })).ok, false);
});

test("index v2 rejects a non-canonical generatedAt instant and a non-date updatedAt", () => {
  assert.equal(validateCatalogIndexV2(indexPage([indexApp()], { generatedAt: "not-a-date" })).ok, false);
  assert.equal(validateCatalogIndexV2(indexPage([indexApp()], { generatedAt: "2026-09-28" })).ok, false);
  for (const updatedAt of ["2026-09-28T00:00:00.000Z", "2026-02-30", "2026-9-28", "28/09/2026", "", 20260928]) {
    assert.equal(validateCatalogIndexV2(indexPage([indexApp({ updatedAt })])).ok, false, `updatedAt ${updatedAt}`);
  }
  assert.equal(validateCatalogIndexV2(indexPage([indexApp({ updatedAt: "2024-02-29" })])).ok, true, "leap day");
});

// --- categories.json ---------------------------------------------------

test("valid categories round-trip and reject more than 24", () => {
  const ok24 = Array.from({ length: 24 }, (_, i) => ({ id: i + 1, name: `Cat ${i}`, order: i, appCount: 0 }));
  assert.equal(validateCatalogCategoriesV1({ categories: ok24 }).ok, true);
  const over = Array.from({ length: 25 }, (_, i) => ({ id: i + 1, name: `Cat ${i}`, order: i, appCount: 0 }));
  assert.equal(validateCatalogCategoriesV1({ categories: over }).ok, false);
});

test("categories reject duplicate ids and malformed fields", () => {
  const dup = [
    { id: 1, name: "A", order: 0, appCount: 0 },
    { id: 1, name: "B", order: 1, appCount: 0 },
  ];
  assert.equal(validateCatalogCategoriesV1({ categories: dup }).ok, false);
  assert.equal(validateCatalogCategoriesV1({ categories: [{ id: 0, name: "A", order: 0, appCount: 0 }] }).ok, false);
  assert.equal(validateCatalogCategoriesV1({ categories: [{ id: 1, name: "", order: 0, appCount: 0 }] }).ok, false);
  assert.equal(validateCatalogCategoriesV1({ categories: [{ id: 1, name: "A", order: -1, appCount: 0 }] }).ok, false);
});

// --- apps/<slug>.json ----------------------------------------------------

test("valid app page round-trips including appStoreMetadata", () => {
  const page = appPage({
    mobileShell: mobileShell({
      appStoreMetadata: {
        kind: APP_STORE_METADATA_KIND,
        version: 1,
        ageRating: 4,
        privacySummary: "No data leaves this device.",
        privacyPolicyUrl: "https://publikhq.com/legal/privacy",
        supportContact: { kind: "email", value: "support@publikhq.com" },
        reportContact: { kind: "email", value: "report@publikhq.com" },
      },
    }),
  });
  assert.equal(validateCatalogAppPageV1(page).ok, true);
});

test("app page rejects a mobileShell/revisionId content-hash mismatch", () => {
  const page = appPage({ mobileShell: mobileShell({ revisionId: `rev-sha256:${"c".repeat(64)}` }) });
  assert.equal(validateCatalogAppPageV1(page).ok, false);
});

test("app page rejects more than 6 screenshots and an oversized/foreign screenshot", () => {
  const seven = Array.from({ length: 7 }, (_, i) => ({ url: `https://publikhq.com/shots/${i}.png`, bytes: 1024 }));
  assert.equal(validateCatalogAppPageV1(appPage({ screenshots: seven })).ok, false);

  const oversized = appPage({ screenshots: [{ url: "https://publikhq.com/shots/1.png", bytes: 401 * 1024 }] });
  assert.equal(validateCatalogAppPageV1(oversized).ok, false);

  const foreignHost = appPage({ screenshots: [{ url: "https://evil.example/shots/1.png", bytes: 1024 }] });
  assert.equal(validateCatalogAppPageV1(foreignHost).ok, false);
});

test("app page rejects an unknown permission capability", () => {
  const page = appPage({ permissions: [{ capability: "native.filesystem", label: "Read every file" }] });
  assert.equal(validateCatalogAppPageV1(page).ok, false);
});

test("app page allows a null whatsNew but rejects an oversized one", () => {
  assert.equal(validateCatalogAppPageV1(appPage({ whatsNew: null })).ok, true);
  assert.equal(validateCatalogAppPageV1(appPage({ whatsNew: "x".repeat(3000) })).ok, false);
});

test("app page rejects a non-https or javascript-scheme supportURL", () => {
  assert.equal(validateCatalogAppPageV1(appPage({ supportURL: "javascript:alert(1)" })).ok, false);
  assert.equal(validateCatalogAppPageV1(appPage({ supportURL: "http://example.com" })).ok, false);
});

test("app page rejects unknown top-level fields (fail closed on schema drift)", () => {
  assert.equal(validateCatalogAppPageV1({ ...appPage(), extraField: 1 }).ok, false);
});

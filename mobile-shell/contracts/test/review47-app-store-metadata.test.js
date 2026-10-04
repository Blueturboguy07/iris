// New test file for unit m3-guideline47 (App Store Guideline 4.7 obligations).
// Do not add App Store metadata assertions to contracts.test.js; this file
// owns validateAppStoreMetadataV1 and its constants exclusively.
import assert from "node:assert/strict";
import test from "node:test";

import {
  APP_STORE_METADATA_KIND,
  APP_STORE_METADATA_LIMITS,
  APP_STORE_METADATA_VERSION,
  KNOWN_AGE_RATINGS,
  validateAppStoreMetadataV1,
} from "../index.js";

function metadata(overrides = {}) {
  return {
    kind: APP_STORE_METADATA_KIND,
    version: APP_STORE_METADATA_VERSION,
    ageRating: 4,
    privacySummary: "Nut AI keeps meal logs on this device only.",
    privacyPolicyUrl: "https://publikhq.com/legal/privacy",
    supportContact: { kind: "email", value: "support@publikhq.com" },
    reportContact: { kind: "email", value: "report@publikhq.com" },
    ...overrides,
  };
}

test("every known Apple age rating tier is accepted", () => {
  assert.deepEqual(KNOWN_AGE_RATINGS, [4, 9, 13, 16, 18]);
  for (const ageRating of KNOWN_AGE_RATINGS) {
    const result = validateAppStoreMetadataV1(metadata({ ageRating }));
    assert.equal(result.ok, true, `ageRating ${ageRating} should validate`);
  }
});

test("a rating outside Apple's current tiers is rejected, not silently rounded", () => {
  for (const ageRating of [0, 3, 12, 17, 18.5, "4", "4+", null]) {
    const result = validateAppStoreMetadataV1(metadata({ ageRating }));
    assert.equal(result.ok, false, `ageRating ${JSON.stringify(ageRating)} must be rejected`);
    assert.ok(result.errors.some((message) => message.includes("ageRating")));
  }
});

test("a url-kind contact accepts only an exact https URL with no injected markup", () => {
  const good = validateAppStoreMetadataV1(metadata({
    reportContact: { kind: "url", value: "https://publikhq.com/report" },
  }));
  assert.equal(good.ok, true);

  const hostile = [
    "http://publikhq.com/report", // not https
    "javascript:alert(1)", // dangerous scheme
    "data:text/html,<script>alert(1)</script>", // dangerous scheme
    "https://publikhq.com/\"><script>alert(1)</script>", // raw markup characters
    "https://attacker.example/report", // still just a URL: contracts do not pin the host, Core/website pin publikhq.com separately
  ];
  for (const value of hostile.slice(0, 4)) {
    const result = validateAppStoreMetadataV1(metadata({ reportContact: { kind: "url", value } }));
    assert.equal(result.ok, false, `expected rejection for ${value}`);
  }
  // The contract layer intentionally does not pin publikhq.com (Core and the
  // website each pin their own allowed origins); it only rejects unsafe form.
  const offSite = validateAppStoreMetadataV1(metadata({
    reportContact: { kind: "url", value: hostile[4] },
  }));
  assert.equal(offSite.ok, true);
});

test("a huge privacySummary or contact value is rejected, not truncated", () => {
  const overSummary = "a".repeat(APP_STORE_METADATA_LIMITS.maxPrivacySummaryChars + 1);
  const atLimitSummary = "a".repeat(APP_STORE_METADATA_LIMITS.maxPrivacySummaryChars);
  assert.equal(validateAppStoreMetadataV1(metadata({ privacySummary: overSummary })).ok, false);
  assert.equal(validateAppStoreMetadataV1(metadata({ privacySummary: atLimitSummary })).ok, true);

  const overContact = "a@" + "b".repeat(APP_STORE_METADATA_LIMITS.maxContactValueChars) + ".com";
  const result = validateAppStoreMetadataV1(metadata({
    supportContact: { kind: "email", value: overContact },
  }));
  assert.equal(result.ok, false);
});

test("control characters in a display string are rejected, including a newline injection", () => {
  for (const bad of ["line one\nline two", "tab\there", "\u0000null-byte", "\u007fdel"]) {
    const result = validateAppStoreMetadataV1(metadata({ privacySummary: bad }));
    assert.equal(result.ok, false, `expected rejection for ${JSON.stringify(bad)}`);
  }
});

test("an email contact rejects malformed addresses without crashing", () => {
  for (const value of ["not-an-email", "a@b", "a b@example.com", "a@@example.com", ""]) {
    const result = validateAppStoreMetadataV1(metadata({ supportContact: { kind: "email", value } }));
    assert.equal(result.ok, false, `expected rejection for ${JSON.stringify(value)}`);
  }
});

test("an unknown contact kind is rejected", () => {
  const result = validateAppStoreMetadataV1(metadata({
    supportContact: { kind: "phone", value: "+1-555-0100" },
  }));
  assert.equal(result.ok, false);
  assert.ok(result.errors.some((message) => message.includes("supportContact.kind")));
});

test("exact keys: an unknown top-level field and a missing required field are both rejected", () => {
  const withExtra = validateAppStoreMetadataV1({ ...metadata(), extra: "field" });
  assert.equal(withExtra.ok, false);
  assert.ok(withExtra.errors.some((message) => message.includes("extra")));

  const { privacyPolicyUrl, ...withoutPolicy } = metadata();
  const missing = validateAppStoreMetadataV1(withoutPolicy);
  assert.equal(missing.ok, false);
  assert.ok(missing.errors.some((message) => message.includes("privacyPolicyUrl")));
});

test("a wrong kind/version, or a non-object value, is rejected rather than throwing", () => {
  assert.equal(validateAppStoreMetadataV1(metadata({ kind: "something-else" })).ok, false);
  assert.equal(validateAppStoreMetadataV1(metadata({ version: 2 })).ok, false);
  for (const hostile of [null, undefined, 42, "string", [], []]) {
    assert.doesNotThrow(() => validateAppStoreMetadataV1(hostile));
    assert.equal(validateAppStoreMetadataV1(hostile).ok, false);
  }
});

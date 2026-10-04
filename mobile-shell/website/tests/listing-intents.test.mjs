import assert from "node:assert/strict";
import test from "node:test";
import { parseAppIntentURL, resolveCatalogHandoff } from "../integration.mjs";

test("the actual public app-page URLs preserve the selected slug", () => {
  for (const slug of ["kneecap", "freeharmony", "lunara"]) {
    const url = `https://publikhq.com/${slug}`;
    assert.deepEqual(parseAppIntentURL(url), { kind: "listing", slug, url });
  }
});

test("a listing intent cannot smuggle a package, credential, path, or other origin", () => {
  const rejected = [
    "http://publikhq.com/kneecap",
    "https://www.publikhq.com/kneecap",
    "https://publikhq.com.evil.example/kneecap",
    "https://publikhq.com:443/kneecap",
    "https://@publikhq.com/kneecap",
    "https://user@publikhq.com/kneecap",
    "https://publikhq.com/kneecap/",
    "https://publikhq.com/kneecap/install/mac-iphone",
    "https://publikhq.com/kneecap?package=https://evil.example/a.irisapp",
    "https://publikhq.com/kneecap?approve=1",
    "https://publikhq.com/kneecap?",
    "https://publikhq.com/kneecap#approve",
    "https://publikhq.com/kneecap#",
    "https://publikhq.com/%6Bneecap",
    "https://publikhq.com/kneecap%2Fextra",
    "https://publikhq.com/other/../kneecap",
    "https://publikhq.com/./kneecap",
    "https://publikhq.com//kneecap",
    "https://publikhq.com/",
    "https://github.com/Blueturboguy07/kneecap",
    "iris://guide/kneecap?version=5&branch=macos:ios&step=0",
  ];
  for (const value of rejected) {
    assert.throws(() => parseAppIntentURL(value), TypeError, value);
  }
});

test("a published repository link is not a published mobile package", () => {
  const intent = parseAppIntentURL("https://publikhq.com/kneecap");
  const handoff = resolveCatalogHandoff([{
    slug: "kneecap",
    name: "kneecap",
    guideSlug: "kneecap",
    repositoryUrl: "https://github.com/Blueturboguy07/kneecap",
  }], intent.slug);
  assert.equal(handoff.available, false);
  assert.equal(handoff.mobileShell, null);
  assert.equal(handoff.fallbackURL, null);
});

test("a single-segment website route still has to resolve to a catalog app", () => {
  const intent = parseAppIntentURL("https://publikhq.com/not-a-catalog-app");
  assert.throws(() => resolveCatalogHandoff([], intent.slug), /absent from the catalog/);
});

import assert from "node:assert/strict";
import test from "node:test";

import {
  generateAASA,
  renderAASAJSON,
  renderCatalogHandoffHTML,
  resolveCatalogHandoff,
  validateAppleDistributionURL,
} from "../integration.mjs";

const CONTENT_HEX = "a".repeat(64);

function availableRow(overrides = {}) {
  const row = {
    slug: "lunara",
    name: "Lunara",
    guideSlug: "lunara",
    macBundleId: null,
    latestReleaseTag: null,
    mobileShell: {
      version: 1,
      platform: "ios",
      packageFormat: "iris.mobile-shell.package+json",
      downloadUrl: "https://publikhq.com/artifacts/lunara.irisapp",
      mediaType: "application/json",
      byteCount: 1346428,
      packageSha256: `sha256:${"b".repeat(64)}`,
      appId: "publik.lunara",
      projectId: "publik.lunara.mobile",
      baseRevisionId: null,
      revisionId: `rev-sha256:${CONTENT_HEX}`,
      contentHash: `sha256:${CONTENT_HEX}`,
    },
  };
  return {
    ...row,
    ...overrides,
    mobileShell: overrides.mobileShell === undefined
      ? row.mobileShell
      : overrides.mobileShell,
  };
}

function withDescriptor(overrides) {
  const row = availableRow();
  return availableRow({ mobileShell: { ...row.mobileShell, ...overrides } });
}

test("descriptor identity, hash, base, and revision fields fail closed when malformed", () => {
  const cases = [
    [withDescriptor({ appId: "Publik.lunara" }), /mobileShell\.appId is invalid/],
    [withDescriptor({ projectId: "publik/lunara/mobile" }), /mobileShell\.projectId is invalid/],
    [withDescriptor({ packageSha256: `sha256:${"b".repeat(63)}` }), /mobileShell\.packageSha256 is invalid/],
    [withDescriptor({ contentHash: `sha256:${"A".repeat(64)}` }), /mobileShell\.contentHash is invalid/],
    [withDescriptor({ baseRevisionId: `rev-sha256:${"z".repeat(64)}` }), /mobileShell\.baseRevisionId is invalid/],
    [withDescriptor({ revisionId: `rev-sha256:${"c".repeat(64)}` }), /revision\/content binding is invalid/],
  ];

  for (const [row, expected] of cases) {
    assert.throws(() => resolveCatalogHandoff([row], "lunara"), expected);
  }
});

test("artifact download URL rejects explicit default port that native URLComponents preserves", () => {
  const row = withDescriptor({
    downloadUrl: "https://publikhq.com:443/artifacts/lunara.irisapp",
  });
  assert.throws(
    () => resolveCatalogHandoff([row], "lunara"),
    /direct https:\/\/publikhq\.com/,
  );
});

test("artifact download URL rejects empty userinfo marker that native URLComponents preserves", () => {
  const row = withDescriptor({
    downloadUrl: "https://@publikhq.com/artifacts/lunara.irisapp",
  });
  assert.throws(
    () => resolveCatalogHandoff([row], "lunara"),
    /direct https:\/\/publikhq\.com/,
  );
});

test("website validation does not invent an appId/projectId naming convention beyond native stable-id parity", () => {
  const row = withDescriptor({
    appId: "publisher.product.identity",
    projectId: "publisher.project.identity",
  });
  const handoff = resolveCatalogHandoff([row], "lunara");
  assert.equal(handoff.available, true);
  assert.equal(handoff.mobileShell.appId, "publisher.product.identity");
  assert.equal(handoff.mobileShell.projectId, "publisher.project.identity");
});

test("duplicate catalog slugs are rejected instead of selecting an ambiguous row", () => {
  const duplicate = availableRow({ name: "Different Lunara", mobileShell: null });
  assert.throws(
    () => resolveCatalogHandoff([availableRow(), duplicate], "lunara"),
    /duplicate catalog app slug: lunara/,
  );
});

test("unknown descriptor and catalog properties are ignored like Swift Decodable unknown keys", () => {
  const row = withDescriptor({
    futureDescriptorVersionHint: { nested: true },
    source: "https://evil.example/source",
    license: "<script>alert(1)</script>",
    href: "javascript:alert(1)",
  });
  row.display = `<img src=x onerror="alert(2)">`;
  row.source = "javascript:alert(3)";
  row.license = "<svg/onload=alert(4)>";
  row.href = "javascript:alert(5)";

  const handoff = resolveCatalogHandoff([row], "lunara");
  assert.equal(handoff.available, true);
  assert.equal(handoff.mobileShell.futureDescriptorVersionHint.nested, true);

  const html = renderCatalogHandoffHTML({ catalogRows: [row], selectedSlug: "lunara" });
  assert.doesNotMatch(html, /evil\.example|javascript:|<script|<svg|<img/);
  assert.match(html, /href="iris-apps:\/\/install\/lunara"/);
  assert.match(html, /href="https:\/\/publikhq\.com\/iris\/apps\/lunara"/);
});

test("malicious catalog display name is escaped while unused href/source/license fields never become markup", () => {
  const row = availableRow({
    name: `Lunara <a href="javascript:alert('name')">bad</a> & Co`,
    href: "javascript:alert('href')",
    source: `"><script>alert('source')</script>`,
    license: `"><img src=x onerror="alert('license')">`,
  });
  const html = renderCatalogHandoffHTML({ catalogRows: [row], selectedSlug: "lunara" });
  assert.doesNotMatch(html, /<script|<img|<a href="javascript:/);
  assert.doesNotMatch(html, /javascript:alert\('href'\)|alert\('source'\)|alert\('license'\)/);
  assert.match(html, /Lunara &lt;a href=&quot;javascript:alert\(&#39;name&#39;\)&quot;&gt;bad&lt;\/a&gt; &amp; Co/);
});

test("distribution URLs reject non-HTTPS, userinfo, fragments, and query strings", () => {
  const bad = [
    "http://apps.apple.com/us/app/iris/id1234567890",
    "https://attacker@apps.apple.com/us/app/iris/id1234567890",
    "https://apps.apple.com/us/app/iris/id1234567890#fragment",
    "https://apps.apple.com/us/app/iris/id1234567890?pt=1&ct=site",
    "https://testflight.apple.com/join/Ab12Cd34?source=site",
  ];
  for (const value of bad) {
    assert.throws(() => validateAppleDistributionURL(value), TypeError, value);
  }
});

test("distribution URL rejects explicit default port instead of accepting URL normalization", () => {
  assert.throws(
    () => validateAppleDistributionURL("https://apps.apple.com:443/us/app/iris/id1234567890"),
    /direct Apple HTTPS URL/,
  );
});

test("distribution URL rejects empty userinfo marker instead of accepting URL normalization", () => {
  assert.throws(
    () => validateAppleDistributionURL("https://@apps.apple.com/us/app/iris/id1234567890"),
    /direct Apple HTTPS URL/,
  );
});

test("unavailable catalog app renders no Open in Iris or Install Iris action", () => {
  const row = availableRow({ mobileShell: null });
  const html = renderCatalogHandoffHTML({
    catalogRows: [row],
    selectedSlug: "lunara",
    irisDistributionURL: "https://apps.apple.com/us/app/iris/id1234567890",
  });
  assert.match(html, /data-iris-available="false"/);
  assert.doesNotMatch(html, /data-action="open-in-iris"/);
  assert.doesNotMatch(html, /data-action="install-iris"/);
  assert.doesNotMatch(html, /iris-apps:\/\/install\/lunara/);
});

test("AASA output uses exactly the provided application identifier and the minimal Iris path", () => {
  const applicationIdentifier = "R5R3ZS54LV.com.publikhq.iris.mobileshell";
  const aasa = generateAASA({ applicationIdentifier });
  assert.deepEqual(Object.keys(aasa), ["applinks"]);
  assert.deepEqual(Object.keys(aasa.applinks).sort(), ["apps", "details"]);
  assert.deepEqual(aasa.applinks.apps, []);
  assert.deepEqual(aasa.applinks.details, [
    { appID: applicationIdentifier, paths: ["/iris/apps/*"] },
  ]);
  const json = renderAASAJSON({ applicationIdentifier });
  assert.equal((json.match(/R5R3ZS54LV\.com\.publikhq\.iris\.mobileshell/g) ?? []).length, 1);
  assert.equal((json.match(/\/iris\/apps\/\*/g) ?? []).length, 1);
  assert.doesNotMatch(json, /webcredentials|activitycontinuation|components|\*\.publikhq\.com/);
});

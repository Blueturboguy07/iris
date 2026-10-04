# Iris mobile shell contract v1

Status: shared implementation contract. This is not a claim that a native shell has shipped, that a PWA has been deployed, or that a revision has been installed on a physical phone.

## Stable import surface

JavaScript owners import only from:

```js
import {
  CONTRACT_VERSION,
  DELIVERY_PACKAGE_FORMAT,
  DELIVERY_PACKAGE_LIMITS,
  KNOWN_CAPABILITIES,
  validateManifestV1,
  validateRevisionV1,
  validateEditRequestV1,
  validateDeliveryApprovalV1,
  validateDeliveryEnvelopeV1,
  validateDeliveryPackageV1,
  evaluateShellCompatibility,
  verifyRevisionIntegrity,
  verifyDeliveryPackageV1,
  createRevisionIdentity,
  validateAppStoreMetadataV1,
  KNOWN_AGE_RATINGS,
} from "/mobile-shell/contracts/index.js";
```

TypeScript/JSDoc consumers use `/mobile-shell/contracts/index.d.ts`. The package has no runtime dependencies and uses browser-standard APIs only (`URL`, `TextEncoder`, Web Crypto `SubtleCrypto`). Node is only the test runner.

## Core invariants

1. **One installed shell, immutable content revisions.** Editable app content is a revision. The native/PWA shell is a separately reviewed runtime. A content update does not replace the shell binary.
2. **Provenance is carried, never guessed.** Every object binds `appId` + `projectId`; every edit and delivery pins a `baseRevisionId`.
3. **Integrity is content-addressed.** Every file has a SHA-256 digest; a revision content hash covers its manifest and complete sorted file table; `revisionId` is derived from that hash.
4. **User data is not revision content.** Mutable user media/preferences/databases live under the shell's data namespace and are never members of the revision file table. Installing or rolling back content must not erase them.
5. **Capabilities are requests, not grants.** A manifest can request only the static allowlist below. A shell separately decides support and stores the reader's grant. No manifest, iframe message, or downloaded script may grant itself a native API.
6. **A phone edit request is intent, not shell access.** It contains natural-language intent plus stable identity/base/nonce fields. v1 has no command, script, argv, environment, path-to-write, or arbitrary tool field.
7. **Approval and delivery are distinct records.** An approval binds one request/base to one immutable revision/hash. A delivery envelope references that approval and adds a distinct delivery nonce. Receiving bytes is not approval; approval is not proof the bytes were delivered or activated.
8. **Fail closed on mismatch.** Wrong app/project/base, replayed nonce, unknown capability, incompatible shell, invalid path, hash mismatch, or malformed object is rejection, not a best-effort install.

## Identifiers

- `appId`: stable product id, lowercase reverse-DNS or slug-like ASCII, 1–128 chars. Example `publik.kneecap`.
- `projectId`: stable editable-project id, same lexical rules as `appId`, independent of display name or filesystem path.
- `revisionId`: `rev-sha256:<64 lowercase hex>`, derived from `contentHash`.
- `baseRevisionId`: revision the editor/delivery was based on. `null` is allowed only for a project's first revision.
- `requestId`, `approvalId`, `envelopeId`: opaque printable identifiers, 8–160 chars. They are correlation ids, not authentication secrets.
- `nonce`, `requestNonce`, `deliveryNonce`: 128-bit-or-stronger caller-generated opaque tokens represented as 32–256 lowercase hex/base64url-safe characters. Consumers persist used nonces to reject replay.

## `MobileShellManifestV1`

```js
{
  kind: "iris.mobile-shell.manifest",
  version: 1,
  appId: "publik.kneecap",
  projectId: "publik.kneecap.mobile",
  displayName: "Kneecap",
  runtime: {
    type: "web",
    entrypoint: "index.html",
    minShellVersion: "1.0.0"
  },
  capabilities: ["web.storage"],
  data: {
    namespace: "publik.kneecap",
    updatePolicy: "preserve"
  }
}
```

Required fields are exact in v1; validators reject unknown top-level/runtime/data fields so a new security-relevant field cannot be silently ignored by an older host.

`runtime.type` is only `web` in v1. That is deliberate: editable/downloaded native executable code is outside this contract. `entrypoint` is a safe package-relative path and must identify a file in the revision.

`data.updatePolicy` is only `preserve` in v1. A future destructive migration needs a new reviewed contract version rather than a manifest flag that can silently wipe user data.

## Static capability allowlist

Recognized v1 capability names:

```text
web.storage
web.network.same-origin
web.navigation.external
web.media.camera
web.media.export
web.media.microphone
web.media.photo-picker
native.share
native.haptics
native.camera
native.microphone
native.photo-library
```

Recognition is not support and not consent. `evaluateShellCompatibility` requires every requested capability to appear in the host's declared `supportedCapabilities`. A reviewed native host must additionally obtain whatever reader/platform permission is required before exposing a `native.*` capability. The editable app never receives a generic native bridge.

`web.media.export` declares intent to save app-produced media through a bounded,
user-controlled destination picker. It is distinct from arbitrary file access,
remote downloading, `native.share`, and broad photo-library access. Recognizing
the name does not enable it in an older or unimplemented Host: its capability
policy still must explicitly support it. The verified revision binds the
declaration; an update without it does not inherit it. Native download/picker
execution is a separate acceptance gate from publisher/package validation.

## `MobileShellRevisionV1`

```js
{
  kind: "iris.mobile-shell.revision",
  version: 1,
  appId: "publik.kneecap",
  projectId: "publik.kneecap.mobile",
  revisionId: "rev-sha256:<hex>",
  baseRevisionId: "rev-sha256:<hex>" | null,
  manifestHash: "sha256:<hex>",
  contentHash: "sha256:<hex>",
  createdAt: "2026-09-16T23:00:00.000Z",
  manifest: MobileShellManifestV1,
  files: [
    { path: "index.html", sha256: "sha256:<hex>", bytes: 1234, mediaType: "text/html" }
  ]
}
```

The complete file table is sorted by `path` for identity. Duplicate paths, unsafe relative paths, non-SHA-256 digests, negative/unsafe sizes, a manifest/app/project mismatch, an entrypoint absent from `files`, or a revision id not derived from `contentHash` are invalid.

`contentHash` covers `appId`, `projectId`, `baseRevisionId`, canonical manifest content, and the sorted file metadata (`path`, `sha256`, `bytes`, `mediaType`). `createdAt` is audit metadata and is intentionally excluded: identical content on the same base has the same revision identity.

## `MobileShellEditRequestV1`

```js
{
  kind: "iris.mobile-shell.edit-request",
  version: 1,
  requestId: "req_...",
  nonce: "...",
  appId: "publik.kneecap",
  projectId: "publik.kneecap.mobile",
  baseRevisionId: "rev-sha256:<hex>",
  requestedAt: "2026-09-16T23:00:00.000Z",
  intent: {
    type: "feature" | "bugfix",
    text: "Make the trim handles easier to grab"
  }
}
```

This is the only phone-to-editor mutation request in v1. It is deliberately strict and rejects extra fields. In particular, `command`, `script`, `shell`, `argv`, `environment`, `cwd`, `writeFile`, and arbitrary tool payloads are not part of the language.

The desktop edit authority must re-check provenance and verify that `baseRevisionId` is still the project's installed/approved base before starting. The nonce is single-use for that `appId` + `projectId` + base tuple.

## `MobileShellDeliveryApprovalV1`

Approval is a separate record owned by the trusted edit/delivery authority:

```js
{
  kind: "iris.mobile-shell.delivery-approval",
  version: 1,
  approvalId: "approval_...",
  requestId: "req_..." | null,
  requestNonce: "..." | null,
  appId: "publik.kneecap",
  projectId: "publik.kneecap.mobile",
  baseRevisionId: "rev-sha256:<hex>" | null,
  approvedRevisionId: "rev-sha256:<hex>",
  approvedContentHash: "sha256:<hex>",
  approvedAt: "2026-09-16T23:00:00.000Z"
}
```

For a phone-originated edit, `requestId` and `requestNonce` are both required and must exactly match the validated edit request. For a desktop-originated edit both are `null`. Approval means “this immutable revision may be delivered”; it does not mean delivery happened.

## `MobileShellDeliveryEnvelopeV1`

```js
{
  kind: "iris.mobile-shell.delivery-envelope",
  version: 1,
  envelopeId: "delivery_...",
  deliveryNonce: "...",
  approvalId: "approval_...",
  appId: "publik.kneecap",
  projectId: "publik.kneecap.mobile",
  baseRevisionId: "rev-sha256:<hex>" | null,
  revisionId: "rev-sha256:<hex>",
  contentHash: "sha256:<hex>",
  issuedAt: "2026-09-16T23:00:00.000Z",
  revision: MobileShellRevisionV1
}
```

The envelope duplicates the binding fields intentionally: validators compare them to the embedded revision and the external approval rather than trusting nested data. `deliveryNonce` is single-use. A shell records activation only after compatibility + integrity + approval + base checks all pass and the immutable revision has been durably staged. Rollback selects an earlier already-verified revision; it does not mutate one in place.

## `MobileShellDeliveryPackageV1`

Desktop, web and native use one local transport container:

```js
{
  format: "iris.mobile-shell.package+json",
  approval: MobileShellDeliveryApprovalV1,
  envelope: MobileShellDeliveryEnvelopeV1,
  files: [
    {
      path: "index.html",
      mediaType: "text/html",
      contentBase64: "PCFkb2N0eXBlIGh0bWw+..."
    }
  ]
}
```

The four top-level fields and the three file-body fields are exact. `files` must be the exact revision file set, each `mediaType` must match its revision descriptor, and the entrypoint must be delivered as `text/html`. Distinct declared paths that would alias on the target filesystem, including case aliases or a file path that is also another file's parent directory, are rejected before storage. The 512-character path bound uses JavaScript UTF-16 code units; native parity uses the same metric. Base64 must be canonical and decode to the declared byte count before its SHA-256 is checked. v1 bounds the package to 256 files, 16 MiB per decoded file and 32 MiB total decoded content; a host may additionally bound the raw JSON bytes before parsing.

`verifyDeliveryPackageV1()` verifies the embedded approval/envelope/revision bindings, base/replay options, canonical revision identity and every inline file byte. The embedded `approval` is transport evidence, **not an authentication source**. A native receiver must resolve the same `approvalId` through a separately trusted local/platform authority and require every approval binding to match before staging. The web receiver likewise requires a shell-created local reader-review receipt bound to the exact verified delivery before persistence. There is no self-authorizing package form.

## Host interfaces

### Web/PWA shell owner

- Treat editable app content as hostile to shell privileges.
- Preferred topology: shell chrome/service worker on one origin, each app revision on a distinct content origin. Do not share shell cookies, IndexedDB, service-worker scope, or DOM authority with app content.
- Embed app content in a sandboxed iframe. Do not add `allow-top-navigation`, `allow-popups-to-escape-sandbox`, or a generic bridge. If an opaque-origin fallback is used (sandbox without `allow-same-origin`), authenticate messages by the exact `WindowProxy` plus a fresh per-open channel token; `event.origin === "null"` is never authentication.
- If a dedicated cross-origin app origin is used, validate both `event.source` and exact expected origin. Never accept wildcard `postMessage` commands.
- Browser capabilities are the browser's own permission model. A web revision cannot silently acquire native shell APIs.
- The PWA route is the low-friction install-once route for web-capable apps. It is not proof of native codec/media parity or indefinite storage retention.

### Desktop edit/delivery owner

- Map existing recorded source provenance into stable `appId`/`projectId` records; do not infer editable provenance from a phone package.
- Accept only `MobileShellEditRequestV1`; bind request id + nonce + app/project + exact base before editing.
- Produce immutable revisions with `createRevisionIdentity`/`verifyRevisionIntegrity` and keep reader data out of the package.
- Create a separate approval only after the revision is reviewable/accepted; then create a delivery envelope bound to that approval.
- Wrong base, wrong project, changed bytes, replayed request/delivery nonce, or stale approval is terminal rejection.

### Reviewed native host owner

- The v1 downloadable runtime remains HTML/CSS/JavaScript content. Native functionality lives in the reviewed shell binary.
- `native.*` capability names are narrow broker methods, never JavaScriptCore/WKWebView access to an arbitrary Objective-C/Swift object graph and never an arbitrary command/file API.
- Every native capability is disabled unless it is (a) in this contract's allowlist, (b) declared supported by that shell build, (c) requested by the revision, and (d) granted under the host's reader/platform permission policy. Prior consent requirements remain external platform gates.
- Shell/version/capability compatibility is checked before activation. An unsupported revision remains downloaded-but-inactive or is rejected; the last verified revision keeps running.
- Raw native import consumes the exact `MobileShellDeliveryPackageV1` bytes through the strict parity validator. Staging and activation are distinct: activation rechecks that the staged `baseRevisionId` is still current, and stored revisions recompute canonical manifest/content identity plus file hashes before reuse or launch.

## Distribution truth

- A Home Screen web app is the initial low-friction route for web-capable content. This contract does not say every Kneecap native codec/editor capability works there.
- A native shell requires an actual reviewed/signable distribution path. Local Xcode installs are development builds, not the lasting consumer model.
- TestFlight is a beta route with a 90-day build lifetime, not a permanent install promise.
- Apple's current review rules are external acceptance gates. In particular, the master plan records the downloaded-code boundary in 2.5.2 and mini-app rules including 4.7.2's prior-permission requirement before exposing native platform APIs to mini-app software. Passing these validators does not imply App Review approval.

## `AppStoreMetadataV1` (App Store Guideline 4.7)

A deliberately separate, independently versioned, additive object supporting App
Review Guideline 4.7 obligations for mini apps (verbatim text checked against
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
on 2026-09-27): 4.7.1 privacy information, 4.7.4's per-app metadata for the
index of software, and 4.7.5's age rating. It is **not** a field of
`MobileShellManifestV1`, `MobileShellRevisionV1` or
`MobileShellDeliveryPackageV1`. Those three keep their exact v1 key sets
unconditionally, per the v1 change rule below; privacy/age-rating metadata
grants no capability and changes no runtime behavior, so widening them is
unnecessary and would force every existing host/validator through a v2
migration for a metadata-only addition. Instead, a caller attaches a validated
`AppStoreMetadataV1` to the catalog-facing mobile-shell descriptor (the object
produced by `publisher/index.mjs#descriptorFromPackageBytes` and consumed by
`website/integration.mjs` and Core's `PublikMobileCatalogClient`), which is
already an open, per-field-validated shape rather than an exact-keys sealed
contract type.

```js
{
  kind: "iris.mobile-shell.app-store-metadata",
  version: 1,
  ageRating: 4 | 9 | 13 | 16 | 18, // Apple App Store Connect tiers, confirmed 2026-09-27
  privacySummary: "Nut AI keeps meal logs on this device only.",
  privacyPolicyUrl: "https://publikhq.com/legal/privacy",
  supportContact: { kind: "email", value: "support@publikhq.com" },
  reportContact: { kind: "email", value: "report@publikhq.com" }
}
```

`ageRating` must be one of `KNOWN_AGE_RATINGS` (`[4, 9, 13, 16, 18]`), Apple's
current App Store Connect scheme; it is Iris's own per-mini-app content
rating and never a substitute for the Iris Apps shell binary's own App Store
Connect rating. `privacySummary` and both contact `value` strings are bounded,
control-character-free plain text (`APP_STORE_METADATA_LIMITS`). `privacyPolicyUrl`
and a `"url"`-kind contact `value` must parse as an exact `https:` URL with no
userinfo and no `<`, `>`, `"` or `'` character (rejecting a `javascript:`/`data:`
scheme or an injected-markup query string outright). A descriptor with no
`appStoreMetadata` remains a fully valid, installable v1 descriptor; it is only
marked not ready for an App Store 4.7 listing (see `Review47AppStoreMetadata`
in `native/Sources/IrisMobileShellCore` and `mobile-shell/website/README.md`).

`AppStoreMetadataV1` carries the two machine-checked Guideline 4.7 fields
(age rating and privacy/contact info). It does not by itself mean a package
is fit to list: `publisher/APP_POLICY.md` is the full checklist (age
rating and privacy, report contact, network disclosure, no payments
outside in-app purchase, account deletion, third-party login parity,
user-generated-content filter/report/block, AI-output disclaimer, health
disclaimer, licences, no third-party marks, camera/microphone purpose
match, on-device default) every package must pass before the catalog
lists it, and `publisher/cli.mjs approve` refuses to run without a
`--policy-checked <version>` flag matching that file's current
`Policy version:` line.

## Catalog index v2 (`CatalogIndexV2`, `CatalogCategoriesV1`, `CatalogAppPageV1`)

A third, deliberately separate additive surface for the mobile "real app store"
browse experience (unit m3-catalog-contract-scale). Like `AppStoreMetadataV1`,
this is catalog/browse data, never an install authorization: a malformed or
hostile catalog page can only make Browse show wrong or missing rows, never
change what gets installed. Install always goes through the existing
`mobileShell` descriptor and `verifyDeliveryPackageV1` unchanged.

- `GET /api/iris/mobile/index.json` is page 1 of the index; when there is more
  than one page, `GET /api/iris/mobile/index-<n>.json` serves page `n` for
  `n` in `[2, pageCount]`. Each page file validates against
  `validateCatalogIndexV2` and carries at most `CATALOG_V2_LIMITS.appsPerPage`
  (250) app rows. All pages of one publish share `generatedAt` and
  `pageCount`, and a changed catalog must carry a new `generatedAt` (the
  publisher refuses to overwrite a publish otherwise), because the iOS client
  treats an unchanged page 1 as proof that the other pages are unchanged and
  skips them: one index request per launch when nothing changed.
- Per-app budget: each row's values, written as one JSON array in schema
  order (`catalogIndexEntryDataBytes`), are at most
  `CATALOG_V2_LIMITS.maxAppEntryBytes` (200) UTF-8 bytes. The 11 field names
  are the same for every app and are not counted; they add a fixed 116 bytes
  per row (147 with a `placement` object) to the file. A budget over the
  whole serialized row could never be met, since the specified field names
  and punctuation alone take 150 bytes. The budget is binding: a row whose
  every field is inside its own limit can still be rejected, and the fix is a
  shorter summary or name. At 1,000 apps the values total at most 200 KB and
  the index files about 300 KB (the checked-in 1,000-app fixture is 298 KB
  across 4 pages), well under the client's 2 MiB per-page cap.
- `updatedAt` is a calendar date (`YYYY-MM-DD`, UTC): Browse shows the day,
  and a date is 14 bytes shorter than an instant inside the budget.
  `byteCount` is the download size and must be between 1 and
  `CATALOG_V2_LIMITS.maxPackageBytes` (48 MiB, the raw package limit the
  publisher and the iOS client enforce).
- `publisher` (optional, RC-05): who made the app, shown as "By Publik" under
  the app name and on the consent sheet. Absent means Publik (every catalog app
  is Publik's own today), so an index published before the field still works.
  When present it is 1 to 80 characters, already trimmed, on one line, with no
  control characters and no `<` or `>` (`isCatalogPublisherName`). Like
  `latestRevisionId` it sits outside the 11-field row shape and the 200 byte
  budget, so it never makes a valid row too big. The iPhone rejects a page
  whose row carries an invalid publisher.
- A row and its own app page must agree
  (`validateCatalogIndexEntryMatchesAppPage`): `byteCount` equals
  `mobileShell.byteCount`, and when the descriptor carries App Store metadata,
  `ageRating` equals its reviewed age rating. The publisher refuses a
  disagreeing app; the website shows it as not available.
- A catalog with more rows than fit in one page (for example 10,000 apps) is
  not representable as a single valid page file: the publisher splits it
  across 40 page files, and a caller who tries to cram them into one page is
  rejected by the same per-page limit, not by a separate "too many apps"
  check.
- `iconHash` is the first 16 hex characters of the sha256 of the icon bytes.
  It is not an install-integrity check (the icon is outside the install
  security boundary), but the iOS client does check it, so another app's
  artwork is never shown under this app's name. `placement` is `null` for
  the common case of no special placement, or `{ featured, sponsored, label }`
  with `label` required exactly when `featured` or `sponsored` is `true`.
- `GET /api/iris/mobile/categories.json` validates against
  `validateCatalogCategoriesV1`: at most `CATALOG_V2_LIMITS.maxCategories`
  (24) rows, unique ids.
- `GET /api/iris/mobile/apps/<slug>.json` validates against
  `validateCatalogAppPageV1`: the existing `mobileShell` descriptor
  (unchanged verification path) plus `description`, up to 6 `screenshots`
  (each `publikhq.com`-only and under 400 KB), plain-language `permissions`
  (each `capability` drawn from `KNOWN_CAPABILITIES`), `privacySummary`,
  `supportURL`, and `whatsNew`.
- `iconURL` (on each index row) and every `screenshots[].url` must be an
  exact `https://publikhq.com/...` URL (`isPublikHttpsURL`); a foreign host,
  even a lookalike such as `publikhq.com.evil.example`, is rejected. `slug`
  reuses the existing stable-id pattern (`[a-z0-9][a-z0-9._-]{0,127}`, no
  `/`), so a path-traversal slug such as `../../etc` is structurally
  impossible, not merely filtered.
- Sponsored and featured placements are carried in `placement` (`featured`,
  `sponsored`, `label`) and are never used for search ranking; a `label` is
  required exactly when `featured` or `sponsored` is `true`.
- Publishing: `publisher/cli.mjs catalog-emit` writes every file as compact
  canonical JSON (sorted keys, one line) and lists each file's sha256 in
  `manifest.json`; a server can use those values as ETags.
- The existing `/api/iris/apps` route (the v1 catalog this file already
  documents) is unchanged and stays the fallback when index v2 is absent
  (page 1 answers 404), and the desktop client's only catalog route.

## v1 change rule

Additive behavior that older hosts must understand is **not** added as an ignored field. Security- or execution-relevant schema changes require contract `version: 2`. v1 validators remain strict so an old host cannot accidentally accept a new privilege by omission.

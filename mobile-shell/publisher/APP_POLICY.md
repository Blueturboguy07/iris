# Publik hosted-app policy

Policy version: 1

Status: this is the checklist every package must pass before the catalog
lists it. It exists because App Store Guideline 4.7 makes Publik
responsible for everything a hosted mini app does inside the Iris Apps
shell, and Guideline 1.2 (user-generated content) makes Publik responsible
for what users post inside one. Both guidelines are checked against
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
as of 2026-09-27 (the same date the `AppStoreMetadataV1` contract section in
`mobile-shell/contracts/CONTRACT.md` was checked).

`publisher/cli.mjs approve` refuses to approve a package unless the caller
passes `--policy-checked <version>` matching the `Policy version:` line
above. This is a person's attestation that they checked the package below,
not an automated content scan; the CLI only verifies the version string
matches, not that the checklist was actually followed.

## The checklist

A package fails this policy, and must not be approved, if any of the
following is true:

1. **Age rating and privacy summary.** The package's `AppStoreMetadataV1`
   (`ageRating`, `privacySummary`, `privacyPolicyUrl`) is missing or the
   summary does not plainly describe what data the app touches. (4.7.1,
   4.7.5)
2. **Report contact and privacy policy URL.** `reportContact` and
   `privacyPolicyUrl` are both present and reachable; "Publik reads every
   report" (or an equivalent honest promise) is the standing reply
   expectation, not a fixed reply-time SLA nobody owns. (4.7.1, 1.2)
3. **No undisclosed network access.** The manifest requests
   `web.network.same-origin` or `web.navigation.external` only if the app
   actually needs it, and the privacy summary discloses it. No capability
   silently expands what the app can reach. (4.7.2, 5.1.1)
4. **No payments or credits outside in-app purchase.** No price, credit
   balance, key field, subscription or paid unlock anywhere in the app
   outside Apple's in-app purchase, per OD-05 in
   `docs/plans/20260928-all-routes/apple-compliance/REQUIRED_CHANGES.md`.
   (3.1.1, 4.7.1)
5. **No accounts without in-app deletion.** If the app has any concept of an
   account, the account can be deleted from inside the app, not only by
   emailing someone. (5.1.1(v))
6. **No third-party login without an equivalent private option.** If the
   app offers "Sign in with X" for any third party, it offers a
   privacy-equivalent option (for example Sign in with Apple, or no
   accounts at all) alongside it. (4.8)
7. **User-generated content has filter, report and block.** Any place a
   user can post, upload or share content inside the app has an in-app
   filter for obvious abuse, a report control, and a block control, all
   reachable from the content itself. (1.2)
8. **AI outputs have a report path and a "may be wrong" line.** Any
   AI-generated output shown to the user carries a visible "this may be
   wrong" style disclaimer and the same report path as user-generated
   content. (1.2, 4.7.1)
9. **Health or diet content has the "not medical advice" line.** Any
   calorie, weight, fitness, diet, or body-image content carries a visible
   "not medical advice" (or equivalent) disclaimer near the content, not
   only in a buried settings page. (2.3.6, 1.4.1)
10. **Licences are listed.** Every third-party library the package bundles
    is listed with its licence somewhere reachable from the app (an
    about/licences screen or equivalent). A licence whose terms this
    package cannot honour (for example a copyleft licence requiring
    relinking inside a hash-locked package) blocks approval until the
    dependency is replaced or a written licence position exists. (owner
    decision OD-15 is the worked example: LGPL `soundtouchjs` in Kneecap.)
11. **No third-party marks or lookalike UI.** The app does not use another
    company's name, logo, or a UI that could be mistaken for another
    company's app, inside its content or its icon/screenshots. (4.1, 5.2.1)
12. **Camera or microphone use matches its stated purpose.** If the
    manifest requests `web.media.camera`, `web.media.microphone`,
    `native.camera` or `native.microphone`, the app only activates it for
    the purpose stated in the privacy summary, and never as a background or
    always-on capability. (5.1.1, 4.7.2)
13. **On-device by default.** The app processes user content on-device
    unless a network capability is both granted (item 3) and required for
    the feature to work at all; on-device is the default posture for every
    new package, not an opt-out.

## What `--policy-checked` does and does not do

- `approve` refuses to run at all without `--policy-checked <version>`, and
  refuses again if `<version>` does not equal this file's current
  `Policy version:` line (a stale version, from before this file changed,
  is treated the same as a missing one).
- Passing the current version means "a person checked this package against
  every item above." The CLI does not and cannot verify most of these items
  itself (some, like "does the privacy summary plainly describe the data
  touched," are judgment calls); this flag is an attestation gate, not a
  scanner.
- Bumping `Policy version:` after a real change to the checklist above
  forces every future `approve` call to re-attest, because the version
  string callers pass will no longer match. Editing this file without
  bumping the version does not force re-attestation, so bump the version
  whenever the checklist's substance changes.

## Related reading

- `docs/plans/20260928-all-routes/apple-compliance/AUDIT.md` and
  `REQUIRED_CHANGES.md` (RC-01 to RC-14, OD-01 to OD-16): the audit this
  checklist is derived from.
- `mobile-shell/contracts/CONTRACT.md`, section `AppStoreMetadataV1`: the
  machine-validated shape that carries items 1 and 2 above.
- `mobile-shell/publisher/index.mjs` (`attachAppStoreMetadata`,
  `approvePublisherBuild`): what `cli.mjs approve` calls after this policy
  gate passes.

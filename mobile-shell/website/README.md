# Iris website handoff integration

This zero-dependency module is the reusable website half of the Publik → Iris mobile handoff. It does not deploy anything, install Iris, fetch packages, or infer Apple identity.

`integration.mjs` owns the shared link contract:

- canonical app intent: `https://publikhq.com/iris/apps/<slug>`
- explicit fallback: `iris-apps://install/<slug>`
- AASA route: `/.well-known/apple-app-site-association`

The website may render **Open in Iris** only for a selected catalog row that contains a valid `mobileShell` descriptor. The descriptor validation mirrors the native downloader's important availability checks: iOS v1 package format, exact Publik HTTPS artifact origin, MIME/byte bounds, hashes, stable app/project ids, and canonical revision/content binding. A row with no descriptor remains unavailable.

Catalog index v2 input: `loadCatalogV2Rows({ readJSON })` reads a published catalog v2 (`index.json`, then `index-2.json` up to page 1's `pageCount`, then `apps/<slug>.json` per row) and returns the same rows `catalogRowsFromIndexV2({ indexPages, appPages })` builds from in-memory documents. Pages must be one publish in order (same `generatedAt` and `pageCount`); a torn or out-of-order set is refused. A row with no app page, or whose size or reviewed age rating disagrees with its app page, is shown as not available. A missing `index.json` is an explicit error, so a caller can fall back to the v1 `/api/iris/apps` rows.

`renderCatalogHandoffHTML(...)` escapes catalog display text and URL attributes. It never invents an Iris installation destination. An **Install Iris** link appears only when the caller supplies a syntactically valid App Store app URL or TestFlight join URL. Supplying a distribution URL is still a caller assertion that the URL is an actual current release; this offline module does not make a network request to prove publication. The canonical selected-app link remains on the page so a reader can return to the same app after installing Iris.

`generateAASA(...)` requires the caller to provide the exact Apple application identifier, for example `R5R3ZS54LV.com.publikhq.iris.mobileshell`. There is no default team, prefix, or bundle id and wildcard application identifiers are rejected.

Seed catalog: `seed-catalog-v2.mjs` turns the three starter apps that ship inside Iris (Kneecap, Nut AI, FreeHarmony) into catalog v2 files, using the publisher's own descriptor and emitter code. It writes the same bytes twice: into the iPhone app (`IrisMobileShellCore/Store/StoreCatalogSeedData.swift`, the catalog Browse falls back to when publikhq.com has none) and into an upload folder with a DEPLOY.md (`docs/plans/20260928-all-routes/round3-deferred/M-store-screens/website-catalog-v2/`). Run it after changing the starters or their copy; `--check` fails if either output is stale. Nothing is uploaded.

## Website build (RC-03, `round5/rc03-website/`)

`build-site.mjs` builds the actual publikhq.com website: the same three apps' catalog v2 (`api/iris/mobile/...`), now carrying each app's `AppStoreMetadataV1` (age rating, privacy policy link, support/report contact; `site-content.mjs`, sourced from `apple-compliance/LISTING.md` and `PRIVACY_POLICY_OUTLINE.md`), the `apple-app-site-association` file, and the human-facing pages (`site-pages.mjs`): a hub page, one page per app, privacy, support, and a not-found page. Output goes to `docs/plans/20260928-all-routes/round5/rc03-website/site/`, a tree separate from `seed-catalog-v2.mjs`'s own output folder, which this script never touches.

```sh
node mobile-shell/website/build-site.mjs            # write the site and refresh DEPLOY.md's website section
node mobile-shell/website/build-site.mjs --check     # fail if the checked-in copy is stale
```

To try it locally, see `docs/plans/20260928-all-routes/round5/rc03-website/HOW_TO_OPEN.txt`. Nothing is deployed.

Two open items for the owner (also logged to `docs/plans/20260928-all-routes/NEEDS_OWNER.md`):

- The AASA file uses a placeholder Apple Team ID (`TEAMIDTBD1` in `site-content.mjs`) because no Apple Developer Program membership is enrolled yet (OD-11, `Release.xcconfig` has an empty `DEVELOPMENT_TEAM`). Replace it and rebuild before this file is ever deployed.
- Nut AI's age rating is 13+ on this website build (OD-08's decision) but still 4 in `seed-catalog-v2.mjs`'s own bundled fallback catalog, since that file is outside this unit's owned paths.

`site-audit.mjs` is the independent "a person following links" oracle used by the tests: every link on a generated page must resolve to a generated file or an explicitly allowed external URL (the bare `https://publikhq.com`, `mailto:`, `iris-apps://install/<slug>`), Privacy and Support must be reachable within two taps of any app page, and the AASA path patterns must agree with the generated `/iris/apps/<slug>` routes.

Run the focused tests without installing dependencies:

```sh
node --test mobile-shell/website/tests/*.test.mjs
```

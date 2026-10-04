Catalog fixture generator
==========================

Deterministically generates catalog v2 fixture publishes (index pages,
`categories.json`, per-app `apps/<slug>.json` pages, and for the small set
real installable packages and icons) so M2, M5, M6 and D10 all test against
the exact same bytes.

Seed
----

`DEFAULT_SEED` (in `bin/generate.mjs`) is `iris-catalog-v2-fixtures-2026-09-28`.
The same seed and app count always produce byte-identical output: no
`Math.random`, no clock reads. Every publish is stamped
`generatedAt = 2026-09-28T12:00:00.000Z` (`GENERATED_AT` in
`src/generate.mjs`). `test/generate.test.mjs` regenerates all three sets and
checks that the checked-in files match, so a hand-edited fixture or a
generator change without regenerating fails the suite.

Usage
-----

```sh
# Regenerate the checked-in fixtures (3, 100 and 1000 apps; packages for the 3-app set):
node bin/generate.mjs

# Custom seed, counts, package sets, or output directory:
node bin/generate.mjs --seed my-seed --counts 3,50 --with-packages 3,50 --out /tmp/out
```

Writing goes through the publisher's own `writeCatalogV2`, so a fixture set
is exactly what `publisher/cli.mjs catalog-emit` would publish, and files
are replaced in place. Nothing is deleted: if a folder holds a catalog file
this run would not produce, the run stops and lists it.

Output layout, per app count `<n>`, under
`mobile-shell/native/Tests/Fixtures/catalog-v2/<n>/`:

- `index.json` (page 1), `index-2.json`, ... (250 apps per page; the 1000-app set has 4 pages, 298 KB in total)
- `categories.json` (24 categories)
- `apps/<slug>.json` (one per app)
- `manifest.json`: seed, counts, `catalogEmitHash`, and the sha256 of every catalog file (usable as ETags by a fake server)
- 3-app set only: `packages/<slug>.irisapp` (real MobileShellDeliveryPackageV1 files, 190 to 250 KB, that pass `verifyDeliveryPackageV1`) and `icons/<slug>.png` (32 x 32 PNG)

How a test server maps them to publikhq.com: `index*.json` and
`categories.json` under `/api/iris/mobile/`, `apps/<slug>.json` under
`/api/iris/mobile/apps/`, packages at each descriptor's `downloadUrl`
(`/api/iris/mobile-shell/<slug>/pkg.json`), icons at each row's `iconURL`
(`/i/<slug>.png`). `native/Tests/IrisMobileShellCoreTests/CatalogFakeServerTests.swift`
does exactly this.

Realism
-------

- Names combine two ordinary-word lists (`src/wordlist.mjs`): "Quiet Notes",
  "Swift Mail", "Daily Budget", including words that collide with built-in
  apps (Notes, Mail, Camera, Weather), which is what search has to cope with.
- Summaries come from plain-language templates and are shortened when a row
  would go over the 200-byte per-app budget, the same rule the publisher
  enforces.
- Sizes are log-uniform from 40 KB to 24 MB (median about 1 MB), and the
  store row's size always equals the descriptor's package size.
- Categories (1 to 3 per app across 24), age ratings (4+, 9+, 13+, 16+, 18+),
  update dates over two years, at most one badge ("new" or "updated"), and a
  sponsored or featured slot on about 1 app in 12.
- The permissions on each app page are what that app's package requests
  (checked for the 3-app set, whose packages are real).

In the 100 and 1000 sets the descriptors are realistic but their
`packageSha256` matches no stored package: installing one fails closed at
the digest check. Use the 3-app set for install journeys, or run the
generator with `--with-packages` for more.

Tests
-----

```sh
node --test ./test/*.test.mjs
```

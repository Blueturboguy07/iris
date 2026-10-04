# Building for the current Iris mobile file runtime

## Build output is not a working mobile app

The current Host keeps each verified page at its package file URL, preserving
the existing per-app browser-data profile across updates and revert. A successful
Vite, Next, or Expo export does not by itself establish that its startup, routes,
workers, database, media controls, or offline workflow operate in that Host.

The real Kneecap acceptance run exposed this distinction: installation completed,
but its external ES-module entry left the app on its static Loading screen. The
publisher now rejects that known-incompatible entry shape during preparation and
again when approving prepared output. It explains the required file-compatible
build instead of producing a new package that appears ready for use.

The guard does not alter source, strip `type=module`, enable file-access bypasses,
start a local server, grant networking, or replace the app with a demo. Classic
scripts still need their actual runtime tested. Inline modules, dynamic imports,
workers, CSS references, and framework-specific routing are not certified by this
limited entrypoint check.

## Preparation and immutable updates

Use a reviewed app source copy and a distinct fresh build-output directory.
Preserve the original package and its receipt when correcting an installed app.
An update must name the exact current base revision; never overwrite installed
version bytes to hide a startup failure. Keep the same app/project identity and
compatible data namespace unless a separately designed migration requires a new
contract.

The existing local commands are:

```sh
node mobile-shell/publisher/cli.mjs prepare \
  --source-root "$REVIEWED_SOURCE_ROOT" \
  --build-root "$BUILT_APP_ROOT" \
  --source-owner "$SOURCE_OWNER" --source-repo "$SOURCE_REPO" \
  --source-commit "$PINNED_COMMIT" \
  --app-slug "$APP_SLUG" --app-id "$APP_ID" --project-id "$PROJECT_ID" \
  --display-name "$APP_NAME" --data-namespace "$DATA_NAMESPACE" \
  --base-revision "$CURRENT_REVISION_OR_NULL" \
  --capability web.storage \
  --out "$NEW_PREPARATION_PATH"

node mobile-shell/publisher/cli.mjs approve \
  --preparation "$NEW_PREPARATION_PATH" --approve-reviewed-output \
  --approve-source-commit "$PINNED_COMMIT" \
  --download-url "$REVIEWED_PUBLIK_ARTIFACT_URL" \
  --package-out "$NEW_PACKAGE_PATH" \
  --descriptor-out "$NEW_DESCRIPTOR_PATH" \
  --receipt-out "$NEW_RECEIPT_PATH"
```

All source/build paths are absolute. Output paths must be fresh and outside those
roots. Use `null` only for a genuinely first revision. Add only the app's needed
capabilities; the example's storage capability is not a universal permission
template. These commands prepare local artifacts only. They do not publish the
URL, upload the package, approve installation in the phone, or independently
authenticate a caller-supplied source pin.

`vite-classic-build.mjs` is an existing adapter for a reviewed single-entry Vite
project whose code can be bundled into the supported classic-script format.
Projects with multiple entrypoints, top-level await, native modules, or worker
requirements need their actual build configuration reviewed. The helper's
existence is not proof that a particular app has a working classic build.

## Real local-preview handoff

The current DEBUG-only `--iris-local-app-acceptance` mode uses isolated app and
usage namespaces. It runs the production catalogue verification, review,
installation, activation, and WebView paths with explicit local retrieval inputs.
Normal Debug and Release keep the public catalogue transport.

The local preview accepts reviewed inputs from its dedicated
`Documents/LocalAppAcceptance` folder only when the preview marker is present.
Changing those developer inputs does not install or activate a revision. The
user still follows the app-specific incoming link and confirms Install & Open or
Update & Open. The preview caption must continue to say local/not published;
do not describe this as a real public website download.

## Required acceptance for each actual app

Record one installation confirmation and the real app's resulting usable screen,
not merely a successful package copy or page-load callback. Exercise onboarding
and the app's core offline task with fictional test data through its actual UI.
Then close/reopen, perform a compatible update, inspect history, and revert while
checking that saved data remains usable. Preserve the failed first revision and
its evidence.

For media apps, exercise selected-media cancellation and successful synthetic
media import as separate cases. Camera permission remains a just-in-time OS
decision, not an automatic installation grant. Undeclared capabilities,
subframes, stale views, and directory-upload requests must remain denied. No
microphone or broad photo-library permission is implied by selected-media access.
Unavailable simulator hardware and missing provider configuration must produce
truthful outcomes; neither may be replaced with a fabricated successful result.

The packaged API SDK and exact signed-adapter integration are documented in
`docs/mobile-shell/PACKAGED_API_INSTALLATION.md`. API configuration and usage
tracking consent remain independent of app installation.

## Verification layers

The publisher's 19 Node tests pass, including seven file-runtime preparation
cases. Before the guard, four of those seven failed by accepting external-module
entrypoints; a syntactically valid disposable variant with the guard disabled
fails those same four assertions. This checks the publisher's error boundary,
not the app's functional runtime. Native tests, real per-app interaction,
installed artifact identity, and public distribution retain separate gates.

# Lunara publisher preparation recipe

This is an offline preparation recipe only. It does not fetch Lunara, clone a repository, install dependencies, build the app, upload a package, edit publikhq.com, deploy anything, sign an app, or install anything on a device.

## Reviewed mobile source identity

The saved Iris audit identifies Lunara as the strongest next **specifically-mobile** candidate among the previously audited native-mobile listings. The current reviewed guide pin is:

- Publik slug: `lunara`
- source repository: `Blueturboguy07/lunara`
- exact reviewed commit: `551e030e8ea276c24ec42b13242d3ce49bca948f`
- guide output type: `mobile_app`
- source shape observed in the saved audit: React/Vite product bundle inside Capacitor iOS/Android projects

The tool's `--recipe lunara` option records that pin as **caller-attested provenance**. This offline tool does not obtain source and does not independently verify that the supplied source root matches the named repository/commit. The caller must supply an already-reviewed source root and an already-built shell-compatible output root.

## Minimal Iris-shell behavior to prepare

The first useful Lunara shell slice should exercise the local core tracker only.

- Built assets must be package-relative. The publisher build used for Iris must emit relative resource paths suitable for a local `file://` entrypoint.
- `web.storage` is required. Lunara's core tracker uses Dexie/IndexedDB for durable local health/profile/log state. The package must declare it and the host must actually preserve it across close/reopen before acceptance.
- Keep AI/provider calls and encrypted cloud backup out of this first package. Those need reviewed networking, account/secret, and consent boundaries.
- Do not claim native parity for local notifications, HealthKit/Health Connect, biometrics/secure vault, widgets, report/share bridges, background work, or haptics. Current Iris native shell capability support does not provide that Lunara native surface.
- The source app may contain those optional/native paths; the publisher-reviewed Iris build must ensure the first accepted workflow does not depend on them.

## Publisher preparation

After an authorized publisher or reviewer has independently supplied the exact reviewed source root and a finished web-content build output:

```sh
node mobile-shell/publisher/cli.mjs prepare \\
  --recipe lunara \\
  --source-root /absolute/already-reviewed/lunara-source \\
  --build-root /absolute/already-built/lunara-output \\
  --app-slug lunara \\
  --app-id <publisher-reviewed-stable-app-id> \\
  --project-id <publisher-reviewed-stable-project-id> \\
  --display-name Lunara \\
  --data-namespace <publisher-reviewed-data-namespace> \\
  --entrypoint index.html \\
  --min-shell-version <reviewed-shell-version> \\
  --out /absolute/review/preparation.json
```

`prepare` walks only the supplied build root with bounded file/directory/depth and file-size limits. It rejects symlinks/unsafe paths, hashes the actual output bytes, and verifies the v1 manifest/revision identity. It also performs a **limited entrypoint sanity check** over quoted HTML `src`/`href` attributes and rejects root-absolute/remote/missing references there. That check does not parse CSS `url()`, `srcset`, JavaScript imports, `<base>`, workers, or runtime-generated URLs, so the publisher must separately test the finished build in the real shell. The preparation binds the caller-attested source pin alongside the exact revision in `preparationHash`.

Preparation is not approval and does not produce a website descriptor.

## Explicit publisher approval

After a human/publisher has reviewed the preparation and chosen the exact future Publik artifact URL:

```sh
node mobile-shell/publisher/cli.mjs approve \\
  --preparation /absolute/review/preparation.json \\
  --approve-reviewed-output \\
  --approve-source-commit 551e030e8ea276c24ec42b13242d3ce49bca948f \\
  --download-url https://publikhq.com/<publisher-reviewed-artifact-path> \\
  --package-out /absolute/review/lunara.irisapp \\
  --descriptor-out /absolute/review/mobileShell.json \\
  --receipt-out /absolute/review/publisher-receipt.json
```

The approval command re-reads and re-hashes the build output. Any changed, missing, or added file causes rejection and requires a fresh preparation. It requires both the explicit approval flag and the exact reviewed source commit.

The proposed `mobileShell` descriptor is generated from the exact final package bytes, not from filenames, source tags, or guessed catalog state. `downloadUrl` is mandatory explicit input and must be an exact `https://publikhq.com/...` URL with no explicit port. The tool preserves that caller-supplied URL string; it never checks whether the URL exists and never uploads there.

## Real mobile acceptance gates

This preparation lane does not complete the user's mobile acceptance. A real acceptance still requires:

1. A specifically-mobile Publik listing, not merely a `Web` listing.
2. Publisher-supplied reviewed Lunara source/build output corresponding to the exact pin above, or an explicitly updated reviewed source pin.
3. A shell-compatible relative-path build whose actual bytes are packaged and bound to caller-attested provenance, plus a real-shell asset-resolution test beyond this tool's limited HTML `src`/`href` sanity check.
4. Durable `web.storage` support in the actual Iris host.
5. The exact package hosted at the publisher-reviewed Publik HTTPS URL with descriptor byte count/hash/identity matching those bytes.
6. Reader review/approval, stage, activation, and launch of that real downloaded package.
7. One useful Lunara core-tracking action followed by close/reopen proof that the saved state survives.
8. Only separately opted-in usage observation for that real action.

Until an actual Lunara source/build root is supplied and built outside this lane, this recipe is preparation infrastructure, not a Lunara package or a completed acceptance result.

# Signing and shipping Iris

What state signing is in, what it costs, and the exact steps left that need a
person. The whole point is that the download opens on the first double-click —
an installer that triggers a scary dialog converts worse than no installer,
because the reader concludes the site ships malware.

## macOS

**Working, except notarization.**

`scripts/build-iris-macos.sh` picks one of two paths, the same way NitroAI's
`electron-builder.cjs` does:

- **Developer ID + notarized** when `APPLE_SIGNING_IDENTITY` names a real
  identity. Tauri signs under the hardened runtime and, if `APPLE_ID`,
  `APPLE_PASSWORD` and `APPLE_TEAM_ID` are set, submits to Apple and staples.
- **Ad-hoc** otherwise, so a contributor without a certificate still gets a
  bundle that runs locally instead of one macOS calls damaged.

`scripts/verify-iris-macos.sh` is the part that was missing. It checks the
signature, the hardened runtime flag and the team identifier, then mounts the
dmg, copies the app out, writes the `com.apple.quarantine` attribute exactly as
a browser download would, and asks Gatekeeper the same question it asks at
double-click time. Finally it launches the binary and confirms it stays up —
passing assessment and actually starting are different failures.

Verified locally on 2026-07-27 against
`Developer ID Application: Mann Bellani (R5R3ZS54LV)`:

```
Signature
  PASS  signature is intact and covers every nested binary
  PASS  signed by Developer ID Application: Mann Bellani (R5R3ZS54LV)
  PASS  hardened runtime is enabled
  PASS  team identifier is R5R3ZS54LV
Install and open
  PASS  the dmg mounts
  ----  Gatekeeper rejects a quarantined copy: source=Unnotarized Developer ID
  PASS  the app starts and stays running (10s)
```

That one remaining line is the whole gap. Signing alone is not enough on any
current macOS: without a notarization ticket a downloaded copy is refused.

### Entitlements

`iris-desktop/src-tauri/entitlements.plist` is deliberately empty, unlike
NitroAI's, which needs four exceptions. Iris is a Rust binary plus a WKWebView,
and the web content runs in Apple's own out-of-process service — so it needs
none of the JIT or unsigned-memory holes an Electron app does. This was checked,
not assumed: the signed build launches and runs with an empty entitlements file.

### What is left

Five secrets on `Blueturboguy07/publik`. They are the same five values NitroAI
already has, and the workflow deliberately reuses NitroAI's secret names so they
can be copied across:

```
gh secret set CSC_LINK --repo Blueturboguy07/publik
gh secret set CSC_KEY_PASSWORD --repo Blueturboguy07/publik
gh secret set APPLE_ID --repo Blueturboguy07/publik
gh secret set APPLE_APP_SPECIFIC_PASSWORD --repo Blueturboguy07/publik
gh secret set APPLE_TEAM_ID --repo Blueturboguy07/publik   # R5R3ZS54LV
```

`CSC_LINK` is the base64 of the Developer ID `.p12`. The app-specific password
comes from appleid.apple.com → Sign-In and Security → App-Specific Passwords; it
is not the Apple ID password.

Once they are set, `gh workflow run iris-release.yml` builds signed, notarized
and stapled, and the verify step runs with `--require-notarized`, so a release
that would not open cannot pass.

## Windows

**Unsigned. Needs a certificate that has to be bought.**

### Why there is no .pfx path

Since June 2023 the CA/Browser Forum baseline requires code-signing private keys
to live on hardware meeting FIPS 140-2 Level 2 or equivalent. A certificate file
you can hold and hand to a CI runner no longer exists for new certificates. So
the options are a physical USB token (unusable in CI) or a cloud signing service
that holds the key in an HSM and signs on request.

### The recommendation: Azure Artifact Signing

Formerly Trusted Signing. **~$9.99/month** on the Basic tier (up to 5,000
signatures). Keys stay in Microsoft's HSM, so it works from a GitHub runner with
nothing but three environment variables. Individual developers in the US and
Canada are eligible with a government photo-ID check through Microsoft Entra
Verified ID; organizations need three years of verifiable history, which is why
the individual route is the relevant one here.

**Check availability first.** Microsoft capped new subscriptions during the
public preview, so eligibility is worth confirming before planning around it.

### On SmartScreen — the "frictionless for a consumer" question

There is no option that buys an instant clean install on Windows. Microsoft
removed EV's automatic SmartScreen bypass in 2024, so an EV certificate at
$300–700/year now behaves like an OV one for reputation purposes. What actually
removes the warning is accumulated reputation, and the important detail is
**what the reputation attaches to**:

- **Unsigned** — reputation accrues per file hash. Every release starts from
  zero, so the warning never goes away. This is the worst outcome, and it is
  where Iris is today.
- **Signed with any stable certificate** — reputation accrues to the signing
  identity and carries across releases. The warning fades as downloads
  accumulate and does not come back with each new version.

So the least-friction path is not the most expensive certificate; it is *any*
certificate, used consistently, as early as possible, because the clock starts
when signing starts. Azure Artifact Signing is the cheapest way to start that
clock and the only one that signs cleanly from CI. Submitting the app through
Microsoft's malware-analysis form once it is signed can shorten the wait.

An OV certificate from Sectigo or DigiCert (~$100–300/year) is a valid fallback
if Azure eligibility does not work out, but the key still has to live on their
cloud HSM or a shipped USB token, which means either extra per-signature cost or
no CI signing at all.

### The workflow is already wired

`.github/workflows/iris-release.yml` installs `trusted-signing-cli` and layers a
`signCommand` onto the Tauri config with `--config` when the Azure secrets are
present, and builds unsigned when they are not — so nothing breaks while this is
still unpurchased. When ready:

```
gh secret set AZURE_CLIENT_ID --repo Blueturboguy07/publik
gh secret set AZURE_CLIENT_SECRET --repo Blueturboguy07/publik
gh secret set AZURE_TENANT_ID --repo Blueturboguy07/publik
gh secret set AZURE_SIGNING_ENDPOINT --repo Blueturboguy07/publik   # e.g. https://wus2.codesigning.azure.net
gh secret set AZURE_SIGNING_ACCOUNT --repo Blueturboguy07/publik
gh secret set AZURE_SIGNING_PROFILE --repo Blueturboguy07/publik
```

The client ID, secret and tenant come from an Entra ID app registration granted
the Trusted Signing Certificate Profile Signer role on the signing account.

`scripts/verify-iris-windows.ps1` then runs with `-RequireSigned`, which checks
the installer's signature, that the payload *inside* it is signed too, and that
the signature carries a trusted timestamp — without one, every copy already
downloaded stops validating the day the certificate expires.

## The other apps

The catalog's macOS story is inconsistent and worth fixing on the same pass:

- **Simplicity** — signed and notarized. Opens clean.
- **NitroAI** — the workflow supports it and the secrets are set.
- **cue** — ad-hoc signed; its README walks people through right-click → Open.
- **WhimprFlow** — Apple-Development-signed only, not notarized, so it warns.

Whatever is decided for Iris should be applied to cue and WhimprFlow, since the
same certificate and the same five secrets cover all of them.

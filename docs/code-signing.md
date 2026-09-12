# Signing and shipping Iris

What state signing is in, what it costs, and the exact steps left that need a
person. The whole point is that the download opens on the first double-click —
an installer that triggers a scary dialog converts worse than no installer,
because the reader concludes the site ships malware.

## macOS

### Consumer release path

The macOS customer artifact is fail-closed in
`.github/workflows/iris-release.yml`. It is not uploaded as a release candidate
unless all five distribution values are present: `CSC_LINK`,
`CSC_KEY_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, and
`APPLE_TEAM_ID`. Missing values fail the macOS job instead of producing an
unsigned or unstapled fallback.

The workflow imports and checks an Apple-issued **Developer ID Application**
identity, builds the native Release target as `com.publikhq.iris` with the
hardened runtime, notarizes and staples the app before putting it in the dmg,
then signs, notarizes, and staples the dmg. Finally,
`scripts/verify-iris-macos.sh` runs with `--require-notarized`,
`--expected-team "$APPLE_TEAM_ID"`, and `--expected-bundle-id
com.publikhq.iris`. That strict check validates the app and the copy inside the
dmg, both stapled tickets, the Developer ID authority, team, bundle identifier,
hardened runtime, quarantined Gatekeeper assessment, and launch. Publication
requires a readiness marker written only after that check passes.

The expected team is supplied to the verifier by the release configuration; it
is not a personal-team constant in the script. The verifier can still inspect a
local build without strict flags, but `--require-signed` requires an explicit
expected team and `--require-notarized` requires both app and dmg tickets.

### Local and legacy paths

`scripts/build-iris-macos.sh` remains useful for local Tauri development and may
produce an ad-hoc bundle when no Developer ID identity is available. That path
is not a customer release. `IrisLocalSigningIdentity.swift` makes the same
distinction: a persistent self-signed identity can stabilize permissions on one
Mac, but it is not a Gatekeeper or notarization identity. Apple Development and
Personal Team identities are likewise local-development credentials, not
Developer ID distribution credentials.

`iris-macos/scripts/release.sh` is a legacy `makesomething` workflow targeting a
different repository. It is not an Iris consumer release path and must not be
used to publish the customer artifact.

### Tauri does not staple the dmg

Worth knowing, because it is invisible until someone is offline. Tauri notarizes
and staples the `.app`, then wraps it in a dmg which it signs but never submits.
A dmg with no ticket of its own has to be checked against Apple over the
network, so the download fails on a machine that is offline or behind a filter,
and the failure looks like a corrupt file rather than a policy decision.

The native release workflow now submits and staples the app before packaging,
then submits and staples the dmg itself. The verify script checks for both
tickets separately, which prevents a valid app from being hidden inside an
unstapled downloaded image.

### Entitlements

`iris-desktop/src-tauri/entitlements.plist` is deliberately empty, unlike
NitroAI's, which needs four exceptions. Iris is a Rust binary plus a WKWebView,
and the web content runs in Apple's own out-of-process service — so it needs
none of the JIT or unsigned-memory holes an Electron app does. This was checked,
not assumed: the signed build launches and runs with an empty entitlements file.

### CI configuration

The workflow deliberately reuses NitroAI's secret names so the same five
distribution values can be managed in one place:

```
gh secret set CSC_LINK --repo Blueturboguy07/publik
gh secret set CSC_KEY_PASSWORD --repo Blueturboguy07/publik
gh secret set APPLE_ID --repo Blueturboguy07/publik
gh secret set APPLE_APP_SPECIFIC_PASSWORD --repo Blueturboguy07/publik
gh secret set APPLE_TEAM_ID --repo Blueturboguy07/publik
```

`CSC_LINK` is the base64 of the Developer ID `.p12` — export it from Keychain
Access, the certificate is already installed. The app-specific password comes
from appleid.apple.com → Sign-In and Security → App-Specific Passwords; it is
not the Apple ID password.

**Or an App Store Connect API key instead.** `notarytool` accepts
`--key <p8> --key-id <id> --issuer <uuid>` in place of the Apple ID pair, and
Tauri reads the same three as `APPLE_API_KEY_PATH`, `APPLE_API_KEY` and
`APPLE_API_ISSUER`. There are already four `AuthKey_*.p8` files in `~/Downloads`;
none of them authenticate as an *individual* key, so they are team keys and need
the Issuer ID from App Store Connect → Users and Access → Integrations, shown at
the top of that page. That value identifies the team rather than authenticating
anyone, so it is the cheaper thing to hand over — but the key also has to hold a
role that permits notarization, which is worth confirming before relying on it.

Once they are set, `gh workflow run iris-release.yml` can produce a customer
artifact. The strict verifier and publication marker prevent a release that is
unsigned, assigned to the wrong team or bundle, missing a ticket, or rejected
by Gatekeeper from being published.

## Windows

**Unsigned. There is a free path to zero warnings, and it is not a certificate.**

### How normal Windows apps actually avoid the warning

Two ways, and only one of them is available to a new app.

**The Microsoft Store.** Store apps are re-signed by Microsoft and carry full
reputation, so a Store install never shows SmartScreen at all. Microsoft's own
guidance leads with this: *"The simplest way to avoid SmartScreen warnings is to
publish through the Microsoft Store."* This is how a brand-new app gets a clean
first install on day one.

**Volume, over months.** Everything downloaded directly — Chrome, Zoom, Discord —
is warning-free because its signing certificate has years of clean installs
behind it. Microsoft is explicit that there is no shortcut: reputation *"can take
several weeks and hundreds of clean installs from a wide audience"*, and for
consumer endpoints there is **no mechanism to submit a file for review** to speed
it up. (An earlier draft of this document claimed otherwise. The malware-analysis
submission portal exists, but Microsoft scopes it to enterprise and managed
deployments, not to consumer SmartScreen reputation.)

So the honest ranking for someone arriving from a link with no patience:

| Route | First install | Cost |
| --- | --- | --- |
| Microsoft Store (MSIX) | **No warning, ever** | Free |
| Signed direct download | Warning until reputation builds, publisher name shown | ~$10/mo |
| Unsigned direct download (today) | Warning every release, forever | Free |

The gap between rows two and three is bigger than it looks: an unsigned file
builds reputation **per file hash**, so every release starts at zero and the
warning never goes away. A signed one builds reputation on the certificate, which
carries across releases. And on Windows 11, Smart App Control blocks unsigned
executables outright rather than offering a "Run anyway".

### The recommendation: Store first, signed download second

**Microsoft Store developer registration is now free** — the $19 individual and
$99 company fees were both removed in 2026, replaced by an identity check
(government ID plus a selfie). **Microsoft signs the MSIX during certification**,
so the Store route needs no certificate purchase at all.

Microsoft ships an official CLI with a Tauri-specific guide, updated 2026-07-23:

```powershell
winget install microsoft.winappcli --source winget
winapp init                    # writes Package.appxmanifest + Assets
winapp pack .\dist --cert .\devcert.pfx   # local testing only
```

Three things to know before committing to it:

1. **Tauri does not emit MSIX.** It builds NSIS and MSI only. `winapp pack` (or
   the community `@choochmeque/tauri-windows-bundle`) wraps the release exe.
2. **The `iris://` protocol has to move into `Package.appxmanifest`.** Tauri's
   deep-link plugin registers the scheme through the NSIS installer's registry
   writes; an MSIX declares protocol activation in its manifest instead. Without
   that, the handoff from the website silently stops working — which is the whole
   reason the desktop app exists.
3. **Store certification adds latency** to every release, and a separate package
   per architecture (x64, Arm64).

A direct download still has to exist — publikhq.com's whole pitch is a download
button, and sending someone to the Store is a detour. So the intended end state
is both: a Store listing as the frictionless Windows route, and a signed direct
download for everyone who will not use the Store.

### For the direct download: Azure Artifact Signing

Formerly Trusted Signing. **~$9.99/month** on the Basic tier (up to 5,000
signatures). Keys stay in Microsoft's HSM, so it works from a GitHub runner with
nothing but three environment variables. Individual developers in the US and
Canada are eligible with a government photo-ID check through Microsoft Entra
Verified ID; organizations need three years of verifiable history, which is why
the individual route is the relevant one here.

**Check availability first.** Microsoft capped new subscriptions during the
public preview, so eligibility is worth confirming before planning around it.

#### Why there is no .pfx path

Since June 2023 the CA/Browser Forum baseline requires code-signing private keys
to live on hardware meeting FIPS 140-2 Level 2 or equivalent. A certificate file
you can hold and hand to a CI runner no longer exists for new certificates. So
the options are a physical USB token (unusable in CI) or a cloud signing service
that holds the key in an HSM and signs on request.

EV certificates are worth naming only to rule them out: signing files with one
used to grant positive SmartScreen reputation by default, and that behaviour was
removed in 2024. Microsoft's current wording is that paying a premium for EV
solely to avoid SmartScreen warnings is no longer justified.

## The other apps

The catalog's macOS story is inconsistent and worth fixing on the same pass:

- **Simplicity** — signed and notarized. Opens clean.
- **NitroAI** — the workflow supports it and the secrets are set.
- **cue** — ad-hoc signed; its README walks people through right-click → Open.
- **WhimprFlow** — Apple-Development-signed only, not notarized, so it warns.

Whatever is decided for Iris should be applied to cue and WhimprFlow, since the
same certificate and the same five secrets cover all of them.

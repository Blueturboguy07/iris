# macOS login and permission continuity

## Customer contract

Customers install the publisher-signed Iris app. They do not create certificates, use Xcode, enroll in a developer program, disable Keychain protections, or run quarantine-removal commands. macOS still owns consent for Accessibility and screen capture. Iris explains those prompts and verifies the real permission checks.

Consumer artifacts must use the maintained publisher bundle identifier and Developer ID team, hardened runtime, notarization and stapled tickets. A local self-signed certificate or Apple Development Personal Team build is not a consumer release. Passing a local test does not waive the distribution gate.

## Account behavior

- First sign-in saves the refresh token in Keychain. Access tokens remain in memory.
- Routine startup, refresh and availability checks do not display password prompts.
- A denied read is not a missing login and must not delete the saved token.
- Recovery is an explicit user action. Explain Always Allow before a legacy Keychain prompt, then verify silent access instead of reporting success from a one-time interactive read.
- A failed save retains the newer in-memory token and reports that persistence is incomplete.
- Already-onboarded users can open Connections even if Accessibility or screen capture is unavailable. Feature permission guards still apply.

## Permission recovery

An enabled-looking System Settings entry does not prove Iris can use it. The app's actual permission checks remain authoritative. When Accessibility remains unavailable, an optional Already enabled? section explains removing only the stale Iris entry and adding the currently running copy. Open Settings and Show Iris are separate actions so opening one cannot immediately hide the other.

Do not automatically edit the TCC database, reset permissions for other apps, or grant broad Keychain access. A fresh consumer install and migration between signing identities are separate test cases.

## Required installed-app acceptance

Use two independently built, correctly signed artifacts from the same publisher team and bundle identifier, with different build numbers and hashes. Keep user secrets out of test reports.

1. Fresh user profile: install a quarantined, notarized release through the documented download path. Check first launch and consent explanations without Xcode or Terminal.
2. Sign in once. Confirm account identity is present and the save succeeded without logging credentials.
3. Quit and relaunch the same build. Verify account restoration without another Keychain prompt.
4. Replace it with the second artifact through the supported update path. Verify the new version and running path, account restoration and permission checks. Do not treat file copying as acceptance.
5. Exercise denied/cancelled Keychain access, a temporary network failure, and a failed token save. Confirm the login is preserved and recovery is reachable.
6. Test an enabled-looking stale Accessibility entry. Confirm repair guidance is reachable, shows the actual app copy, and only reports success after the real permission check passes.
7. Separately test a legacy signing-identity migration. A required one-time approval must be explained. It must not be confused with normal same-publisher updates.

The offline account suite, permission policy checks and mocked release verifier protect code paths. They do not establish completion of this installed-app matrix. Record actual results before declaring release acceptance.

## Local development observation, September 6

An Apple Development-signed 25.25 retained the account after explicit reconnection and a clean restart. Independently built 25.26, with the same Apple-issued team and a different CDHash, also restored the account. Both installed bundles passed strict signature validation. This establishes local development restart/update continuity only. Fresh-profile notarized distribution and normal publisher update acceptance remain outstanding.

The native permission-repair disclosure and Connections access during denied Accessibility were verified. Accessibility itself remained denied despite an enabled-looking System Settings entry; the remove-and-add repair has not yet been completed successfully. No TCC database or Keychain ACL was altered.

Follow-up on the same build: resetting only Iris's Accessibility grant with the supported tccutil command, adding `/Applications/Iris.app` through System Settings, and restarting resulted in Granted inside Iris. The equivalent Iris-only ScreenCapture reset and re-add required macOS Quit & Reopen. Final native UI reported Iris Active with the saved account intact; the composer and resting eye were visually confirmed. This is a completed local stale-entry recovery, not a reason to reset permissions automatically on startup. No direct TCC database or Keychain ACL edits were used.

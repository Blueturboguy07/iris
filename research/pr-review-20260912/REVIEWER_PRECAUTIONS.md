# Reviewer precautions

## Evidence rules

Use these labels in review comments:

- **Native-tested**: an isolated Iris Test app or registered native route was
  actually exercised, and the observed result is named.
- **Controlled fixture**: a disposable host, app, profile, or filesystem test
  exercised a narrow state transition.
- **Component-only**: source, unit, build, package, or deterministic checks.
- **WIP**: not sufficient to support an acceptance claim.

Never turn a source build, passing generated tests, signed bundle, successful
package, or native launch into a claim that the requested feature works. In
particular, no transfer row becomes green until a real export/import journey,
duplicate and copy behavior, persistence after target restart, and
restart-selected Undo are observed.

## Snapshot and upstream drift

This package is evidence for the tested experimental snapshot containing the
9fb installed baseline. It is not evidence for the current upstream/main tip.
Reviewers should expect conflicts when applying the draft PR. Reconcile them
manually, preserve the Test-only isolation and existing gates, then rebuild the
affected host and app before assigning any live status. Do not attribute an
upstream change to the tested snapshot, and do not call current main accepted
without a fresh installed journey.

## Safe Iris Test procedure

Open `iris-macos/leanring-buddy.xcodeproj` in Xcode and explicitly select the
shared **Iris Test** scheme. Build through Xcode, not terminal `xcodebuild`.
The Test configuration expects a local signing identity named
`Iris Local Code Signing`; another developer must configure their own identity.
No certificate, private key, or distribution signing permission is included.
Confirm the result is named Iris Test with bundle ID `com.publikhq.iris.test`
before launching. Do not run a normal Debug/Release product as a Test substitute.
The Test scheme has no attached Xcode test plan; use the documented standalone
component suites separately. A successful GUI build is not a suite run.

1. Use only the Iris Test application identity and a registered disposable Test
   project. Start from a recorded clean source baseline and verify the current
   registry binding before editing.
2. Use the existing host instructions in
   `iris-macos/tools/harness-feature-host/README.md` for source-only checks.
   Keep scratch profiles and temporary bundles disposable and separate from
   normal Iris, normal app profiles, and user data.
3. Keep the declared review, identity, source-cleanliness, cancellation,
   permission, byte, call, and time limits unchanged. Do not add a model call,
   bypass an independent review, or substitute an unrestricted terminal run.
4. For delivery, verify the exact Test project, source revision, branch/base
   relationship, bundle identity, payload identity, and durable receipt before
   quitting or replacing the app. A package is only an artifact until the
   installed app is opened and the requested behavior is observed.
5. For recovery, quit the Test app through the existing lifecycle route before
   a swap. After restore, relaunch the restored app, inspect the truthful result
   card, and verify source and app-document preservation. After restarting Iris,
   offer Undo only when the durable receipt, backup, installed payload, source,
   and registry still match. Changed, dirty, moved, ambiguous, or incomplete
   state must refuse without automatic replay.
6. Preserve the previous Test bundle and recovery records during review. Do not
   prune backups, delete receipts, reset source, reclone a target, or manually
   patch a generated feature to make a check pass.

The checked-in campaign helpers are reviewable technical WIP, not a turnkey
fixture installer. Portable helpers require explicit fixture locations and
fresh operator-declared hashes. They must fail closed when those declarations
are absent. Public portability changes do not make the old private native
declaration valid automatically. No paid model run is part of the quick checks.

## Rollback interpretation

- A review rejection means no candidate delivery. The previous installed app
  and source baseline should remain in place.
- A build, packaging, or launch failure is not feature acceptance. Report the
  failure and retain the recovery artifact; do not call it a successful update.
- A successful small-feature Undo is evidence only for that observed journey.
  It does not authorize an Undo claim for an unaccepted transfer.
- App documents are never an Undo target. Recovery restores the app/source
  checkpoint while preserving user data unless a separately observed contract
  says otherwise.
- If saved-version metadata exists but its backup or identity is unavailable,
  the UI must not offer Show or Undo as if the version were usable.

## Security and privacy boundaries

Do not include credentials, Keychain values, user chat text, raw downloaded
files, private fixture snapshots, personal IDs, run UUIDs, absolute machine
paths, or raw logs in a public PR. Redact any failure excerpt before sharing.
Do not use normal Iris, normal app profiles, or an unregistered target. Do not
grant broad home-directory, network, signing, or device permissions to make a
check pass. Existing Test localhost behavior is not evidence of a remote
service or physical-device route.

## Transfer-specific stop conditions

Stop and keep the candidate unaccepted if any of these occur:

- provenance is reduced to label, timestamp, position, or current content;
- repeated import changes the destination after the first unchanged import;
- a same-ID, different-content record overwrites or attaches to the wrong
  parent;
- a preview or cancel path mutates storage;
- a transaction failure leaves partial rows;
- the native route cannot use the actual export/import controls;
- target restart or Iris restart loses the imported graph;
- the reviewer lacks the consumer or source needed to validate the claim.

## Kneecap is not a transfer acceptance shortcut

Keep the Kneecap issue in its own operational report. A clean-copy refusal is
an intentional safety boundary when the checkout has local changes. It is not
evidence that a folder is absent, and it does not authorize reset, stash,
reclone, delete, or endless retries. The retry/resume correction must preserve
the dirty checkout and report the exact handoff needed from the user.

The repository documents a possible Mac-to-iPhone/Xcode route, but this review
has no proof of a signed release, Apple team/device trust, USB-C transfer, or
physical phone installation. Treat all of those as unverified.

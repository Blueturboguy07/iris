# Mobile shell handoff (2026-10-04)

From Akrit to blueturboguy07. Everything under `mobile-shell/` here is a snapshot of Akrit's working tree on 2026-10-04. It was never in git before. This folder (`mobile-shell/HANDOFF/`) is the context you need to take over the work: goals, current state with evidence, how to build and test, what is blocked, and what to do next.

Read in this order: this file, `goals/MOBILE_GOALS.md`, `specs/SPEC.md` (phone version history design), `specs/KEEPCOUNT_PUBLIC_API.md`, then `logs/`.

## What the mobile shell is
Iris Apps ("Kneecap" is the app shown to people, capital K): an iOS shell where non-technical people browse, install and run small local apps full screen and offline. Publik runs on the person's own device, no Publik compute servers. Swift package at `native/` (Core, Host, App entry), the Xcode project at `native/IrisMobileShellApp/`, contracts, publisher, website and web helpers beside it. Three starter apps ship inside (Kneecap, Nut AI, FreeHarmony; Lunara is small).

## Where the work stands (every line labelled by what kind of evidence it is)
Nothing here is "accepted". Package results, Simulator results and the owner's phone are separate facts.

**Keep-count (the newest feature).** The phone keeps 2 versions per app by default (current plus a fallback for Go back), customizable to 3, 5 or all. Core API: `VersionsKeptPerApp`, `NativeShellLibraryCoordinator.versionKeepCount`, `planVersionKeepCount`, `setVersionKeepCount`, preference key `iris.storage.versionsKeptPerApp`. Contract: `specs/KEEPCOUNT_PUBLIC_API.md`; design: `specs/SPEC.md` (sections 1.4, 1.7, 2.5, 5.1, 8).
- Package level (SwiftPM `swift test`, no Simulator): the whole `mobile-shell/native` package ran 648 tests with 0 failures in about 54 minutes, including the 1,000-app scale test (`logs/mobile-swift-test-whole-package-20261002.summary.txt`).
- Mutation check: 14 injected keep-count defects, 14 caught by the final tests (`logs/keepcount-mutation-pass-14-of-14.txt`, mutant descriptions in `specs/keepcount-mutants.md`).
- iOS typechecks (Core, Host, App; normal and debug configurations): 0 errors (`logs/ios-typechecks-20261002.txt`).
- Real-state migration test: copies a snapshot of the owner's phone app state and checks that migration keeps current plus fallback and loses nothing. It needs a state copy that is NOT in this repo (it holds the owner's app data). Without it set via `IRIS_PHONE_STATE_COPY` that one test fails; skip it with `--skip NativeKeepCountRealStateMigrationTests`.
- iOS Simulator UI run (native, simulator only, KeepCountUITests plus StorageUITests, an erased iPhone 18 Pro simulator): 11 of 14 pass (`logs/simulator-keepcount-3.summary.txt`). StorageUITests 6 of 6 pass. KeepCountUITests 5 of 8 pass. Three still fail: `testChoiceIsGlobalAcrossAppsAndFeaturesLedgerStillShowsAppBHistory` (line 162, "At global K=3 the second app's third revision remains kept by count"), `testRaisingCountDoesNotRestoreFreedVersion` (line 250, the freed historical row remains in the ledger) and `testResetToTwoPersistsAcrossSecondRelaunch` (line 186, no message). They are unclassified: first look at the xcresult attachments (export all of them, the screen dump shows element types), then decide test defect versus fixture versus product. Earlier runs (`logs/simulator-keepcount-1/2.summary.txt`) failed 8 of 14 for fixture and test reasons that are now fixed; the analysis is `specs/ROOT_sim-keepcount-1.md` (read it first, it explains the session-token, package-hash and cap-order bugs and why the amount regex, the over-limit predicates and the default-selection oracle must not be loosened).
- NOT done: the build for the owner's iPhone with keep-count (phone build 3; it waits until the Simulator class is green or its failures are ruled), the MV6 Simulator run, and a ruling on a pre-existing iOS 17 API typecheck failure in `AccessibilityUITests.swift` (`performAccessibilityAudit` needs iOS 17, the project targets lower).
- Known caveat: `IrisMobileShellUITests` need a clean simulator state; session tokens must be 8 to 40 characters (the app now fails loudly in DEBUG for anything else).

## How to build and test
- Package tests: `cd mobile-shell/native && swift test` (the 1,000-app stress test alone takes about 28 minutes; filter with `--filter`).
- iOS typechecks without signing: `HANDOFF/mobile-ios-typecheck.sh` and `HANDOFF/mobile-ios-typecheck-debug.sh` (set `IRIS_REPO` to the repo root; lightly adapted from Akrit's scratch tooling).
- Simulator UI classes: `HANDOFF/mobile-sim-run.sh <label> KeepCountUITests StorageUITests`. Edit the `SIM=` line to your simulator UDID (`xcrun simctl list devices`); use ONE simulator only and erase it first for clean state (`xcrun simctl erase <udid>`). The scheme is `IrisMobileShellUITests`.
- The Starter app packages (about 340 MB) are NOT in git; see `EXCLUDED_BIG_FILES.md` for the list and sha256, get them from Akrit by file transfer.
- Never run terminal `xcodebuild` against the macOS app (Akrit's rule: it breaks macOS privacy grants). The iOS Simulator and the iPhone are fine from the terminal.

## Goals and what is blocked on whom
See `goals/MOBILE_GOALS.md`. In short: G7 (mobile shell functionality, the key deliverable), G8 (store redesign), G0 (phone test on the owner's iPhone), and the phone half of G2 (version history: one app per app, a Features page, space efficient at 3, 100 and 1,000 apps, user data never lost). Owner-only: anything on the owner's real iPhone or Apple ID, signing and App Store steps, TCC prompts.

## How Akrit has been working (so the logs make sense)
- A builder never writes tests. A separate spec-only author writes tests from the spec and the public contract. A separate blind tester uses the product like a person. Every new test suite gets a mutation check on a scratch copy (inject realistic defects, the tests must fail).
- Report package passes, Simulator passes, phone runs and real user journeys as separate facts. Never call a source or simulator pass "accepted".
- No em dashes anywhere (chat, code, comments, commits, docs).
- No push, PR, tag, deploy, App Store step or purchase without Akrit. The logs under `logs/lanes-mobile-units-excerpt.log` are the unit history (START and DONE lines with the one-line outcome); they are Akrit's orchestration tooling output, not something you need to run.

## Suggested first steps
1. Build, run the package tests and the iOS typechecks on your machine to confirm the baseline.
2. Fetch the Starter packages from Akrit (see `EXCLUDED_BIG_FILES.md`).
3. Run `KeepCountUITests` on a freshly erased simulator, export the xcresult attachments for the three failures and classify them.
4. Fix per the roles above, rerun, then coordinate phone build 3 with Akrit (his phone, his Apple ID and team).
5. Rule on the `AccessibilityUITests.swift` iOS 17 availability error.

Questions about owner decisions: ask Akrit. Open owner decisions that touch mobile: the Simulator keep-count failures are not a decision; the captions speech-to-text capability for web apps is still a proposal, not decided.

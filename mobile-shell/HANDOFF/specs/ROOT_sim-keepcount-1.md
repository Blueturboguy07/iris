# ROOT CAUSE: sim-keepcount-1 (KeepCountUITests 6 of 8 failed, StorageUITests 2 of 6 failed)

Analyst: read-only (Sonnet 5.5, 2026-10-03). Nothing was edited, built or run. Evidence read: sim-keepcount-1.out and sim-keepcount-2.out, the exported attachments under lanes/wf/ROOT_sim-keepcount-1-evidence/ (frames/*.png, e_Raising and g/h hierarchy .txt), the test, fixture and product sources, SPEC.md, MV6-ui-tests/FIXTURE_CONTRACT.md, and earlier gate results.
Tags: VERIFIED = seen in a file or tool output (cited). INFERRED = deduced, not directly observed.
Paths: T = <repo>/mobile-shell/native. Scratch = <scratchpad>.

## 0. Bottom line

Three independent root causes explain all 8 failures. None is a product behavior defect against the SPEC.

| Cause | One line | Failures |
|---|---|---|
| RC1 STATE_LEAK, test-side | KeepCountUITests builds a session token of 41 characters; the app accepts only 8 to 40, so it silently ignores the token and every test shares one legacy namespace and one preferences suite. | testDefaultSelectionIsTwo, testFourChoices, testResetToTwo, plus the leak part of testConfirmLowering and testRaising |
| RC2 FIXTURE, product-side | The storage-keep-count fixture installs nothing (library is empty: "Zero KB used across 0 apps"). Its package identity hash is computed with JSONSerialization, which escapes "/", so the real validator probably rejects every package, and the seed code swallows the error. | testChoiceIsGlobal, testConfirmLowering, testRaising |
| RC3 FIXTURE race + ENV | storage-full now seeds into a fresh namespace on every launch (cold first install), takes longer than the 60 s synchronous bound, and lowers the cap as its LAST step. Storage loads mid-install at the default 2 GB cap, so no over-the-limit sentence. | testOverTheCap, testKeepAtMost |

Plus one TEST_DEFECT hidden behind RC2: testRaisingCountDoesNotRestoreFreedVersion looks for Features ledger rows while still on the Storage screen.

## 1. Key evidence

1. VERIFIED, the token is rejected. KeepCountUITests.swift:21 builds "kcui-" + UUID().uuidString.lowercased(): 5 + 36 = 41 characters. T/Sources/IrisMobileShellCore/MyApps/MyAppsUITestSeed.swift:60 requires 8...40 characters, else fixtureSessionToken returns nil. NativeUITestFixtures.swift:111-114 then falls back to the legacy namespace "ui-test-storage-keep-count", shared by every test and never swept. Other test files use addFixtureSession() (NativeUITestFixtureSupport.swift:174, "s" + 12 characters = 13), which is valid.
2. VERIFIED, where the preference lives. Key iris.storage.versionsKeptPerApp (NativeShellLibraryCoordinator.swift:669), saved in UserDefaults suite "IrisMobileShell.<namespace>" (IrisMobileShellApp.swift:91), a plist in the app container's Library/Preferences. It survives terminate and relaunch and test to test. It is NOT reset per launch. seedKeepCountFixture (NativeUITestFixtures.swift:232-289) reads priorChoice (238), sets keepAll while seeding (240), then restores priorChoice if one exists (275-276) and only otherwise applies the --iris-ui-test-keep-count seed (277-278) or removes the key (280). So a leaked value always beats the seed argument. No launch argument resets it; --iris-ui-test-preserve-state (234) only skips seeding. The fixture contract (FIXTURE_CONTRACT.md line 10) says a new session token must start clean, which only holds if the token is accepted.
3. VERIFIED, the alphabetical order explains every observed value (run 1 started on an erased simulator, order from sim-keepcount-1.out lines 990 to 1637):

| # | Test | Start value | Why | End value |
|---|---|---|---|---|
| 1 | ChoiceIsGlobal | none, default 2 | clean | 3 (it chose 3, then failed at app B row) |
| 2 | ConfirmLowering | 3 | seed "5" ignored, prior 3 wins | 3 (stopped at the card) |
| 3 | DefaultSelection | 3 | leaked from #1/#2 (log 1255: value=3) | 3 |
| 4 | FivePersists | 3 | leaked | 5 (chose 5, passed, relaunch reads 5) |
| 5 | FourChoices | 5 | leaked (log 1429: value=5); first tap on "2" is a lowering so it shows a card and value stays 5 | 5 |
| 6 | NotNow | 5 | leaked 5 (seed 5 would agree, so it passes by luck) | 5 |
| 7 | Raising | 5 | leaked | 2 (confirm tapped, result shown) |
| 8 | Reset | 2 | seed "5" ignored, prior 2 wins (log 1635: expected K=5, value=2) | 2 |

   Run 2 (the 8-test rerun, same simulator, not erased) starts from run 1's final value 2: #1 sets 3, #2 leaves 3, #3 reads 3 (matches "value 3 in both runs"), #4 FourChoices reads 3 (matches "3 in run 2"). The leak model reproduces all four numbers.
4. VERIFIED, the keep-count library is empty. frames/b_confirm_tail.png and a_choice_tail.png show My apps "Make this space yours" and "Storage, Zero KB used across 0 apps", Storage "Iris apps on this iPhone Zero KB", "Nothing to free right now", "Nothing to free yet." e_Raising hierarchy (BC4F2129-...txt): device line "Iris apps use Zero KB", identifier iris.store.storage.empty, result "Kept 2 versions per app. Nothing could be freed because the other versions are protected or unavailable to download." This is in the very first test on an erased simulator, so it is not leftover state.
5. INFERRED (strong), why the library is empty. NativeUITestFixtures.swift:381 computes contentHash as sha256 of JSONSerialization(identityPayload, options: [.sortedKeys]) (json() at 461-463). The payload contains mediaType "text/html" (372). JSONSerialization escapes "/" as "\/" unless .withoutEscapingSlashes is passed. The real canonical encoder does not escape "/" (SecurityPrimitives.swift:259-297, quote() default branch). DeliveryPackageV1Validator.swift:121-141 recomputes identity with that canonical encoder and throws invalidRevisionIdentity on a contentHash mismatch. reviewImport is the first call (NativeUITestFixtures.swift:249), so the first throw skips everything, and the catch (282-288) swallows it silently. manifestHash is unaffected (no "/" in the manifest), so only contentHash and revisionId are wrong. MyAppsUITestSeed and the Starter chains avoid this because they use the real revisionIdentity or real packages. Not directly observed (no app log, and no Simulator run is allowed to me). Launch timing agrees with an early return: keep-count launches go idle at 10 to 15 s (log lines 999, 1167, 1225, 1267), inside the 20 s legacy bound, with no apps.
6. VERIFIED, the keep-count fixture was never run natively before this run. wfm-r1-mv6-fixtures-integrate.json gates: "Source-level checks only, no Simulator run, no phone run; seeding behavior is unproven until the main session runs the UI tests."
7. VERIFIED, Storage tests block 60 s in launch. Every StorageUITests launch shows "Wait for ... to idle" at t = 61.4 to 61.9 s (log lines 1650, 1715, 1773, 1831, 1913; automation session set up at about 1.7 s). That is the 60 s semaphore bound in NativeUITestFixtures.swift:157-158 (session token present means 60 s) expiring before the seed finished. The cap is the last seed step (201, after installMissing at 198).
8. VERIFIED, Storage read mid-install. h_StorageOverCap hierarchy (4FCE2545-...txt): cap row "Keep at most 2 GB of app code" (fixture wanted 256 KB), total 99.3 MB, Kneecap "60.1 MB app code . 6 versions". g_StorageKeepAtMost hierarchy (E3F1A46E-...txt): total 70.2 MB, Kneecap "40.3 MB . 4 versions". Two fresh launches show different amounts for the same app, so the install was still running. Both hierarchies also contain iris.store.storage.keep-count.error (StoreStorageView.swift:89, refresh() catch), meaning refresh threw while the store was busy. In both, the over-limit sentence needs usage.totalCodeBytes minus promised > capBytes (StoreStorageView.swift:242), false at a 2 GB cap with 70 to 99 MB installed.
9. VERIFIED, the product default selection is right. The h_StorageOverCap UI snapshot shows the keep-count control with accessibility value "2 (Default)" when no preference is set. The sheet frames (a_choice_mid, e_raising_sheet) list "2 (Default)", "3", "5", "Keep all while there is room", "Reset to 2 (Default)", "Done", and the confirmation card text equals SPEC 1.7 word for word except the amount.

## 2. Per failure

### F1 testChoiceIsGlobalAcrossAppsAndFeaturesLedgerStillShowsAppBHistory (KeepCountUITests.swift:154)
- Class: FIXTURE (RC2). Confidence: high that the library was empty (VERIFIED, evidence 4); medium-high (about 75%) on the slash-escape cause (INFERRED).
- Why: the app B row iris.store.storage.app-row.publik.nut-ai cannot exist with zero apps. Not a leak failure (this was the first test), and the oracle matches the product (identifier format confirmed by the Kneecap row in the h hierarchy).
- Smallest fix: NativeUITestFixtures.swift:462, json(): pass options [.sortedKeys, .withoutEscapingSlashes]. Also stop swallowing the seed error (see 3.2).
- Owner: product builder (the fixture is DEBUG product code under Sources/IrisMobileShellHost). Rerun on a clean simulator: required to confirm.

### F2 testConfirmLoweringWaitsForPruneAndReportsTheConfirmedAmount (line 209)
- Class: FIXTURE (RC2) primary, STATE_LEAK (RC1) secondary (it started at K=3, not the seeded 5, so line 213 would have failed next).
- Why: card text is exactly SPEC 1.7 with amount "Zero KB" because plan.bytesReclaimed is 0 for an empty library (StoreStorageView.swift:145-146, ByteCountFormatter renders 0 as "Zero KB").
- Fix: the RC2 fix plus the RC1 token fix. No test change.
- Owner: product builder (RC2), test author (RC1). Clean rerun: required.

### F3 testDefaultSelectionIsTwo (line 113, value=3)
- Class: STATE_LEAK (RC1). Confidence 95%. The product reads "2 (Default)" with no preference (evidence 9); 3 came from test #1 (table above).
- Fix: KeepCountUITests.swift:21 use a token of at most 40 characters, for example "kcui-" + String(UUID().uuidString.lowercased().prefix(12)), or reuse addFixtureSession().
- Owner: spec-only test author. Clean rerun: confirm after the fix (the simulator is already erased, so it is enough to run once).

### F4 testFourChoicesKeepExactCopyIdentifiersAndAccessibilityAtXXXL (line 141, value=5 run 1, 3 run 2)
- Class: STATE_LEAK (RC1). Confidence 90%.
- Why: starting at 5 (or 3), the first tap on option "2" is a lowering, so the confirmation card opens and the selected value stays. Lines 133, 134, 138 and 139 (four options, order, exact labels, hittable at XXXL) passed for the first key, because the failure is at 141 (VERIFIED, log 1429). Later keys (3, 5, all) at XXXL are untested so far, so a clean run is the real proof.
- Fix: the RC1 token fix. Owner: spec-only test author. Clean rerun: required.

### F5 testRaisingCountDoesNotRestoreFreedVersion (line 245)
- Class: FIXTURE (RC2) plus TEST_DEFECT plus STATE_LEAK (RC1).
- Why (test defect, VERIFIED by source): at line 244 the test queries identifiers "iris.store.versions.row.*" right after the result sentence, while still on the Storage screen. Those identifiers are produced only by Versions/FeaturesView.swift (Versions.row, NativeAccessibilityIdentifiers.swift:290; Storage uses iris.store.storage.app-row.*). The call openStorage(app) on line 248 shows the author expected to be on a Features screen, but no navigation to it exists between 243 and 244. So even with a perfect fixture this assertion cannot hold. Confidence 85%.
- Smallest fix (test): after the result appears, scrollUntilExists and tap storageAppRow(appA), wait for NativeStoreIdentifiers.versions, find the "Not on this iPhone" row, record its identifier, go back, then continue to the raise step. Add the same fixture fix (F1) first.
- Owner: spec-only test author (test), product builder (fixture). Clean rerun: required.

### F6 testResetToTwoPersistsAcrossSecondRelaunch (line 184, expected 5, value 2)
- Class: STATE_LEAK (RC1). Confidence 95%. Seed "5" is ignored because test #7 left 2 and priorChoice wins (NativeUITestFixtures.swift:275-276).
- Fix: RC1 token fix. Owner: spec-only test author. Clean rerun: confirm.
- Note: with an empty library this test could still pass, because Reset on an empty library gives the "Nothing could be freed" result. A pass of this test does not prove the fixture.

### F7 testOverTheCapTheScreenSaysInstalledAppsUseMoreThanTheLimit (line 109) and F8 testKeepAtMostSettingOffers... (line 139)
- Class: FIXTURE race (RC3) with ENV amplification (cold, just-erased simulator, first-time install of about 100 MB of Starter chains). Confidence 85%. Not a product defect: the product sentence "Your apps' kept versions use X, more than the Y limit. Iris keeps them all. ..." (StoreStorageView.swift:344) matches the test predicate (more than the, limit, Iris keeps them all). Not a test defect: the oracle follows SPEC 1.4.
- Why: evidence 7 and 8. The seed outlives the 60 s bound and writes the cap last, so Storage reads the 2 GB default, and the sentence needs total minus promised above the cap.
- Smallest fix (fixture): in NativeUITestFixtures.seed, call setGlobalCodeCapBytes(256 * 1024, ...) BEFORE installMissing (move lines 200-202 above 195-198), so the cap is already low whenever Storage loads and the late write cannot overwrite a cap the test chose later (KeepAtMost picks 4 GB; a late seed write would clobber it). Prefer also making seedSynchronously wait for completion of session seeds when it is storage-full. Two things the builder must check natively: (a) with a 256 KB cap active during install, no automatic prune deletes the Starter history that the free-up tests need (storage-full returns no catalog-offered revisions, NativeUITestFixtures.swift:130 guard, so the "never free what the catalog cannot offer" rule should make nothing eligible, but this is INFERRED); (b) install speed (see Q2).
- Owner: product builder. Clean rerun: required.

## 3. Special questions

### Q1 Is "Zero KB" the right sentence when lowering frees nothing? Does the test wrongly demand a nonzero amount?
- "Zero KB" is the honest rendering of 0 bytes by ByteCountFormatter (StoreStorageView.swift:145), and SPEC 1.7 says only that the amount is "formatted for display". So the product is not wrong for a case where nothing can be freed.
- The test is not wrong either. Its regex (KeepCountUITests.swift:88) needs digits and a unit, and FIXTURE_CONTRACT.md line 25 states that for this fixture the planned and completed freed allocation must be greater than zero (eight Kneecap and three Nut AI downloadable revisions, only current plus fallback protected). A correct fixture at K=5 on disk with eight Kneecap revisions frees six, which is a few tens of KB (4 KB blocks), which prints as "NN KB" and matches.
- So the fault is the fixture failing to seed freeable versions (RC2). Do not loosen the regex. Minor note: ByteCountFormatter prints "1 byte" in the singular, which the regex ("bytes") would reject; unreachable here.

### Q2 Did the two Storage over-limit tests pass before the keep-count work? What changed?
- VERIFIED history:
  - 2026-09-30 about 03:20 (round6 mobile-sim round1, lanes/results/mob-run-1.json and docs/plans/20260928-all-routes/round6/mobile-sim/round1/RUNS.md lines 614 and 639): both failed with the same two messages, because product code then used the low-device-space banner for cap overflow (FIXES.md lines 42 to 43, fix P10).
  - 2026-09-30 13:59 (r3, lanes/results/gates/r0105-mob-fix-1-t3-r3-3.out lines 36 to 57): the failing list has StorageUITests testKeepAtMostSetting... but NOT testOverTheCap..., so testOverTheCap passed. testKeepAtMost reached the 4 GB choice and cleared the over-limit sentence, then failed only on the cap-row text "4.29 GB" (FIXES.md line 241, since fixed at line 193). So the sentence was on screen at r3 under the old persistent "ui-test-storage-full" namespace.
- What changed between r3 and now:
  1. Fixture sessions (NativeUITestFixtureSupport.swift mtime 2026-09-30 17:08, wfm-r1-fixture-session 17:26 and later): launchWithFixtures now adds a fresh token per launch, so every storage-full launch is a cold first install, where it used to be an already-installed no-op under a persistent namespace (FIXES.md line 90 describes the old persistent namespace). This is the primary change.
  2. Keep-count work (policy mtime 2026-10-01 20:01, coordinator 20:09, StoreStorageView 2026-10-02 01:30, fixture 03:03): added root-settled assertions and a global prune plan to Storage refresh(), so a refresh that overlaps an in-flight seed throws (the error text visible in both hierarchies). INFERRED that this increased sensitivity.
  3. NOT changed: default cap is still 2 GB (NativeStorageRetentionPolicy.swift:175); default count K is 2 (NativeShellLibraryCoordinator.swift:671-675), but storage-full has no catalog-offered revisions, so the count rule frees nothing there and cannot explain these failures.
- A clean-simulator rerun is not needed to explain it (the 60 s block is VERIFIED), but it is needed to confirm the fix.

## 4. Secondary findings (not causes of the 8)

1. NativeUITestFixtures.swift:125-133: the comment says FreeHarmony is intentionally absent from the downloadable set (local-only, FIXTURE_CONTRACT.md line 21), but the code looks it up in KeepCountFixture.apps, which contains FreeHarmony, so its one revision is reported as downloadable. Harmless for its current revision today, but the local-only rule is not what is tested.
2. seedKeepCountFixture returns before sweepStaleSessions (172), so keep-count session namespaces and suite plists are never swept once tokens work (storage and leftover cost only).
3. The keep-count control is disabled while isLoading (StoreStorageView.swift:416, .disabled(... || model.isLoading)); tests tap after only waitForExistence, so a slow refresh turns a tap into a silent no-op. Low risk after the fixes, flake risk before them.
4. Passing tests testFivePersistsAcrossTerminationAndRelaunch and testNotNowLeavesFiveSelectedAndShowsNoResult are not evidence that the seeded library works: both pass on an empty library (NotNow passed because 5 had leaked in from test #4/#5).
5. Selecting the already saved value (choose 2 when K is 2) runs the prune without a confirmation (StoreStorageView.swift:141, 153), which matters only if disk holds more than K per app; the fixture creates exactly that state (default 2 with all revisions on disk). Not a SPEC conflict (SPEC 1.7 confirms only a lowering), just a behavior to know about when writing more tests.

## 5. Ranked next actions

1. Test author: RC1 token. KeepCountUITests.swift:21, token of at most 40 characters (13 characters is the house style). Clears F3, F4, F6 and the leak part of F2 and F5. One line.
2. Product builder: RC2 fixture. NativeUITestFixtures.swift:462 add .withoutEscapingSlashes to json(); make the seed catch (282-288) loud in DEBUG (precondition or a visible marker) so a bad package can never again look like an empty library; fix FreeHarmony lookup (125-133). Clears F1, F2 and unblocks F5.
3. Product builder: RC3 fixture. Set the storage-full cap before installMissing and make session seeding finish before the app mounts (or document a longer bound); confirm natively that early cap does not prune the starter history. Clears F7 and F8.
4. Test author: F5. Add the navigation to Kneecap's Features screen before querying "Not on this iPhone" rows (see F5). Spec-only: the SPEC 1.7 and FIXTURE_CONTRACT.md line 36 give everything needed.
5. Builder (optional hardening): in DEBUG, a launch with --iris-ui-test-session whose token is invalid should fail loudly instead of falling back to the shared legacy namespace (MyAppsUITestSeed.swift:56-62 caller side). This would have turned RC1 into an immediate, obvious failure.
6. Then one native rerun of both classes (14 tests) on the erased simulator, quote the xcresult, and report as simulator-only. Items still unproven by this analysis and to check on that run: equality of the confirmation amount and the result amount (SPEC 5.1 line 12), all four choices at XXXL beyond the first key, Nut AI rows at K=3, the cap sentence after the cap-first change.
7. Do not loosen the amount regex, the over-limit predicates or the default-selection oracle: all three match SPEC and the product.

A rerun on a clean (erased) simulator is needed to confirm every fix above; it is not needed to explain the failures, which are explained by the evidence listed. After the token fix the clean-simulator requirement is only about leftover legacy state ("ui-test-storage-keep-count"), and the simulator is already erased.

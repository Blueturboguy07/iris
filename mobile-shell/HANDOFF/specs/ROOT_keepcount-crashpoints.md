# Root cause: 49 failures in testEveryPublicCrashPointPreservesHashesUntilSettlementThenAllowsOneKeepTwoPrune

Analyst: read-only, static reading only (no build, no test, no simulator). Evidence read: `orch-scratch/lanes/results/gates/r0105-wfm-r1-keepcount-tests-fix3-t4-r4-1.out` (called EV below, line numbers are EV lines). Test file: `mobile-shell/native/Tests/IrisMobileShellCoreTests/NativeKeepCountSettingTests.swift` (T). Product paths: `mobile-shell/native/Sources/IrisMobileShellCore/` (S). Tags: [V] verified in source or evidence, [I] inferred.

## Result table

| Family (T line) | Count | Class | Confidence | Owner | One-line fix |
|---|---:|---|---:|---|---|
| A: "expected injected swap failure" (361) | 2 | TEST_DEFECT (inapplicable pairs), helped by a contract overclaim | 78% | spec-only test author, plus contract owner for one table row | Rollback target must be older than the fallback when the point is afterCheckoutBuilt; skip (undo, afterCheckoutBuilt); fix the 7.3 table row |
| B: "interruption cannot rewrite ... hashes" (367) | 9 | TEST_DEFECT (oracle hashes mutable files; undo baseline taken before the arrangement step) | 95% | spec-only test author | Hash only `objects/**` and `manifests/**/rev-*.json`, assert no revision manifest vanished, take the baseline after arrangement. 2 of the 9 disappear with A |
| C: "read-only refusal cannot prune" (379) | 35 (not 29) | TEST_DEFECT (stale baseline: compares to the pre-crash snapshot, but the crash itself already moved the pointer) | 93% | spec-only test author | Compare each barrier iteration to `interruptedHashes` (post-interruption), not `beforeHashes` |
| D: "refused prune preserves fixture hashes" (390) | 3 | TEST_DEFECT (same stale baseline; recovery attempts legitimately rewrite undo-offer and ledger files) | 92% | spec-only test author | Immutable-object oracle against the post-interruption snapshot, plus blocks non-decreasing |

Genuine product defects among the 49: none found (static, 90% confidence, [V] on every prune-capable call path, see section 4). No prune, tombstone or object deletion can have happened in any of the 49 cases. Not proven by a run (nothing was executed).

## 1. What hashes(at:) covers, and which files legitimately differ (question 1)

[V] `KCAWorld.hashes(at:)` (T 582 to 590) SHA-256s every regular file under `storeRoot` at any depth. That is `objects/**`, `manifests/**`, `checkouts/**` (content tree plus `checkout.json`), `state/<app>/<project>/*` (active.json, journal.json, undo-offer.json, features.json, pins, nonces, store-format) and `gc/*` (refs.sqlite and its side files, `dirty`). Failure messages at 367, 379 and 390 call it the "manifest/content hashes" but the implementation compares the whole root. The intent (SPEC 2.5, 5.1 check 18, contract 7.3: "revision content/manifest hashes", "journal/pointer changes from attempted recovery are not pruning") is only the immutable part.

Immutable by construction [V]: `objects/**` (content addressed, written once, `NativeObjectStore`), and `manifests/**/rev-sha256:*.json` (written once by tmp plus rename; a prune turns one into `.json.tomb` then `.json.freed`, `NativeVersionManifests.swift:316 to 334`). Everything else is rewritten by a swap or by recovery:

| File | Written by | Source |
|---|---|---|
| `state/*/active.json` | `writeActive`, atomic rename, then the fault fires AFTER the rename | `Versions/NativeVersionJournal.swift:66 to 76, 90 to 101` |
| `state/*/undo-offer.json` | `finishSwapCleanup` for rollback, and again by recovery (`writeUndoOffer: journal.op == .rollback`) | `Versions/NativeVersionStore.swift:468 to 472, 537 to 540` |
| `state/*/features.json` | ledger append "Went back" for rollback (at :473), again on every recovery run of a rollback | `NativeVersionStore.swift:473 to 481` |
| `checkouts/**/checkout.json` | `verify()` rewrites `verifiedAt` (millisecond ISO) every time an existing checkout is re-verified, which is every `build` over a retained checkout (rollback to fallback, undo) | `Versions/NativeVersionCheckout.swift:58 to 62, 111 to 113` |
| `checkouts/**` trees | deleted by `cleanupCheckouts` after journal delete and by recovery | `NativeVersionStore.swift:490, 528, 552 to 557` |
| `gc/refs.sqlite`, `-wal`, `-shm` | any open SQLite connection (the test's own `facade` plus the registry store used by the coordinator) | `Versions/NativeVersionRefs.swift:25 to 45` [I for checkpoint timing] |

Per (point, operation) what changed against the pre-fault baseline `beforeHashes` (T 349) [V from the code order in `performSwap`, `NativeVersionStore.swift:422 to 454`, plus EV pass/fail pattern):

- afterJournalWritten, activate or rollback: only a NEW `journal.json` (not in the baseline). EV: passes 367. Consistent.
- afterJournalWritten, undo: the arrangement `rollback` (T 358) ran un-faulted AFTER `beforeHashes` was taken. It rewrote active.json, features.json, undo-offer.json and second's checkout.json. EV 24: fails. Pure baseline-position defect.
- afterCheckoutBuilt, activate: new checkout only. EV: passes 361 and 367.
- afterCheckoutBuilt, rollback and undo: the point is never reached (section 3), the operation COMPLETES, pointer moves, so 367 fails (EV 26, 28). Knock-on of family A.
- afterPointerWrite and beforeJournalDelete, all three operations: active.json now names the new revision (activate: only that file differs). EV 29 to 32, 46, 60 fail. Rollback and undo add undo-offer, features and checkout.json.

So for activate the ONLY mutated baseline key is the pointer the point is named after. A test that hashes `active.json` and then crashes "after pointer write" cannot pass. [V]

## 2. What each refusing call writes before it refuses (question 2)

Contract text [V] (`KEEPCOUNT_PUBLIC_API.md` section 3 and 7.3): planning "throws this error rather than implicitly recovering"; an explicit prune or apply "can run normal recovery first; if it remains unsettled, it throws this error and makes no prune or preference mutation"; "Compare stored revision hashes against the post-interruption baseline; journal/pointer changes from attempted recovery are not pruning." SPEC 2.5: "Do not free anything while a journal or migration is unsettled."

- `world.coordinator(versionFault:)` [V]: `NativeShellLibraryCoordinator.init` stores fields only (`NativeShellLibraryCoordinator.swift:227 to 245`). No I/O.
- `planVersionKeepCount` [V]: `retentionSnapshots()` (:747) does read-only identity discovery (:1053), builds a `NativeRevisionStore` (no I/O in its init, `NativeRevisionStore.swift:156 to 192`) and calls `assertStorageSettled()` (:750), which only checks `journal.json` and `migration.json` existence (`NativeRevisionStore.swift:429 to 457`, throw at :448). It throws `recoveryRequired` before reading manifests. No recovery, no write. Each barrier iteration at T 371 to 379 is therefore a no-op on disk, so `afterPlan == interruptedHashes` must hold exactly (whole root, SQLite side files aside).
- `pruneStorage(identity:)` and `setVersionKeepCount` [V]: `withStorage` runs `prepareObjectStorage()` BEFORE the operation closure (`NativeRevisionStore.swift:1153 to 1160`). With store-format 2 this calls `settleVersionStorage()` (:1209), which calls `versionStore.recoverIfNeeded(..., fault: versionFault)` (:1224). Writes before it refuses: owned-directory creation and SQLite open (`prepareVersionStoreNamespaces`, :1118 to 1150), orphan temp sweeps (`objects/tmp-*` older than 600 s, checkout `tmp-*`), `recoverTombstones` (no-op, no tombstone in these fixtures), manifest `tmp-*` cleanup, and for a swap whose pointer already moved `finishSwapCleanup`: rewrite undo-offer.json plus append a ledger row (rollback only), THEN `fault.fire(.journalWrite_beforeJournalDelete)` throws `NativeVersionSimulatedCrash` (`NativeVersionStore.swift:537 to 540, 484`). The prune body (`pruneStorageImpl` :825) and `applyVersionKeepCount` (coordinator :701, `preferences.set` at :713 only after the preflight at :707 to 709) are never reached. [V]
- A refusing call must leave: no manifest or object removed or changed, no tombstone, no preference write (T 388, 398 already assert this and pass), journal still present, and the world recoverable (T 400 to 405 pass: fault-free `recoverIfNeeded` then `.clean`). It may leave rewritten recovery files (undo-offer.json, features.json, checkout.json). It must NOT be asked to leave the pointer at its pre-crash value.

## 3. Is journalWrite_afterCheckoutBuilt reachable for rollback and undo (question 3)

[V] Only when a checkout is actually built. `NativeVersionCheckoutBuilder.build` returns early after `verify` when the checkout directory already exists (`NativeVersionCheckout.swift:58 to 62`); the fault fires only at :97 after the rename of a freshly built tree. This matches SPEC 2.3 step 2 ("already present from an earlier switch: verify it instead of rebuilding").

In the T fixture (`first`, `second`, `third` activated through the coordinator, `fourth` staged): after `activate(third)` the retained checkouts are exactly {third (current), second (fallback)} (`finishSwapCleanup` keep set, `NativeVersionStore.swift:489`).
- activate(fourth): no checkout, builds, point reached. EV: passes 361. [V]
- rollback(second), T 356: second's checkout is retained, so verify only, point NOT reached, the rollback completes. EV 25: "[afterCheckoutBuilt, rollback] expected injected swap failure". [V, exact match to evidence]
- undo, T 358 to 359: after the arrangement rollback the checkouts retained are {second, third}; undo's target `third` is retained, so again verify only. EV 27. [V] By construction an undo target is always the previous current, whose checkout is always retained, so (afterCheckoutBuilt, undo) is unreachable in any normal flow, not just this fixture. [I for "any"]
- rollback to `first` (older than the fallback; `isAncestor` allows it, `NativeVersionStore.swift:409 to 420`): its checkout was deleted when `third` was activated, so it IS built and the point IS reached. [V]

Existing MV1 matrix [V]: `VersionsCrashPointTests.testEverySwapCrashPointRecoversToAConsistentStore` (lines 72 to 128) runs all four swap points for ACTIVATE of a fresh v2 only, with `XCTFail` if it does not throw. Rollback and undo appear only in `VersionsHardeningTests.testForceQuitPersonaAcrossSeededSessions` (lines 297 to 313), where an un-thrown fault is accepted silently (`catch is NativeVersionSimulatedCrash` with no failure otherwise). `HANDOFF.md:149` records that the MV1 builder moved the fire to after the rename so "built" means built. The Python model (`tests/oracle_store.py:429 to 430`) fires the point on every swap regardless, which is a model difference, not product behavior.

Applicable pairs (product as built): activate x all 4 points; rollback x all 4 points IF the target checkout is not retained (target older than the fallback) else x 3 (not afterCheckoutBuilt); undo x 3 (not afterCheckoutBuilt). The contract row for `.journalWrite_afterCheckoutBuilt` ("Same three swap operations", `KEEPCOUNT_PUBLIC_API.md` 7.3) overclaims. 7.3 also says "Test each journal point with each of the three swap operations", which is the instruction the author followed.

## 4. Is any of the 49 a real prune (question 4)

No [V]. The only code that removes revision content is `NativeVersionGC.free`/`finishRemovals` (`Versions/NativeVersionGC.swift:36 to 107`), reached only through `NativeVersionStore.freeVersion` (:959) from `NativeRevisionStore.removeSpecificRevisionsImpl` (:932), which is called from `pruneStorageImpl` (:825), `maintainCountAfterSelection` (:875) and the coordinator's `removeRetentionItems` (:729). Each of the three entry bodies starts with `assertStorageSettled()` (:826, :876, :933), which throws `recoveryRequired` while ANY `journal.json` exists anywhere in the root (:448). Before that, `withStorage` recovery throws the simulated crash first (section 2). `markAndSweep` has no product caller (grep over `Sources/`). `recoverTombstones` only completes an already begun free; none exists in these fixtures. Recovery's own deletions are temp files and checkout trees, never `objects/` or `manifests/rev-*.json`.

Corroborating evidence [V]: the post-crash assertions that do check blocks (T 311 for stage points, T 368 for swap points) pass in every case (none of the 49 are at 311 or 368), and T 410 and 411 (post-settlement prune equals independent allocation drop and frees one revision) pass in every case.

A hash difference is NOT evidence of a prune: every one of the 49 is explained by files in the mutable table above. What would discriminate, to add to the oracle: (a) every `manifests/<app>/<project>/rev-sha256:*.json` name present before is present after, and no `*.json.tomb` or `*.json.freed` exists; (b) every `objects/**` file name and hash present before is present after; (c) `allocatedBlocks(at:)` after >= before (already asserted at 368, repeat it at 379 and 390); (d) no revision id lost, read from the filesystem, not from a recovery-capable getter (contract 8: "without calling a recovery-capable getter").

## 5. Per family: smallest fix and exact oracle wording

Shared helper (spec-only test author, in `KCAWorld`, T near 582):

```
struct KCAImmutableSnapshot { var files: [String: String]; var manifestNames: Set<String>; var blocks: Int64 }
func immutableSnapshot() throws -> KCAImmutableSnapshot
// files: hashes(at: storeRoot) filtered to paths with component "objects", or component "manifests"
//        and last component hasPrefix("rev-sha256:") && hasSuffix(".json")
// manifestNames: the "manifests" subset above, as paths
func assertNoPruneOrRewrite(_ before: KCAImmutableSnapshot, _ after: KCAImmutableSnapshot, _ label: String)
// XCTAssertTrue(before.files.allSatisfy { after.files[$0.key] == $0.value }, "[label] no object or revision manifest was removed or changed")
// XCTAssertTrue(before.manifestNames.isSubset(of: after.manifestNames), "[label] no revision that was present is gone")
// XCTAssertGreaterThanOrEqual(after.blocks, before.blocks, "[label] allocated object blocks did not decrease")
// no path in storeRoot ends with ".json.tomb" or ".json.freed"
```

A. Count 2 (T 361). Fix, in the test: choose the rollback target per point, `let rollbackTarget = point == .journalWrite_afterCheckoutBuilt ? first : second`, so the checkout really gets built; for `(operation == .undo, point == .journalWrite_afterCheckoutBuilt)` do not run the faulted call, record "inapplicable: the undo target checkout is always retained (SPEC 2.3 step 2), the point is reached only by a build" and instead assert the un-faulted undo returns true. Contract owner: change the 7.3 table row to "activate always; rollback when the target's checkout was not retained (older than the fallback); undo never reaches it". Product alternative (NOT recommended, needs an owner decision): fire the point on the verified-existing path in `NativeVersionCheckoutBuilder.build`; then recovery's "pointer never moved" branch (`NativeVersionStore.swift:552 to 557`) would delete a retained fallback checkout, which SPEC 2.3 step 5 forbids.

B. Count 9 (T 349, 365 to 368). Move `beforeHashes`/`beforeBlocks` to AFTER the arrangement and immediately before the faulted call: for undo, run the un-faulted `rollback` first, then snapshot, then the faulted `undo`. Replace line 367 with `assertNoPruneOrRewrite(beforeSnapshot, immutableSnapshot(), "[point, op] interruption cannot rewrite or remove existing object or manifest content")`. Keep 368.

C. Count 35 (T 378 to 379). Barrier loop: `let afterPlan = try world.hashes(at: world.storeRoot)` must equal `interruptedHashes` (taken at T 365) for every file under `state/`, `manifests/`, `objects/` and `checkouts/`, label "[...] read-only refusal did not repair, recover or prune". Exclude `gc/` only (open SQLite connections). This is stricter than today because it forbids repair, which is what the contract says planning must not do.

D. Count 3 (T 389 to 390). Take `interruptedSnapshot = immutableSnapshot()` right after T 365 and assert `assertNoPruneOrRewrite(interruptedSnapshot, immutableSnapshot(), "[point, op] refused prune preserves objects and manifests")`, plus `journal.json` still present for the identity, plus the existing nil-preference asserts (388, 398). Do not hash state/checkouts here: the refused call legitimately rewrites undo-offer.json and features.json for rollback (section 2).

Expected after the fixes [I, not run]: 0 failures in this method; the five other post-recovery assertions (400 to 411) already pass. Mutation checks the author should add or run: (1) a mutant that calls `removeSpecificRevisions` inside `settleVersionStorage` before the fault must fail the new B and D oracles; (2) a mutant that makes `planVersionKeepCount` call `recoverIfNeeded` must fail C (whole-root equality); (3) a mutant that deletes a manifest during recovery must fail B.

## Next actions in order

1. Spec-only test author: add `immutableSnapshot`/`assertNoPruneOrRewrite`, move the baseline after arrangement (B), retarget rollback and skip (undo, afterCheckoutBuilt) (A), retarget C and D to the post-interruption snapshot. No product edit, no weakening: the oracle still fails on any prune, tombstone, object deletion or block decrease before settlement.
2. Contract owner: correct the `.journalWrite_afterCheckoutBuilt` row in `KEEPCOUNT_PUBLIC_API.md` 7.3 (one row) and add the sentence that recovery attempts may rewrite undo-offer.json and features.json.
3. Runner: re-run only this method through the usual gate, then the whole keep-count filter. Report the result as a source-slice pass, not as accepted.
4. Product builder (separate, low priority, not blocking): the two side findings below.
5. Owner decision only if someone wants the product to fire the point on verified checkouts (alternative in family A).

## What is unproven

- Nothing was run. All "passes after the fix" statements are [I].
- 35 of the expected 36 barrier cases failed at T 379. The missing one is `[beforeJournalDelete, undo, barrier journalWrite_afterPointerWrite]` (EV lines 61 to 71 list 11 undo barriers, no afterPointerWrite). A read-only plan cannot differ between iterations, and undo's baseline differs deterministically (features.json, undo-offer.json), so one passing iteration is unexplained by static reading. Candidates: a time or SQLite dependent writer, or an incomplete log. EV itself counts 49 failures, so it is not a log truncation of the count. Recommendation: keep `gc/` out of any whole-root comparison and re-run twice before trusting C's strict form; if it flakes, fall back to immutable subtrees plus byte equality of journal.json and active.json.
- Mutant survival [I, 80%]: the explicit prune and apply refusals are always short-circuited by recovery's simulated crash, so the `assertStorageSettled()` guards inside `pruneStorageImpl`, `removeSpecificRevisionsImpl` and `maintainCountAfterSelection` are never the thing that refuses in this test. Only the plan path exercises the guard. A mutant that deletes those guards would likely survive. A migration journal left not-done (`.migration_midRename`) followed by an explicit prune would reach the guard through `settleVersionStorage` (`NativeRevisionStore.swift:1233 to 1235`); the test file has no such case.
- Why the Python oracle fires afterCheckoutBuilt on every swap (model vs product) was not investigated beyond noting the difference.

Side findings, [V] by reading, NOT part of the 49 and not prunes:
- Recovery of an interrupted rollback is not idempotent: `recoverIfNeededImpl` re-enters `finishSwapCleanup(writeUndoOffer: true)` (`NativeVersionStore.swift:537 to 540`), which rewrites undo-offer.json and appends another "Went back to a previous version" ledger row (:469 to 481) before the fault or the journal delete. Each failed or successful recovery of that journal adds a row; in this test one Go back can end with up to 4 rows (original, refused prune, refused apply, final recovery) [I for the count].
- Recovery's "pointer never moved" branch deletes the checkout of `journal.to` unconditionally (`NativeVersionStore.swift:552 to 557`), including an intact retained fallback checkout when the interrupted operation was a rollback to the fallback. Objects stay, launch rebuilds it, so no data loss, but it deviates from SPEC 2.3 step 5 (delete checkouts of versions that are neither current nor fallback).

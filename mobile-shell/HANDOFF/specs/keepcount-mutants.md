# Keep-count mutants (versions kept per app)

Driver: `<scratch>/bin/mutate-keepcount.py`. Package under test: `<repo>/mobile-shell/native` (module IrisMobileShellCore).
Spec: `docs/plans/20260928-all-routes/round3/mobile-versions/SPEC.md` 2.5 and 5.1, `KEEPCOUNT_PUBLIC_API.md`.

No mutant has been run. The "predicted" column is the author's reading of the current tests, not a result. Every anchor was counted exactly once in the live files with `--verify-anchors`; line numbers are those of the live files on 2026-10-02.

## Mutants

Suite short names: Policy = NativeKeepCountPolicyTests, Setting = NativeKeepCountSettingTests, Retention = NativeKeepCountRetentionTests, RealState = NativeKeepCountRealStateMigrationTests, GlobalCap = NativeShellLibraryCoordinatorGlobalCapTests, Storage = NativeShellLibraryCoordinatorStorageTests. Paths are under `Sources/IrisMobileShellCore/`.

| id | what the defect is | file and anchor line | suite that should catch it | why a spec-only oracle catches it | predicted |
|---|---|---|---|---|---|
| KC01-k2-keeps-three | Count slots are charged to the current version only, so K=2 keeps current, fallback and one more (three versions). Letter (a). | `NativeStorageRetentionPolicy.swift:158` `let ordinaryRoles = Set([roles.current, roles.previous]...)` becomes `[roles.current]` | Policy, Retention (check 6) | SPEC 2.5: current and fallback take the first K slots. An independent model of the table, or eight generated hashes at K=2, must leave exactly two usable. | caught |
| KC02-fallback-not-a-role | The retained-role projection forgets the fallback, so a count prune at K=2 frees the version Go back needs. Letter (b). | `NativeStorageRetentionPolicy.swift:84` `for value in [current, previous, pending]` becomes `[current, pending]` | Policy, Setting (check 17) | SPEC 2.5 and check 9: the fallback survives even at K=1; check 17: Go back after the prune must restore the exact fixture hashes and the sentinel. | caught |
| KC03-pinned-ignored | Pins are ignored, so a pinned third historical version is pruned at K=2. Letter (c). | `NativeStorageRetentionPolicy.swift:114` `for id in pinnedRevisionIds where knownIds.contains(id)` gains `&& false` | Policy, Retention (checks 9, 10) | Pinned ids stay outside the K slots; the pinned object hash must stay readable. | caught |
| KC04-catalog-offers-ignored | The planning snapshot reports every stored version as downloadable, so versions the catalog never offered or withdrew are pruned. Letter (d). | `NativeRevisionStore.swift:398` `offers: offers,` becomes `offers: Set(versions.map(\.revisionId)),` | Retention (checks 11, 20) | A version with no current download offer is never freed; its hash stays and its row reads "Kept on this iPhone (not available to download)". | caught |
| KC05-unavailable-not-protected | `protectedIds` no longer includes stored versions the catalog does not offer, so the cap, `prunableAllocation` and `removeSpecificRevisions` may free them, and `nothingCouldBeFreed` is wrong. Letter (d), second form. | `NativeStorageBlockMeasurement.swift:25` `.revisionIds.union(storedIds.subtracting(offers))` loses the union | Retention, GlobalCap, Storage (check 20 names cap enforcement; API section 2 names `nothingCouldBeFreed`) | An unavailable old version next to a cap that would otherwise take it must keep its hash; a fixture holding only unavailable extras must report `nothingCouldBeFreed == true`. | survive (likely gap: no listed test combines unavailable history with cap pressure, and no Core test reads `nothingCouldBeFreed`) |
| KC06-settled-guards-removed | Every settled-storage guard is disabled (root journal walk, own journal check, and the two checks at adapter entry), so plan and setter run through an unsettled swap or migration journal. Letter (e). | `NativeRevisionStore.swift:429`, `:459` (early return), `:1230`, `:1235` (guards deleted) | Setting (check 18) | While a journal is unsettled, `planVersionKeepCount` throws `recoveryRequired`, the setter throws and saves nothing, and objects and manifests are byte-identical. | caught (guards are layered; only removing all of them is visible for a single app) |
| KC07-choice-not-persisted | The setter prunes at the chosen K but never saves the choice. Letter (f). | `NativeShellLibraryCoordinator.swift:713-714` `preferences.set(...)` removed | Setting (checks 4, 5) | A new actor over the same suite and root reads the choice back, and the raw suite string equals "2" after a reset. | caught |
| KC08-apply-ignores-chosen-k | Applying any choice plans at K=2, so choosing 3, 5 or keep-all (including raising from 3 to 5) still frees versions the new K keeps. Letter (g), the "changes bytes" form; Core has no code path that restores bytes (raising never downloads), so this is the observable raise defect. | `NativeShellLibraryCoordinator.swift:715` `retentionPlan(choice, ...)` becomes `retentionPlan(.keepTwo, ...)` | Retention (checks 7, 8), Setting | Eight packages at K=3 and K=5 keep three and five newest hashes; three packages at K=5 keep all three. Check 15 alone (raise after a K=2 prune) would not see it. | caught |
| KC09-cap-ignored-under-keepall | Cap enforcement is skipped whenever the saved choice is keep-all. Letter (h). | `NativeShellLibraryCoordinator.swift:774` guard gains `choice.count != nil,` | GlobalCap, Storage | SPEC 1.6: keep all still obeys the 2 GB cap; a small saved cap under keep-all must produce a non-empty plan and a smaller allocation. | caught |
| KC10-cap-loop-ignores-count-savings | The cap loop compares the unreduced total to the cap, so once the cap is exceeded it frees every eligible kept-tier version instead of stopping when both targets are met. Letter (h), "stricter must win" form. | `NativeShellLibraryCoordinator.swift:774` `ledger.totalBytes - ledger.bytesReclaimed > ...` becomes `ledger.totalBytes > ...` | GlobalCap, Setting (check 16), Storage | SPEC 2.5: free "until both targets are satisfied". A fixture with more eligible kept-tier versions than the cap needs must keep the surplus; the oracle needs a lower bound, not only allocation at or below the cap. | survive (likely gap: current cap tests assert only the upper bound) |
| KC11-migration-drops-fallback | Legacy migration imports only the current revision (a K=1 style prune), so the fallback and older original content never reach `objects/` and the legacy tree is retired. Letter (i). | `Versions/NativeStoreMigration.swift:145` loop gains `where legacy.revisionId == currentRevisionId` | RealState (check 19), Retention | Every original content hash of the copied phone state must be present in `objects/` after migration and first launch. | caught |
| KC12-warning-memory-only | The migration sentence is held only by the process that migrated; a reconstructed store no longer derives it from the persisted deferral marker. Letter (j). | `NativeRevisionStore.swift:138-139`, `:1167-1169`, `:1204-1205` (three persisted-warning paths removed) | RealState (aimed), Retention | After migration and the first verified launch, a fresh `NativeRevisionStore` returns exactly "Older versions will be cleared the next time Iris tidies storage." | caught, but by Retention only: the real phone copy has exactly 2 revisions per app, so RealState's "more than two" warning branch never runs |
| KC13-default-keepall | The public readback defaults to keep-all instead of 2 when nothing was saved. Letter (k). | `NativeShellLibraryCoordinator.swift:673-674` `?? .keepTwo` becomes `?? .keepAll` | Policy (check 1), GlobalCap | An empty suite reads `.keepTwo` and the read writes nothing. The store lifecycle keeps its own two `?? .keepTwo` defaults, which this mutant leaves alone. | caught |
| KC14-plan-deletes | The dry-run `planVersionKeepCount` also executes the removals it plans. Letter (l). | `NativeShellLibraryCoordinator.swift:679-680` plan result is passed to `removeRetentionItems` | Setting (check 13) | After plan and a "Not now", the saved choice, every hash and the allocated blocks are unchanged. | caught |

Letters (a) to (l) are the owner's list of defects; every letter has at least one mutant. Run order is the table order.

## Suites used

The baseline runs the union of: Policy, Setting, Retention, RealState, GlobalCap, Storage. `NativeShellLibraryCoordinatorScaleTests` (about 17 minutes) is never selected. `NativeRevisionStoreTests` is allowed but no mutant needs it; adding it would put the 50 MiB and 100-app facade tests into every baseline. Setting is the slowest suite because every package goes through node.

## How to run

The script reads the live package and never writes to it. It builds a scratch mirror with rsync (Package.swift, Sources/, Tests/; no `.build`, no xcodeproj; the only paths Package.swift references are the default Sources/ and Tests/ roots), restores each mutated file byte for byte and checks the sha256, and refuses to start if a mirror source file differs from live after a re-sync.

The mirror package lives at `<scratch>/keepcount-mirror/mobile-shell/native`, not at `keepcount-mirror/native` (that path is kept as a symlink). The test fixtures locate `mobile-shell/native/Tests/Fixtures/generate-desktop-package.mjs` by walking five directories up from each test file, and that script imports `../../../desktop/cli.mjs`. With the package directly under `keepcount-mirror/native` the walk lands in `orch-scratch`, no package can be generated, and the baseline would fail. The other repo entries are symlinked read-only into the mirror, the same way the earlier wfv phone-test mirrors did it.

```
# baseline, then all 14 mutants (each swift test queues on the heavy lock itself)
IRIS_HEAVY_PRIO=1 IRIS_PHONE_STATE_COPY=<scratch>/phone-state-copy-20261001 \
  /Applications/Xcode-27.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/bin/python3 \
  <scratch>/bin/mutate-keepcount.py --baseline
```

Other forms (use `python3` as above, `$S` = the script):

- `$S --list [--verbose]` and `$S --verify-anchors` touch nothing.
- `$S --baseline-only` syncs the mirror and runs only the baseline.
- `$S KC05-unavailable-not-protected KC10-cap-loop-ignores-count-savings` runs listed mutants; it needs a passing `baseline.json` for the current mirror state, otherwise add `--baseline`.
- `--timeout N` changes the 1500 s per run (the very first build in a fresh mirror gets 900 s extra).

Each swift run is `iris-heavy-lock.sh nice -n 10 swift test --disable-sandbox --package-path <mirror package> --filter '<suites>'` with `IRIS_HEAVY_PRIO=1` and `IRIS_PHONE_STATE_COPY` set. Output goes to `keepcount-mirror/scratch/` : `logs/<id>.log`, `baseline.json`, `report.json` (rewritten after every mutant), `in-progress.json` (present only while a mutant is applied; the next start re-syncs from live), `originals/` (byte backups).

Verdicts: CAUGHT needs a nonzero exit, "Build complete!" and at least one XCTest failure line; BUILD-BROKEN means the mutant did not compile and is not counted as caught; NOT-RUN means 0 tests or a named suite never executed; CRASHED is a nonzero exit without a failure line; SURVIVED is a clean pass. The report also records which suites failed and whether the aimed suite was among them. Exit code 1 means a build-broken, not-run, crashed, timed-out or anchor-missing mutant, or a survivor that was predicted caught; predicted survivors are listed, not failed.

## Second-pass ideas (not in the script, anchors not verified)

- Pending protection picks the oldest child: flip `if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }` at `NativeStorageRetentionPolicy.swift:109`. The keep-count suites only test an equal-time tie (P1 and P2 both created at 2026-09-30T00:00:00Z); the older `NativeStorageRetentionPolicyTests.testOnlyTheNewestCandidateBuiltOnCurrentIsPending` would catch it.
- Lifecycle count prune off: skip the removal in `NativeRevisionStore.maintainCountAfterSelection` (`:882`). SPEC 2.5 requires a prune after stage, activate, rollback, Undo and launch; I found no listed test that asserts it, because the keep-count worlds either leave the store's catalog empty or save keep-all before building.
- Default drift: the two store-level `?? .keepTwo` defaults (`NativeRevisionStore.swift:830` and `:880`) differ from the coordinator read that KC13 mutates.
- Sibling journal ignored: delete the root-wide swap journal check (`NativeRevisionStore.swift:446-448`). Single-app tests also hit the own-journal check, so only a two-app fixture with one unsettled app can see it.
- Choice saved before the catalog read succeeds: move `preferences.set` ahead of `retentionSnapshots()` in `applyVersionKeepCount`; `testFailedCatalogReadCannotAuthorizeFreeingAnyVersion` should catch it.

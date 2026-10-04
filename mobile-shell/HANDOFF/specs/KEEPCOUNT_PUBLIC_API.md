# Public API contract: versions kept per app

Unit `r0105-wfm-r1-keepcount-contract`. This names the MV2 Core surface and the MV4 Host binding surface; it implements neither. [SPEC.md](SPEC.md) sections 1.6, 1.7, 2.5, 5.1, 6 and the section 8 protections control behavior. **EXISTS** means declared today, not verified or shipped. **NEW** means the owning builder must add it. Each new declaration is defined once below; later mentions are references.

## 1. Existing surface and construction

Paths below are relative to `mobile-shell/native/Sources/`. Core declarations are public in `IrisMobileShellCore`. The coordinator and revision store are actors, so external callers use `await`, including for getters without an `async` declaration. Host declarations remain internal and `@MainActor`, matching the existing view model; Host unit tests can use `@testable`, while UI tests use accessibility and visible copy.

| Status | File | Symbols relied on |
|---|---|---|
| EXISTS | `IrisMobileShellCore/NativeShellLibraryCoordinator.swift` | `NativeShellLibraryCoordinator.init(rootURL:shellVersion:capabilityPolicy:fileManager:automaticCodeCap:)`; `reviewImport(packageBytes:expectedIdentity:clientReviewSequence:)`, `approvePendingReviewLocallyAndStage(reviewToken:packageSHA256:)`, `stagePendingReview(reviewToken:packageSHA256:using:)`, `refreshLibrary()`, `libraryEntry(identity:)`, `activate(identity:revisionId:)`, `activateAndCaptureSelection(identity:revisionId:)`, `revert(identity:to:)`, `launchActive(identity:requiringSelection:)`, `pin(identity:revisionId:)`, `unpin(identity:revisionId:)`, `pinnedRevisionIds(identity:)`, `pruneStorage(identity:)` |
| EXISTS | Same file | `globalCodeCapUserDefaultsKey = "iris.storage.globalCodeCapBytes"`; `globalCodeCapBytes(defaults:)`, `setGlobalCodeCapBytes(_:defaults:)`, `globalStorageUsage(capBytes:defaults:)`, `planGlobalCapEnforcement(capBytes:defaults:)`, `enforceGlobalCap(capBytes:defaults:)`; `NativeShellAppIdentity`, `NativeStorageGlobalReclaimItem` with `identity`, `revisionId`, `allocatedBytes` |
| EXISTS | `IrisMobileShellCore/NativeRevisionStore.swift` | Throwing `NativeRevisionStore.init(rootURL:appId:projectId:shellVersion:capabilityPolicy:fileManager:minimumFreeBytesForStaging:availableCapacityProvider:)`; `stage(packageBytes:approvalAuthority:)`, `activate(revisionId:)`, `rollback(to:)`, `activeRevisionId()`, `fallbackRevisionId()`, `revisionSummaries()`, `revisionIsOnThisPhone(revisionId:)`, `launchDescriptorForActiveRevision()`, `readerDataDirectory(namespace:)`, `pin(revisionId:)`, `unpin(revisionId:)`, `pinnedRevisionIds()`, `storageAllocation()`, `totalAllocatedBytes()`, `storageUsage()`, `pruneStorage()`, `prunableAllocation()`, `removeSpecificRevisions(_:)`, `storageMigrationWarning()` |
| EXISTS | Same file | `NativeStoragePruneReport.removedRevisionIds` and `.retainedRevisionIds`, both `Set<String>`; `prunableAllocation()` returns `[(revisionId: String, allocatedBytes: Int, createdAt: String)]` |
| EXISTS | `IrisMobileShellCore/NativeStorageRetentionPolicy.swift` | `NativeStorageRetentionPolicy.RevisionFact.init(revisionId:baseRevisionId:createdAt:)`, `retainedSet(revisions:currentRevisionId:fallbackRevisionId:pinnedRevisionIds:)`, `RetainedSet.current`, `.previous`, `.pending`, `.pinned`, `.revisionIds`; `pinLimit = 2`; `planGlobalReclaim(currentTotalBytes:capBytes:prunableCandidates:)`; `NativeStorageError.cannotRemoveRetainedRevision(_:)` |
| EXISTS | `IrisMobileShellCore/NativeStorageBlockMeasurement.swift` | `NativeStorageBlockMeasurement.allocatedBytes(atPath:)`, `dedupingAllocatedBytes(contentRootByRevision:filesByRevision:baseRevisionByRevision:)`; allocation uses `st_blocks * 512`, not logical file sizes |
| EXISTS | `IrisMobileShellCore/NativeRevisionHistory.swift` | `NativeRevisionHistoryRow`, `.revision`, `.id`, `.state`, `.canRevert`, `.canActivate`, `rows(for:)`; today's `State.label` does not carry the required Features storage words or download eligibility |
| EXISTS | `IrisMobileShellHost/Store/StoreStorageView.swift` | `StoreStorageModel.init(coordinator:defaults:library:displayNames:)`, `refresh()`, `errorMessage`, `resultMessage`, `StoreStorageView.init(coordinator:defaults:library:displayNames:openVersions:)` |
| EXISTS, documented in round 6 `PUBLIC_CONTRACT.md` section 1.2 | Core `Versions/` facade | `NativeVersionStore.init(root:)`, `activate(appId:projectId:revisionId:fault:)`, `rollback(appId:projectId:revisionId:fault:)`, `undo(appId:projectId:fault:)`, `recoverIfNeeded(appId:projectId:fault:)`; `NativeVersionFaultInjector`, `NativeVersionCrashPoint`, `NativeVersionRecoveryOutcome`. The gap addenda below enumerate the inspected public declarations and fault recipes. |

**NEW initializer inputs**, appended with defaults to both existing coordinator and revision-store initializers, in their respective Core files:

```swift
// Preferences already used by the code-cap setting.
defaults: UserDefaults = .standard
// Current authoritative package offers, keyed by exact app/project identity.
downloadableRevisionIds: @escaping @Sendable (NativeShellAppIdentity) async throws -> Set<String> = { _ in [] }
// Optional existing MV1 OS-edge fault control, not a policy or byte-output fake.
versionFault: NativeVersionFaultInjector? = nil
```

The coordinator passes these same inputs into every store it creates. The catalog closure returns revision ids of packages actually offered now for that identity, not all historical ledger ids. An empty set protects all unavailable history. A failed catalog read must never authorize freeing a version: explicit planning/applying propagates the failure; automatic maintenance retains bytes and reports no successful prune. A test can capture an actor-backed catalog fixture whose offered set changes between operations.

Use a fresh `UserDefaults(suiteName:)` suite and a disposable `rootURL`; reconstruct both actors with the same suite/root for relaunch checks. Existing `shellVersion`, `capabilityPolicy`, and revision-store capacity inputs retain their meanings. No preferences file, database or migration scheme is added. Explicit `defaults:` arguments on existing cap methods must use this same suite. The existing `automaticCodeCap` override remains supported; its omitted default must read the injected preferences rather than accidentally reading `.standard` for a test suite. This changes default resolution, not the cap policy or the override's callable shape.

## 2. Choice, saved setting, plan and completed result

**NEW in `IrisMobileShellCore/NativeStorageRetentionPolicy.swift`:**

```swift
public enum VersionsKeptPerApp: String, Codable, CaseIterable, Equatable, Sendable {
    case keepTwo = "2"
    case keepThree = "3"
    case keepFive = "5"
    case keepAll = "all"
    public var count: Int? { get }
}
```

`count` is respectively 2, 3, 5, or nil. Nil removes only the count ceiling, never the cap or safety protections. The default is `.keepTwo`. These are the only saved/UI choices. Missing or invalid saved raw values read as `.keepTwo`; reading does not rewrite preferences.

**NEW in `IrisMobileShellCore/NativeShellLibraryCoordinator.swift`:**

```swift
public struct NativeStorageKeepCountPlan: Equatable, Sendable {
    public let choice: VersionsKeptPerApp
    public let bytesReclaimed: Int64
    public let items: [NativeStorageGlobalReclaimItem]
}

public struct NativeStorageKeepCountResult: Equatable, Sendable {
    public let choice: VersionsKeptPerApp
    public let bytesReclaimed: Int64
    public let retainedRevisionIds: [NativeShellAppIdentity: Set<String>]
    public let freedRevisionIds: [NativeShellAppIdentity: Set<String>]
    public let nothingCouldBeFreed: Bool
}

// Members of NativeShellLibraryCoordinator:
public static let versionKeepCountUserDefaultsKey = "iris.storage.versionsKeptPerApp"
public func versionKeepCount(defaults: UserDefaults? = nil) -> VersionsKeptPerApp
public func planVersionKeepCount(_ choice: VersionsKeptPerApp, defaults: UserDefaults? = nil) async throws -> NativeStorageKeepCountPlan
@discardableResult
public func setVersionKeepCount(_ choice: VersionsKeptPerApp, defaults: UserDefaults? = nil) async throws -> NativeStorageKeepCountResult
```

Nil `defaults` resolves to the initializer's preferences; an explicit value overrides it for that operation, following the cap's injectable preferences pattern. A Host/test uses the same suite consistently for reads, writes and automatic lifecycle actions. Persist the enum's raw String under the public key. It is global, survives relaunch/shell update, and governs existing and future apps.

Planning reads the candidate policy and the current catalog without saving, pruning, staging, migrating, repairing journals, or changing rows/files. `items` is the count-prune set plus any additional eligible cap removals. `bytesReclaimed` is the allocated storage that their union would actually release, using `prunableAllocation` and last-reference accounting across the entire root. Summing independently attributed per-revision bytes is insufficient when selected revisions share an object. Each allocation is credited only once when its last retained reference disappears. Logical `contentBytes` is never the confirmation amount.

Applying is an awaited save-and-prune operation across all installed identities. It recomputes eligibility immediately before mutation, saves the choice, applies count pruning and then the saved cap, refreshes the retained/freed projection, and returns only after pruning completes. It never reconstructs or downloads files when raised. `bytesReclaimed` in the result is the actual allocated reduction caused by that operation, not the earlier estimate. Maps contain every installed identity, including empty freed sets; revision ids are scoped by identity. `retainedRevisionIds` contains all revisions whose usable stored files remain, not just the four role slots; `freedRevisionIds` contains revisions whose stored code was removed during this call, not older ledger-only rows.

`nothingCouldBeFreed` is true when no allocated storage could be released because the remaining other versions are protected or unavailable to download. It is false after positive reclamation, and must not explain a failure, an unsettled journal, or zero-byte shared-object accounting as protected/unavailable. Section 1.7 owns the no-eligible result copy. A plan can become stale; never free a newly pinned, pending, current, fallback, local-only or unavailable revision to honor an old estimate.

Explicit actions propagate existing storage/delivery/I/O errors; never swallow them as success. If saving has occurred but pruning fails, the saved choice remains the honest readback, the operation throws, and the sheet shows failure and stays open. A retry of the same choice still applies its policy. No successful result is issued for a partial prune. A recovery preflight failure occurs before saving.

## 3. Retention, ordinary lifecycle calls and recovery

**NEW pure policy member in `IrisMobileShellCore/NativeStorageRetentionPolicy.swift`:**

```swift
public static func retainedRevisionIds(
    revisions: [RevisionFact],
    currentRevisionId: String?,
    fallbackRevisionId: String?,
    pinnedRevisionIds: [String],
    localOnlyRevisionIds: Set<String>,
    downloadableRevisionIds: Set<String>,
    keepCount: Int?
) -> Set<String>
```

Nil means no count ceiling; a finite policy input must be positive. This pure function takes generated facts, not disk or settings. It includes the existing `retainedSet` roles plus local-only and catalog-unavailable known revisions; fills ordinary count slots with current/fallback first, then newest eligible older revisions per SPEC section 2.5; and never resurrects an unknown id. Separately protected roles use no extra ordinary slots. Its return value is the count-policy retained set before any stricter cap selection. Ordering uses package/ledger order, not the device clock; deterministic ties follow the existing revision-id ordering.

SPEC section 5.1 check 9's K=1 is an adversarial **policy** input to this pure function, not a fifth setting. Even at 1, both current and fallback and all extra protected roles survive. Tests can apply the complement through existing `removeSpecificRevisions(_:)` on their disposable fixture and independently verify the surviving bytes. The saved choice remains one of the four allowed values. Do not add a K=1 UI option, persist 1, or silently coerce `.keepTwo` into 1.

**EXISTS with required new behavior, no new prune entry point:** `NativeRevisionStore.pruneStorage()` and coordinator `pruneStorage(identity:)` apply the saved K without a count argument. The report's existing retained ids project every surviving revision, including kept-tier, local-only and unavailable revisions. `prunableAllocation()` continues to expose all safely removable candidates, including eligible kept-tier history that only the cap would remove; it must not be narrowed to count-excess candidates and thereby disable cap enforcement. `removeSpecificRevisions(_:)` rechecks all protections, including current catalog eligibility, before any removal.

Existing stage and activate calls apply K at their successful lifecycle boundaries. SPEC section 2.5 also requires pruning after rollback, Undo and launch. Pending protection is established before stage pruning; new current/fallback protection is established before activate/rollback/Undo pruning. The coordinator's reviewed-stage and selection wrappers must use the same policy, not a cap-only bypass. Count pruning runs even below the cap; further eligible kept-tier history is freed only as the cap requires. Explicit operations await completion and propagate pruning errors; automatic maintenance never disguises a successful selection as a failed selection solely because later maintenance failed, and never claims a failed prune completed. Existing public cap calls use the same safety and K rules.

**NEW error case in the existing `NativeStorageError` in `IrisMobileShellCore/NativeStorageRetentionPolicy.swift`:**

```swift
case recoveryRequired
```

No count or cap pruning, tombstoning, reference decrement or object sweep is permitted while a swap/migration journal is unsettled. Read-only planning throws this error rather than implicitly recovering. An explicit prune/apply can run normal recovery first; if it remains unsettled, it throws this error and makes no prune or preference mutation. A fault at any recovery boundary cannot fall through to collection. Settling recovery itself can complete or roll back the interrupted transaction, but it is not permission to prune before settlement. Pass the optional facade fault input through to the existing MV1 recovery boundary; do not invent a parallel recovery engine.

For a legacy install, migration retains all existing revisions, including those exceeding K. **EXISTS with required projection:** `storageMigrationWarning()` exposes SPEC section 4 item 15's migration sentence after successful migration and on the first verified launch; keep the existing failure warning for failed migration. The Host displays this sentence. Neither migration nor that first launch prunes the legacy kept tier; the next ordinary prune applies K. This deferral is distinct from a failed/unsettled recovery and must not turn the initial install into a lower-count deletion.

## 4. Features ledger projection

**NEW in `IrisMobileShellCore/NativeShellLibraryCoordinator.swift`:**

```swift
public func featureHistory(identity: NativeShellAppIdentity) async throws -> [NativeRevisionHistoryRow]
```

**NEW read-only members of the existing `NativeRevisionHistoryRow` in `IrisMobileShellCore/NativeRevisionHistory.swift`:**

```swift
public let isOnThisPhone: Bool
public let storageStateLabel: String
public let canDownload: Bool
```

Return one row per ledger revision, including freed revisions, in the Features ordering of SPEC section 1.1. The existing `.id`/`.revision.revisionId` identifies it. This projection joins ledger/manifest history with actual file availability, role/pin state and the current authoritative catalog, not just whether a manifest exists. Existing summaries preserve all eight rows in the eight-version fixture; `revisionIsOnThisPhone` must agree with usable code presence, not mistake a freed manifest for a stored version. Keep `rows(for:)` source-compatible; the new coordinator projection supplies facts absent from the old metadata-only helper.

`storageStateLabel` uses the exact base state words below, with precedence current, fallback, pending, pin, unavailable/local-only, ordinary kept, absent. A current or fallback revision remains protected even if pinned or unavailable.

| Condition | `storageStateLabel` | `canDownload` |
|---|---|---|
| Current, files present | On this iPhone now | false |
| Fallback, files present | Kept as backup | false |
| Pending, files present | Downloaded, not switched on yet | false |
| Other pinned revision, files present | Pinned: kept until you unpin it | false |
| Other local-only or catalog-unavailable revision, files present | Kept on this iPhone (not available to download) | false |
| Other count-kept revision, files present | Kept (within your count) | false |
| Files absent, current catalog offers the package | Not on this iPhone | true |
| Files absent, no current catalog offer | No longer available | false |

`isOnThisPhone` is true only for the six files-present cases. An unavailable history revision with files is never freed. A previously freed row may later become No longer available if the catalog withdraws its offer; that is not a new prune. The view can append the download-size/help text from section 1.1, but the base state stays testable. Existing `canRevert` and `canActivate` are false when files are absent; offering Download does not authorize an activation without obtaining and validating the actual package.

## 5. Storage binding surface

**NEW members on the existing internal `@MainActor StoreStorageModel` in `IrisMobileShellHost/Store/StoreStorageView.swift`:**

```swift
@Published private(set) var selectedKeepCount: VersionsKeptPerApp
@Published var keepCountSheetIsPresented: Bool
@Published private(set) var keepCountConfirmation: NativeStorageKeepCountPlan?
@Published private(set) var keepCountResult: NativeStorageKeepCountResult?
@Published private(set) var isApplyingKeepCount: Bool
@Published private(set) var keepCountConfirmationMessage: String?
@Published private(set) var keepCountConfirmButtonTitle: String?
@Published private(set) var keepCountCancelButtonTitle: String?
@Published private(set) var keepCountResultMessage: String?
@Published private(set) var keepCountRaisingMessage: String?
func selectKeepCount(_ choice: VersionsKeptPerApp) async
func confirmKeepCount() async
func cancelKeepCount()
func resetKeepCount() async
```

`refresh()` reads the saved choice into selection; initial selection is `.keepTwo` until that read completes. Selection does not optimistically change the saved choice. A decrease, treating keep-all as infinity, sets the candidate plan and confirmation fields; no mutation occurs. Confirmation content is verbatim **SPEC section 1.7 paragraph 1**, including both button labels, populated with candidate count and formatted allocated `bytesReclaimed`. Cancel clears the candidate/confirmation and leaves selection, preferences, rows and bytes unchanged. Dismissing the confirmation follows cancel.

Confirm awaits the coordinator setter while applying is true and rejects duplicate confirms. On success it publishes the completed result and saved selection, sets result copy verbatim **SPEC section 1.7 paragraph 2**, then permits sheet closure. On failure it uses existing `errorMessage`, refreshes honest saved selection, retains the sheet, and permits retry. Raising saves/applies without a lowering confirmation and publishes the warning verbatim **SPEC section 1.7 final sentence**; it never auto-downloads. Reset calls the same selection/confirmation/apply path with `.keepTwo`, including immediate prune after confirmation when it lowers the value. Reset at 2 is safe and does not create duplicate operations.

**NEW members of `NativeAccessibilityIdentifiers.Storage` for MV4 in `IrisMobileShellHost/NativeAccessibilityIdentifiers.swift`:**

```swift
static let keepCount = "iris.store.storage.keep-count"
static func keepCountOption(_ choice: VersionsKeptPerApp) -> String
static let keepCountReset = "iris.store.storage.keep-count.reset"
```

The option function returns `iris.store.storage.keep-count.option.` plus the stable raw value (2, 3, 5, all). Labels, help, choice order, reset wording and selected accessibility announcement come verbatim from SPEC section 1.6. UI tests read the selected option's accessibility selection trait/value, which must match `selectedKeepCount.count`; keep-all announces its full choice label, never a numeric sentinel. No layout is specified here.

## 6. Acceptance mapping

All arrangements use distinct generated packages, independently recorded revision order/content, disposable roots and isolated preferences. Store/coordinator below mean the public actors with the inputs above. UI means the Storage identifiers and Features controls specified in SPEC, not a private implementation hook. Byte/hash observations are independent filesystem walks; reported plans/results are claims to compare, not the byte oracle.

| SPEC 5.1 | Arrange | Act | Observe |
|---:|---|---|---|
| 1 | Empty suite; coordinator; existing Storage model/view initializer | `refresh()`; open Storage | `versionKeepCount() == .keepTwo`, `selectedKeepCount.count == 2`, UI label and selected option 2 |
| 2 | Same fixture; accessibility Dynamic Type | Open each choice through `keepCountOption`; select via UI | Exactly four labels/ids per 1.6; selected traits; each option remains operable |
| 3 | Generated app A and B in one root, same suite | `selectKeepCount(.keepThree)` or setter | Global readback 3; `pruneStorage(identity:)`/summaries and independent retained hashes for both identities |
| 4 | Two actors/root and isolated suite | Save `.keepFive`; terminate/relaunch or recreate with same suite/root | `versionKeepCount()`, selected option 5; separately verify actual shell relaunch in UI |
| 5 | Saved `.keepFive` | `resetKeepCount()`; `confirmKeepCount()` or reset/confirm UI; relaunch | Result completes before closure; saved 2, selected option 2 after second launch |
| 6 | Build eight-version fixture at `.keepAll` with cap room, all eight offered; no extra roles | Set `.keepTwo`; existing `pruneStorage()` | Report/result retained ids; summaries and `featureHistory` retain eight rows; independent usable hashes only current/fallback |
| 7 | Independent eight-version fixtures with all offered and cap room | Setter/prune at `.keepThree`, then separate fixture `.keepFive` | Summaries, retained ids and independent files: current/fallback plus one or three newest eligible older hashes |
| 8 | Three-version fixture, offered, cap room | Setter `.keepFive`; prune | All three independent hashes remain; report/result includes them |
| 9 | Generated revision facts for current, fallback, pending, two pins, local-only; corresponding disposable stored bytes | Pure `retainedRevisionIds(..., keepCount: 1)`; remove only its complement via `removeSpecificRevisions(_:)` | All protected role ids in pure projection and prune report; hashes readable. Policy robustness only; 1 is not a saved choice |
| 10 | Older downloadable fixture revision at default; stay within two-pin allowance | `pin(revisionId:)` or coordinator pin; prune | `pinnedRevisionIds()`, retained ids and independent pinned hash |
| 11 | Catalog fixture omits one old revision; a second is locally built/absent; optional pin | Plan/lower/confirm; prune | Both hashes readable; `featureHistory` labels Kept on this iPhone (not available to download) or Pinned: kept until you unpin it for applicable non-current/fallback rows |
| 12 | Eight revisions retained at 5, eligible excess, cap room; independently measured object allocation | `selectKeepCount(.keepTwo)`; inspect confirmation; `confirmKeepCount()` | Plan bytes before mutation; exact section 1.7 sentence/buttons; saved 2; result bytes equals independent allocated reduction including shared last references; closure only after completed result |
| 13 | Same lower-count arrangement | `cancelKeepCount()` or Not now UI | Readback remains 5; no result apply; unchanged file hashes, row states and allocation |
| 14 | Same fixture; no subsequent stage/update | Lower and await setter/confirm only | Immediate retained ids and independent allocation satisfy 2 before any later lifecycle operation |
| 15 | A historical hash freed by setting 2; catalog still offers it | Set/choose 5; then change catalog offer set and refresh projection | No restored object; `featureHistory` is Not on this iPhone/Download true while offered, No longer available/false after withdrawal; raising warning |
| 16 | Generated history at 5; eligible bytes sufficient to meet an injected saved cap; protected/unavailable sentinels | Existing `setGlobalCodeCapBytes(_:defaults:)`, `planGlobalCapEnforcement`, `enforceGlobalCap`; ordinary prune | Independent allocation at/below cap; count/cap retained union follows stricter policy; protected hashes survive |
| 17 | After count prune; independently known current/fallback content and reader-data sentinel | `rollback(to:)` or coordinator `revert(identity:to:)`; existing public MV1 `undo(appId:projectId:fault:)`, then ordinary prune; actual UI Go back/Undo for Host integration | `activeRevisionId`, `fallbackRevisionId`, launch descriptor tree hashes and unchanged data; fallback usable throughout. Direct MV1 evidence is module-only, not UI credit |
| 18 | Optional `versionFault` injects the declared MV1 swap/migration points; separately cover nonjournal write/GC points per the gap addenda; record allocation/manifest hashes before recovery | Plan (read-only refusal); attempt prune/apply with recovery still failing; remove fault/reconstruct and call existing `recoverIfNeeded`, then one ordinary prune | `recoveryRequired` on unsettled explicit operations, no saved change or pruning before settlement; independent hashes/allocation and retained role projection unchanged by pruning; K satisfied after settlement |
| 19 | Eight-version legacy fixture; empty/default-2 suite; record all original content | New actor/shell launch triggers normal migration; first verified launch; next ordinary prune | All legacy hashes survive migration/first launch, `storageMigrationWarning()` and visible migration sentence per SPEC 4.15; next prune's actual allocated reduction measured independently |
| 20 | Current catalog fixture offers only latest and one prior, older history retained initially | Ordinary prune and cap enforcement | Every older unavailable hash remains allocated; `featureHistory` has on-phone unavailable state; no fabricated Download offer |

No acceptance line lacks a named arrange/act/observe surface. Check 9's setting-versus-policy distinction is explicit rather than expanding the owner's choices. Public fault controls supply OS-edge interruption only; neither diagnostics nor policy return values replace actual bytes, actual recovery or actual UI observations.

## 7. Builder notes

- MV2, `NativeStorageRetentionPolicy.swift`: add the choice enum, pure count-retention projection and recovery-required error; preserve the existing retained-role helper and pin limit.
- MV2, `NativeShellLibraryCoordinator.swift`: add injected inputs, global saved/read/plan/apply API and identity-scoped results; wire catalog eligibility, automatic cap preference resolution and Features history projection.
- MV2, `NativeRevisionStore.swift`: carry the same injected inputs through normal lifecycle and pruning, enforce unsettled/migration deferral, preserve ledger rows and expose truthful stored-code/migration projections.
- MV2, `NativeStorageBlockMeasurement.swift`: provide candidate-union/last-reference allocated accounting for plans/results without replacing the independent filesystem oracle.
- MV2, `NativeRevisionHistory.swift`: add storage facts/words and Download availability to rows, preserving existing callers.
- MV4, `Store/StoreStorageView.swift`: bind the existing model to saved selection, confirmation/cancel, awaited apply, result, raising warning and reset; no layout directive is added here.
- MV4, `NativeAccessibilityIdentifiers.swift`: add the three keep-count identifier members and preserve all existing identifiers.

## 8. Test author notes

Tests may rely on the declaration signatures, stable raw values/key, injected preferences/catalog/fault boundaries, exact SPEC copy/ids, await-completion semantics, identity-scoped results and protected-role guarantees. NEW declarations are implementation targets, not a claim that a compiling implementation already exists. Use valid package/approval fixtures through normal public stage/activate calls; retain history initially with keep-all and cap room, or use a declared legacy fixture, so automatic count pruning cannot erase the arrangement prematurely.

Do not inspect private helpers, simulate policy results, use product byte totals as the independent allocation oracle, invent a fifth choice, assume eight manifests means eight usable versions, or count lower-level module evidence as phone/UI acceptance. Check 18 observes disk before any recovery-capable read; a public read that legitimately settles a journal is not a pre-recovery observation. Existing migration/fault mechanisms remain MV1's responsibility; any missing boundary is an integration gap, not permission to manufacture a settled result. Locked test changes belong to the separate test author. This unit ran no compiler, build, test, Simulator or native gate.

## 7. Addenda 2026-10-01 (gap rulings)

These seven rulings complete the recipes above. The requested addendum number is retained after the existing section 8; the existing section numbers are unchanged. The only earlier text corrections are the section 1 facade table's source-inspection note and check 18's arrangement: not every crash point leaves a swap journal unsettled. **EXISTS** below names public declarations, not verified behavior. **NEW** inputs and methods already defined above remain builder targets. No additional public name is introduced by this addendum.

### 7.1 Core reset

**Ruling:** Core reset is the existing contracted `setVersionKeepCount(.keepTwo)`. Only the Host calls its `resetKeepCount()` binding. Core has no separate reset method; the Host owns confirmation, while Core owns saving and immediate pruning.

**Recipe, check 5:** Construct `NativeShellLibraryCoordinator(rootURL: root, defaults: suite, downloadableRevisionIds: offers)` with cap room and an eight-version offered fixture initially saved at `.keepFive` or `.keepAll`. Call `try await coordinator.planVersionKeepCount(.keepTwo)`; assert `plan.choice == .keepTwo`, eligible excess appears in `items`, and preferences/files are unchanged. This is the plan shown when reset lowers the count. Call `try await coordinator.setVersionKeepCount(.keepTwo)` after the simulated confirmation. Before any later update, verify the completed result and independent usable hashes retain current/fallback plus extra protected roles. Reconstruct the coordinator with the same root/suite/closure; `await coordinator.versionKeepCount()` must be `.keepTwo`, its `.count` must be 2, and `suite.string(forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey)` must be `"2"`. Core recreation checks persistence; actual shell relaunch remains a separate UI gate.

### 7.2 Go back and Undo

**Ruling:** Go back over the public coordinator is `revert(identity:to:)`. No public coordinator Undo equivalent is declared. Undo is **EXISTS** `NativeVersionStore.undo(appId:projectId:fault:) async throws -> Bool`, reached by constructing `try NativeVersionStore(root: root)` over the same root. Calling `revert` a second time is another Go back and is not an Undo test. A coordinator-only test cannot claim Undo coverage; use the public facade alongside it, then the coordinator for policy enforcement/readback.

**Recipe, check 17:** Retain current V8 and fallback V7 after count pruning at 2; independently record both launch trees and a sentinel under `readerDataDirectory(identity:namespace:)`. Await `coordinator.revert(identity: identity, to: V7)`. `libraryEntry(identity:)` must report current V7 and fallback V8, and `launchActive(identity:)` must launch V7's exact bytes. With `facade = try NativeVersionStore(root: root)`, call `try await facade.undo(appId: identity.appId, projectId: identity.projectId, fault: NativeVersionFaultInjector())` and assert true. Await `coordinator.pruneStorage(identity:)`; read back current V8/fallback V7 through `libraryEntry`, launch V8, and verify both protected trees and unchanged reader data. False or `NativeVersionStoreError.noUndoOffer` is not success. The facade has no keep-count preferences input, so the explicit coordinator prune is required for this combined public-API recipe; it does not replace the Host Undo integration gate.

### 7.3 Crash injection and settlement

**Ruling:** The complete **EXISTS** `NativeVersionCrashPoint: String, Sendable, CaseIterable` surface is below. Construct `NativeVersionFaultInjector(point: point)`; `NativeVersionFaultInjector()` or `.init(point: .none)` disables injection. A reached point throws **EXISTS** `NativeVersionSimulatedCrash` whose `.point` identifies the interruption. Do not assume reusing the injector disables it after a throw. Construct a fault-free actor/input for recovery.

| Case | Public operation that reaches the point |
|---|---|
| `.none` | No interruption; control run |
| `.objectWrite_afterTempWrite` | Facade `stage(..., fault:)`, object write |
| `.objectWrite_afterFsync` | Same stage operation |
| `.objectWrite_afterRename` | Same stage operation |
| `.manifestWrite_afterTempWrite` | Facade `stage(..., fault:)`, manifest write |
| `.manifestWrite_afterRename` | Same stage operation |
| `.manifestWrite_afterRefsCommit` | Same stage operation |
| `.journalWrite_afterJournalWritten` | Facade `activate`, `rollback`, or `undo`, each with `fault:` |
| `.journalWrite_afterCheckoutBuilt` | `activate` always; `rollback` only when the target's checkout was not retained (a target older than the fallback); `undo` never (its target is the previous current version, whose checkout is always retained, and a retained checkout is verified, not rebuilt, so the point is not reached). Corrected 2026-10-02 from the crash-point analysis (ROOT_keepcount-crashpoints.md). |
| `.journalWrite_afterPointerWrite` | Same three swap operations |
| `.journalWrite_beforeJournalDelete` | Same three swap operations; also settlement finalization where reached |
| `.gcSweep_midSweep` | `facade.gc.markAndSweep(graceSeconds: 0, fault: injector)` with an independently created unreferenced object eligible for sweep |
| `.migration_midRename` | `facade.migrateLegacy(appId:projectId:legacyRevisionsRoot:currentRevisionId:fallbackRevisionId:fault:)` or `NativeStoreMigration.migrate(..., fault:)` |

Note (2026-10-02): Test each journal point with each swap operation it applies to (table above). Recovery and refused-prune attempts may legitimately rewrite `undo-offer.json` and `features.json`, and a crash moves the current-version pointer files, so an interruption oracle must hash only immutable content (objects and revision manifests), not the whole store root, and compare read-only refusals against the post-interruption snapshot.

For Core-adapter coverage, pass the injector through the **NEW** section 1 `versionFault:` initializer input on `NativeShellLibraryCoordinator` or `NativeRevisionStore`; the builder must forward it to the applicable facade operation and recovery. For direct facade coverage, pass `fault: injector` on that call. There is no `fault:` argument on coordinator `activate`, `revert`, or `pruneStorage`. Stage inputs, all **EXISTS**, are:

```swift
try await facade.stage(
    appId: app, projectId: project, revisionId: nextId,
    baseRevisionId: currentId, contentHash: nextContentHash,
    createdAt: nextPackageTime,
    files: [NativeVersionStagedFile(path: "index.html", data: nextBytes,
                                   mediaType: "text/html")],
    fault: injector
)
```

Use valid independently generated identities/content hashes and distinct new bytes so a write really occurs. For activate, first stage a child of current without a fault, then `activate(appId: app, projectId: project, revisionId: child, fault: injector)`. For rollback, arrange a valid ancestor/fallback and call `rollback(appId: app, projectId: project, revisionId: ancestor, fault: injector)`. For undo, first perform a fault-free rollback to create the offer, then `undo(appId: app, projectId: project, fault: injector)`. For migration use the legacy arrangement in 7.6 and pass `fault:` to `migrateLegacy` with current V8/fallback V7. Test each journal point with each swap operation it applies to (see the table above: undo never reaches `.journalWrite_afterCheckoutBuilt`, and rollback reaches it only toward a version older than the fallback, whose checkout was not retained) on fresh fixtures.

**Settlement observable:** `try await facade.recoverIfNeeded(appId: app, projectId: project, fault: .init())` returns **EXISTS** `NativeVersionRecoveryOutcome`: `.clean`, `.rolledBackIncompleteSwap(revisionId:)`, `.completedSwapAfterCrash(revisionId:)`, or `.stuck(revisionId:)`. The first three permit the next prune only when `facade.state.readJournal(appId:projectId:) == nil` and any migration journal is done. `.stuck`, a thrown recovery error, or a remaining unsettled journal forbids collection. An interrupted migration is first resumed with the same fault-free `migrateLegacy` arguments; `NativeStoreMigration(legacyRevisionsRoot: legacy, v1Root: root).readJournal(appId:projectId:)?.done == true` proves migration completion. `recoverIfNeeded` alone is not a migration-input substitute. Repeat recovery once without a fault and expect `.clean` with no swap journal; independently verify current/fallback bytes, not just the outcome enum.

**Recipe, check 18:** For each non-none case, arrange the applicable operation above at keep-all with cap room, inject, and verify the thrown crash point. Immediately capture revision content/manifest hashes and allocated blocks without calling a recovery-capable getter. Stage/object/manifest failures must not count-prune prior usable revisions. A swap or migration with an unsettled journal makes `planVersionKeepCount(.keepTwo)` throw `NativeStorageError.recoveryRequired` without repairing it. To test explicit-prune refusal, use a swap stopped at `.journalWrite_beforeJournalDelete` and construct the coordinator with `versionFault: .init(point: .journalWrite_beforeJournalDelete)` so recovery remains interrupted; `pruneStorage(identity:)` and `setVersionKeepCount(.keepTwo)` must report failure, not a successful result, and perform no count/cap deletion or preference write while unsettled. Compare stored revision hashes against the post-interruption baseline; journal/pointer changes from attempted recovery are not pruning. If a particular point allows recovery to settle, subsequent pruning is legal and cannot be asserted to fail merely because a fault was once injected.

Then reconstruct without `versionFault`, resume migration if applicable, await the settlement checks above, and call `setVersionKeepCount(.keepTwo)` once as the ordinary save-and-prune operation. Compare its freed/retained maps with independent hashes and allocation; roles and unavailable versions survive and eligible excess is freed before return. For migration retain the first-launch deferral in 7.6 before this prune. `.none` follows the same recipe without an interruption/refusal assertion.

Object/manifest points and `.gcSweep_midSweep` do not by themselves create an unsettled swap journal. GC may have swept eligible orphan objects before its interruption; those are not stored protected versions, so a zero-byte-change assertion on that direct GC call is incorrect. Cover the journal collection barrier separately for **every** configured non-none injector: arrange the same known unsettled swap, make the read-only keep-count plan with that injector installed, and observe `recoveryRequired` plus no pruning. A barrier refusal must occur before reaching any collection crash point. This separates the no-pruning-while-unsettled recipe from fault reachability and never treats an unhit injector as a simulated crash.

### 7.4 Local-only and catalog-unavailable

**Rule, minor interpretation for the owner:** For Core storage eligibility and the Features label, a never-offered local revision and a formerly offered revision absent from the current catalog are treated identically. Local-only means built locally **and absent from the catalog**, as SPEC 2.5 states. No persisted origin flag or catalog-history API is required. Represent both by omitting their ids from the identity's injected `downloadableRevisionIds` set. The pure function's explicit `localOnlyRevisionIds` remains a separate protective input and may not be ignored, even if a caller supplies overlapping sets. This interpretation changes no owner protection or K choice.

**Recipe, checks 11 and 20:** Start with keep-all and cap room. Generate a local package L, inspect it with `coordinator.reviewImport(packageBytes: localBytes, expectedIdentity: identity)`, then use the returned `reviewToken` and `packageSHA256` in `approvePendingReviewLocallyAndStage(reviewToken:packageSHA256:)`. Activate L normally and deliver later children so L becomes older history. The catalog fixture never includes L. For a separate historical revision U, include U in the offers when staged through the usual reviewed/approved delivery path, then remove U from the offers before lowering K. No origin assertion is needed: after `setVersionKeepCount(.keepTwo)` and cap enforcement, both usable hashes survive, and their non-role rows from `featureHistory(identity:)` have `isOnThisPhone == true`, `canDownload == false`, and `storageStateLabel == "Kept on this iPhone (not available to download)"`. In the pure recipe supply `localOnlyRevisionIds: [L]` and an offered set omitting L/U; both survive without consuming additional ordinary slots. Include a separate ordinary offered old revision to prove the same prune actually frees eligible history.

### 7.5 Pending in the pure policy

**Ruling:** Pending is derived exactly as `retainedSet` does: among facts with `baseRevisionId == currentRevisionId` and `revisionId != currentRevisionId`, choose the greatest `createdAt`, breaking ties by greatest `revisionId`; no explicit pending argument is needed.

**Recipe, check 9:** Generate `RevisionFact(revisionId: "C", baseRevisionId: "F", createdAt: "2026-09-28T00:00:00Z")`, fallback F, and two staged candidates P1/P2 based on C with times `2026-09-29T00:00:00Z` and `2026-09-30T00:00:00Z`. Call `NativeStorageRetentionPolicy.retainedRevisionIds(revisions: facts, currentRevisionId: "C", fallbackRevisionId: "F", pinnedRevisionIds: [], localOnlyRevisionIds: [], downloadableRevisionIds: Set(facts.map(\.revisionId)), keepCount: 1)`. The result contains C, F and P2; P1 receives no pending protection and is absent with no ordinary slots left. Give P1/P2 the same time and ids ordered P1 < P2; P2 still wins regardless of input order. Change P2's base to F and P1 becomes pending. These plain generated policy ids need not be package hashes; disk fixtures do. K=1 remains policy-only, never a saved choice.

### 7.6 Legacy migration inputs

**Ruling:** The **EXISTS** module-test idiom is `VersionsLegacyFixture.revision(id:base:seed:createdAt:fileCount:changes:)` followed by `VersionsLegacyFixture.write(revisions:to:)` in `VersionsTestSupport.swift`, and the public migration seam is `NativeVersionStore.migrateLegacy(...)` named in 7.3. The helper is test support, not a public product API. Its placeholder app/project/hash fields and binary entrypoint are suitable for module migration tests, not a valid coordinator-first-launch fixture. Do not claim coordinator coverage by pre-migrating that unvalidated helper fixture or by assuming `NativeRevisionStore` exposes facade components.

**Recipe, check 19, coordinator first launch:** Use eight independently generated valid web packages with a trusted fixture `DeliveryApprovalAuthority`. Call **EXISTS** `DeliveryPackageV1Validator().validate(packageBytes: bytes, approvalAuthority: authority)` for each, obtaining **EXISTS** `ContractValidatedDelivery`. Reproduce the helper's legacy file-writing idiom from these receipts, without invoking stage/migration yet: write each receipt file's `.data` to `root/content/<app>/<project>/revisions/<revisionId>/content/<path>`. Write sibling `metadata.json` with the receipt's `contractVersion`, `appId`, `projectId`, `baseRevisionId`, `revisionId`, `manifestHash`, `contentHash`, `createdAt`, `manifest`, `changes`, and `files`; each file entry has `path`, `sha256`, `bytes`, `mediaType`, omitting `data`. The manifest has `displayName`, `runtimeType`, `entrypoint`, `minShellVersion`, `requestedCapabilities`, `dataNamespace`, `dataUpdatePolicy`. Copy values exactly, preserving hash prefixes and valid HTML entrypoint; omit absent optional changes. This is a documented on-disk input fixture, not a new factory or private hook.

Set the legacy active pointer using **EXISTS** `try NativeVersionStateFiles(root: root.appendingPathComponent("state"))` and `writeActive(NativeVersionActivePointer(currentRevisionId: V8, fallbackRevisionId: V7), appId: app, projectId: project)` with no fault. Do not create `store-format` or pre-run migration. Independently record all eight content hashes and a reader-data sentinel. Construct `NativeShellLibraryCoordinator(rootURL: root, defaults: suite, downloadableRevisionIds: offers)` with an empty/default-2 suite, all eight offered, and cap room. Await `refreshLibrary()` and `launchActive(identity: identity)` to exercise discovery/migration and the first verified launch. All eight usable hashes and the sentinel must survive both operations. Construct `try NativeRevisionStore(rootURL: root, appId: app, projectId: project, shellVersion: "1.0.0", defaults: suite, downloadableRevisionIds: offers)`, await its `revisionSummaries()` to initialize its migrated projection, then `storageMigrationWarning()` must return exactly `"Older versions will be cleared the next time Iris tidies storage."`. The warning must survive adapter reconstruction until the next ordinary prune; Host-visible copy is a separate gate. Finally await one `coordinator.pruneStorage(identity:)`; current V8/fallback V7 remain, all six eligible older hashes are freed, eight ledger rows remain, and independent allocated blocks decrease truthfully. All fixture creation is work for the separate test author; this unit changes no test file.

### 7.7 Unfinished starter chain

**Ruling:** No special in-progress chain role is required: a chain resumes by staging the next package onto the active revision, which is protected, and that next staged child has the ordinary pending protection until activation. Earlier completed prefix versions beyond current/fallback may be freed when offered and beyond K; resume must not depend on their bytes.

**Recipe:** Generate a valid three-package chain A, B(base A), C(base B), all offered. Through `reviewImport`, `approvePendingReviewLocallyAndStage`, and `activate(identity:revisionId:)`, install A then B at K=2. Reconstruct the coordinator; current B/fallback A remain. Stage C through the same reviewed local-approval calls without activating it, then await `pruneStorage(identity:)`: B, A and pending C all remain usable. Reconstruct again and call **EXISTS** `NativeStarterInstaller().installOne(NativeStarterInstaller.AppChain(displayName: "Fixture", orderedPackages: [aBytes, bBytes, cBytes]), label: "Fixture", into: coordinator)`. Expect an installed result with final revision C; `libraryEntry(identity:)` reports C current/B fallback and both launch trees verify. An ordinary prune may now free offered A at K=2. The result demonstrates safe stage/activation boundaries and resume; it is not evidence of observing a private installer phase.

### Builder notes for these addenda

- Additional NEW names: none. Use the already marked NEW settings/catalog/fault inputs and projections; do not add Core `resetKeepCount`, coordinator Undo, a pending parameter, an origin flag, or a chain-specific retention role to satisfy these recipes.
- Forward `versionFault` into the applicable facade write and settlement boundaries; refuse pruning while settlement fails. Preserve migration input validation and the first-launch warning/deferral across adapter recreation. Direct facade Undo evidence requires the explicit Core policy prune and does not establish the Host integration.
- This addendum ran no compiler, build, test, Simulator operation, or native gate. Its verification is the seven public-API recipes, declarations checked, unchanged-prefix comparison except the two stated corrections, and a whole-file forbidden-character scan.

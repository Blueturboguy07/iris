# Feature version history on the iPhone: one app, a Features page, small storage

Design lead: Fable 5.1, 2026-09-28. Route G2 (phone half), owner's words the same day: "version history should be baked into the phone as well, but ... if you have 10 different apps for each version it's not only cluttered but not space efficient at all". Design only; no code was edited. Built on the code on disk today (`mobile-shell/native/Sources/IrisMobileShellCore/NativeRevisionStore.swift`, `NativeStorageRetentionPolicy.swift`, `NativeShellLibraryCoordinator.swift`, `NativeRevisionHistory.swift`, `DeliveryPackageV1Validator.swift`), the desktop design (`../../design/DESKTOP_UX_SPECS.md` Part A, `FeatureVersionLedger.swift`, D3 and R2-feature-removal-delivery handoffs) and the store design (`../../design/MOBILE_STORE_DESIGN.md` sections 7.1, 8, 13.4).

Measurements in `measurements/` (MEASURE.md, DELTA.md, measure.json, the two read-only scripts). Every number below that is not marked "estimate" comes from those files.

Units start only after round 2's mobile integration finishes (`mobile-shell/**` is locked until then).

---

## 0. What the measurements say (the ground for every estimate)

Method: `measure_dedupe.py` decoded every `.irisapp` in the bundled starters (`mobile-shell/native/IrisMobileShellApp/Resources/Starter`, the 01-base, 02-update, 03-update, 03-final and 04-final chains for Kneecap, NutAI and FreeHarmony) and every `.irisapp` under `outputs/.../core-acceptance/multiapp-storage-20260920`, re-hashed every file (0 mismatches over 31 unique revisions, 438.6 MB of package content), linked revisions by `baseRevisionId`, and counted bytes shared between consecutive revisions by path+hash (today's clonefile rule) and by hash alone (a content-addressed store). `measure_delta.py` then took every changed file between consecutive starter revisions and measured `zstd -19` alone and `zstd --patch-from` the previous revision's file.

| Fact | Value |
|---|---|
| Average size of one version (latest of the three real apps) | 19.2 MB (Kneecap 20.7, FreeHarmony 27.6, Nut AI 9.2) |
| Files per version | 26 to 109 (Kneecap 51, Nut AI 26, FreeHarmony 109) |
| Bytes of an update already present in the previous version, byte-weighted over the 13 real consecutive pairs | **69.8 percent** (77.1 MB new out of 255.0 MB delivered). Per app: FreeHarmony 96.4, Nut AI 64.5, Kneecap 55.6 percent |
| Same, by hash alone instead of path+hash | 70.0 percent (renamed files add 0.4 percent, FreeHarmony only) |
| Whole chain, one copy per unique file versus full copies | Kneecap 8 revisions 2.02x smaller, FreeHarmony 4 revisions 3.77x, Nut AI 4 revisions 1.94x; everything together 2.82x (438.6 MB to 155.5 MB) |
| Files shared between different apps | 1 file, 34 KB. Cross-app sharing is real in principle and worth nothing today |
| What the new bytes are | one or two rebuilt bundles per update (Kneecap `assets/iris-classic.js` 6.0 MB, Nut AI `iris-entry-*.js` 3.0 MB); FreeHarmony's are 85 to 100 small Next.js chunks |
| Those rebuilt bundles compressed alone | 11 to 36 percent of raw |
| Those rebuilt bundles as a delta from the previous revision's file | 0.0 to 25 percent of raw; 5 of 8 pairs under 5 percent (Kneecap 02 to 03: 6.0 MB of new bytes become a 760 byte delta) |
| Unique files under 4 KiB | 195 of 451; 4 KiB block rounding costs 0.7 percent |

Planning numbers used below: **S = 19.2 MB per version, n = 30 percent new bytes per update** (whole files), cold-object compression to 20 percent of raw (phase 2, estimate from the "zstd alone" column), delta to 5 percent of raw (phase 3, median of the measured pairs).

What today's layout already does: `NativeRevisionStore.stageIntoTemporaryDirectory` clones unchanged files from the active revision with `clonefile`, so on APFS the physical bytes of an adjacent chain are already close to the unique bytes (the 2026-09-20 receipt measured 88.8 percent less physical space on a 100 percent reuse chain). The content-addressed store is therefore not sold as "smaller than today for two adjacent versions". It is what makes longer histories per app, hundreds of apps, exact accounting and garbage collection possible at all, because today every version is a full file tree (up to 109 inodes), every library refresh re-hashes every byte of every stored version (`revisionSummaries()` calls `verifyStoredRevision` with content hashing; the 224 ms measured at 100 apps x 5 versions was on tiny synthetic revisions, at real sizes that is 9.5 GB of hashing per refresh), and the measured size of a version over-counts as soon as its base is pruned (`NativeStorageBlockMeasurement.dedupingAllocatedBytes` only corrects against the direct base). The configurable keep count in section 1.6 governs which downloadable older versions stay on the phone.

---

## 1. What the person sees

One app per app, always. My apps lists an app once (`iris.store.my-apps.row.<appId>`); versions never appear as apps, never get icons, never appear in Browse or Search. The store design's "Versions" screen (section 7.1) becomes the **Features** page described here; its kept identifiers stay valid.

### 1.1 The Features page (pushed from the installed app page, from a Storage row, or from My apps' row menu)

Title "<name> features". Under it, always: "Iris keeps 2 versions of each app by default: the one you use and the one before it. You can change this in Storage. Pinned versions and versions only on this iPhone are kept too. Your data is separate and is never changed by any of this." (`iris.store.versions.explanation`, kept).

Rows, newest first, one per version, 8 shown then "Show all N" (`iris.store.versions.show-all`, 240 pt scrolling area, lazy rows, same rule as desktop A.7.1):

- Title: the feature title the package carries ("Added: Dark mode", "Removed: Auto-scroll", section 2.6). A package without one reads "Update from Sep 21". The first version reads "First version".
- Detail line, words never color: "On this iPhone now" (current), "Kept as backup" (fallback), "Pinned: kept until you unpin it", "Kept (within your count)" (older downloadable version within K), "Kept on this iPhone (not available to download)" (a protected local-only or catalog-unavailable version), "Not on this iPhone. Download to go back (6 MB)" (objects freed, catalog still has it), "No longer available" (objects freed and nothing to download), "Downloaded, not switched on yet" (pending), D3's "Stopped before it finished Sep 25 · nothing was changed".
- Trailing controls, 44 pt, borderless buttons (R2-CP-4 rule: one tap fires one button): **Go back** (`iris.revert.<rev>`, kept, on any earlier version that is on the iPhone; reads "Switch on" (`iris.activate.<rev>`, kept) on a pending one), **Download** (`iris.store.versions.download.<rev>`), the **pin toggle** (`iris.storage.pin.<rev>` / `iris.storage.unpin.<rev>`, kept; label "Keep" / "Kept", VoiceOver "Pin this version, keeps it when Iris frees space"), and **Remove** (`iris.store.versions.remove.<rev>`).

Below the rows: the status block (progress sentence, done sentence with **Undo** (`iris.store.versions.undo`), failed sentence with one next step), then "Space used by <name>: 71 MB, 3 versions" (`iris.store.versions.space-used`), **Free up space (48 MB)** (`iris.store.versions.free-up`, only when the per-app plan frees something), and at the bottom **Remove <name> from this iPhone** (`iris.store.versions.remove-app`).

### 1.2 What each action means, in plain words

| Action | What it does | What the person reads |
|---|---|---|
| Go back (an earlier version on the iPhone) | Switches the app to that version. Local, no network, under 1 s: the checkout is rebuilt from stored files and the pointer swaps. The version it left becomes "Kept as backup". | Confirmation "Go back to "<title>"?" body "<name> will be the way it was on <date>. Everything added after that is switched off, not deleted; you can come back. Your data stays as it is." Buttons "Go back" (default is "Keep it"). Done: "Went back to "<title>"." with Undo. |
| Remove (the newest feature) | Same as Go back to the version before it. Local. | Confirmation "Remove "<title>"?" body "Takes "<title>" out of <name>. Once it starts it can't be stopped. You can undo it afterward." Buttons "Remove this feature" (destructive, never default) and "Keep it" (default, Escape and tap outside). Done: "Removed "<title>" from <name>." with "Undo this removal". |
| Remove (an older feature, keeping the newer ones) | The phone cannot rebuild an app; only Iris on the person's Mac can (desktop R2). The row's Remove opens a sheet, nothing changes on the phone. When the Mac later delivers the rebuilt version it arrives as a normal update whose title is "Removed: <title>". | Sheet: "To take out just "<title>" and keep the newer changes, open Iris on your Mac, go to <name> > Features, and remove it there. It then arrives here as an update." One button "OK". (Owner decision 5: a phone-to-Mac request so this becomes one tap.) |
| Undo | Re-activates the version that was current before the last Go back or Remove. Offered until the next Go back, Remove, update or Remove app; survives closing the page and relaunching the shell (offer is stored). | "Undo this removal" / "Undo going back". Running: "Putting it back...". Done: "Undone." Failed: "Iris couldn't undo this." with "Try again". |
| Keep (pin) | Marks a version as never freed. At most 2 per app (existing `pinLimit`). | Third pin: "You can keep up to 2 versions of this app. Unpin one before pinning another." |
| Download | Fetches that version's package again (catalog, owner decision 3), stores it, then offers Go back. | Button reads "Downloading 40%", then "Go back". Offline: "Needs the internet to download this version." |
| Free up space | Frees eligible downloadable versions beyond K, then any additional eligible kept-tier versions required by the cap (section 2.5), and reports allocated bytes. | "Freed 48 MB of allocated storage. Kept the current version, the one before it, and 1 pinned version." or "There was nothing eligible to free for <name> right now." |
| Remove app | Deletes the app's code and versions. The person's data stays unless they also choose to delete it (owner decision 4). | Confirmation "Remove <name> from this iPhone?" body "Its versions are removed. Your data in <name> (34 MB) stays unless you also delete it below, so installing <name> again finds it." Toggle "Also delete my data in <name>" (off by default), buttons "Remove" (destructive) and "Keep it". |
| Update (app page or My apps) while the person is on an older version | An update is built on the newest version. Iris first switches the app back to the newest stored version, then applies the update. | Under the Update button: "Updating puts back the changes you went back from." |

### 1.3 State machine

Mirrors the desktop reducer `FeatureVersionHistoryInteraction.reduce` (DESKTOP_UX_SPECS A.2): `idle`, `confirming(row)`, `removing(row, phase)` (also used for Go back), `done(message, undoOffer)`, `failed(reason, nextStep)`, `paused`, `paused(stuck)`, plus two phone-only states: `downloading(row, percent)` and `explainingMacRemoval`. Rules kept exactly: a double tap never starts twice; Return and tap-outside never remove; every state except `removing` has a way out; `removing` on the phone is under 1 s and the confirmation says it cannot be stopped; reopening the page during a live operation shows the running row, not the paused banner (D2 A.7.3); the 200 ms rule for every tap. Phases for the sentence under the row: "Getting ready.", "Checking the stored files.", "Putting <name> in place.", "Finishing up." `paused` appears when a journal (section 2.4) says a swap did not finish; "Check again" finishes or rolls back the journal; after two unsettled checks the honest sentence "Iris still can't finish this change. <name> keeps working as it is. Quit and reopen Iris, then check again."

### 1.4 When space is low

- Under 500 MB free (existing `defaultMinimumFreeBytesForStaging`): Download and Update are refused before any byte is written; "Not enough free storage to download this. The version you have keeps working." Go back to a stored version still works (it needs no new bytes on APFS; on a copy volume it needs the version's size and says "Needs 20 MB free").
- The count rule in section 2.5 removes eligible downloadable versions beyond K at the next prune. The 2 GB code cap still removes eligible kept-tier versions when allocation is over the cap. Both constraints apply: the stricter one wins. A version is eligible only when the catalog says it can be downloaded again and it is not a retained role or local-only version. The Storage screen says: "Versions beyond your keep count are freed when Iris next tidies storage. The 2 GB limit can free more."
- When protected versions alone exceed the cap (section 3): nothing is freed by force. Storage screen: "Your apps' protected versions use 2.5 GB, more than the 2 GB limit. Iris keeps them all. Raise the limit or remove apps you don't use." Offloading after 30 days remains owner-pending; no version is offloaded until that decision is made. If later approved, it must obey section 8 and must not free a version that cannot be downloaded again.

### 1.5 Accessibility and identifiers

Every control above has an identifier in `NativeAccessibilityIdentifiers.swift` (`iris.store.versions.*` family, kept ones unchanged). Rows are one accessible element: "<state word>: <title>, <date>" (mirrors `voiceOverRowLabel`). Announcements: each phase at default priority, the outcome at high priority. Reduce Motion: sentences are the progress. Dynamic Type up to accessibility sizes keeps one column, controls wrap under the text.

### 1.6 How many versions stay on this iPhone

The public API and acceptance-call mapping for this setting are defined in [KEEPCOUNT_PUBLIC_API.md](KEEPCOUNT_PUBLIC_API.md).

The global setting is on the Storage screen, directly beside the existing code-cap setting. Its exact label is **Versions kept per app** (`iris.store.storage.keep-count`). Its help text is **Current and previous versions count. Pinned, pending, and versions only on this iPhone are kept separately.** The choices are **2 (Default)**, **3**, **5**, and **Keep all while there is room**. Two is the owner-decided default: the version in use and the version before it. Three and five let someone retain a short or longer downloadable history. Keep all while there is room restores the former count policy; the 2 GB cap and section 8 protections still apply. The exact reset control is **Reset to 2 (Default)** (`iris.store.storage.keep-count.reset`).

This is one global setting for all apps. Per-app choices are deferred because the Storage screen and existing coordinator apply global policy; per-app controls would make the same global cap harder to explain and audit. The choice is saved in the shell's preferences, survives force quit, relaunch, and shell update, and applies to existing as well as newly installed apps. If no saved value exists, use 2. Reset to 2 changes the saved value to 2 and immediately applies the lower-count behavior in section 1.7.

Accessibility identifiers are `iris.store.storage.keep-count`, `iris.store.storage.keep-count.option.<2|3|5|all>`, and `iris.store.storage.keep-count.reset`. The control has the accessible label **Versions kept per app**, announces the selected choice, and remains operable at accessibility Dynamic Type sizes. Acceptance for visible copy, selection, persistence, reset, and identifiers is in section 5.1.

### 1.7 Lowering and raising the keep count

When a selection lowers K, show a confirmation before saving it. The exact sentence is **Keep <K> versions per app? Iris will free <amount> of allocated storage now. This is the space the files give back to your iPhone.** `<amount>` is the planned `bytesReclaimed` from `prunableAllocation`, formatted for display and based on allocated bytes, not logical version sizes. Buttons are **Keep <K> versions** and **Not now**. Not now leaves the setting, files, and rows unchanged.

After confirming, save K and prune before closing the setting sheet. The result sentence is **Kept <K> versions per app. Iris freed <amount> of allocated storage.** If no eligible objects can be freed, say **Kept <K> versions per app. Nothing could be freed because the other versions are protected or unavailable to download.** A freed revision's Features row remains and reads **Not on this iPhone**; show **Download** only when the current catalog offers its package, otherwise show **No longer available**. Raising K does not restore freed files. Say **Raising this number will not bring back versions that were freed. Download a version again if the catalog still offers it.** Acceptance is in section 5.1.

---

## 2. Storage design

### 2.1 Layout (root stays `Library/Application Support/IrisMobileShell/v1`)

```
v1/
  objects/                      one file per unique content, shared by every app and version
    ab/abcd...ef                sha256 hex, two-character fan-out, read-only (0444), excluded from backup
    tmp-<uuid>                  in-flight writes, swept on launch
  manifests/<appId>/<projectId>/
    rev-sha256:<id>.json        the version: the StoredRevision fields as today (file table with path, sha256, bytes, mediaType), 5 to 11 KB
    rev-sha256:<id>.json.tomb   tombstone while a version is being removed
  checkouts/<appId>/<projectId>/
    rev-sha256:<id>/content/... the launchable tree of the current version (and, while it exists, the backup), built by clonefile from objects; excluded from backup
    rev-sha256:<id>/checkout.json  { "cloned": true|false, "builtAt", "verifiedAt" }
  state/<appId>/<projectId>/    unchanged: active.json (currentRevisionId, fallbackRevisionId), pinned-revisions.json, delivery-nonces/<sha256(nonce)>
    features.json               the Features ledger: one row per version ever seen (title, kind, createdAt, revisionId, undoneAt, stoppedBeforeFinishing), 300 bytes per row, never pruned
    journal.json                the in-flight swap (section 2.4); absent when nothing is in flight
    undo-offer.json             the current Undo offer (from, to, kind, at)
  reader-data/<appId>/<projectId>/<namespace>/   unchanged, user files, never touched by any version operation, backed up
  gc/
    refs.sqlite                 reference counts (object -> count) and the object index (size, first seen); rebuildable
    dirty                       marker: a GC or migration did not finish; rebuild refs from manifests on next launch
  library.json                  one row per app (identity, displayName, current, fallback, offloaded, lastOpenedAt, codeBytes): the My apps index, rebuildable
  store-format                  "2" once migrated
```

WKWebView still loads the app from a real directory (`readAccessRootURL` = the checkout's `content`), so the current version is always a checkout. On APFS a checkout costs no physical bytes (clones); `checkout.json.cloned = false` records a copy fallback so measurement counts it (section 2.5).

Objects are written once, verified once at write (hash of the bytes just written), and never modified. A version's identity is unchanged: `revisionId` is derived from `contentHash`, which covers the sorted file table, so a manifest proves itself against its own name without touching objects (`NativeSecurity.revisionIdentity` stays the check).

### 2.2 Stage (an update or a download arrives)

1. Same guards as today, same order: free-space guard, `DeliveryPackageV1Validator.validate`, `validateDelivery` (contract 1, identity, base must equal the current revision, nonce not used, shell version, capabilities, data namespace equal to the current version's).
2. For each file: if `objects/<sha>` exists, re-hash it (or trust it when `refs.sqlite` says verified and the mtime and size match; owner-visible rule: launch always re-verifies the checkout anyway) and skip; else write to `objects/tmp-<uuid>`, fsync, rename to `objects/<sha>`, chmod 0444. A concurrent writer of the same object loses the rename race harmlessly (rename over an identical file).
3. Write the manifest to `manifests/.../tmp-<uuid>.json`, fsync, rename to `rev-sha256:<id>.json`. Increment refs for its objects (one SQLite transaction). If the process dies between 2 and 3, the objects are orphans and the next GC sweeps them. If it dies inside 3 after the rename but before the refs commit, `gc/dirty` (written before step 2) makes the next launch rebuild refs from manifests.
4. Record the delivery nonce (unchanged). Append the Features row (title from section 2.6, kind added) to `features.json`.
5. Staging never touches a checkout or `active.json`. Idempotent: staging the same package again verifies the manifest and returns `alreadyStaged`, as today.

### 2.3 Activate, Go back, Undo (the pointer swap)

1. Write `journal.json` `{ op, from, to, startedAt, phase: "building" }`.
2. Build `checkouts/.../tmp-<uuid>/content` from the manifest: for each file `clonefile(objects/<sha>, dest)`; on failure copy; then verify the whole tree exactly as `verifyExactContentTree` plus hash does today; write `checkout.json`; rename the folder to `rev-sha256:<to>` (already present from an earlier switch: verify it instead of rebuilding, and rebuild it only if verification fails).
3. `activate` keeps the contiguity rule (`to.base == current`); `rollback` keeps the namespace rule and additionally requires `to` to be an ancestor of current or the fallback (what `NativeRevisionHistoryRow.canRevert` computes today). Write `active.json` atomically `{ current: to, fallback: from }`.
4. Write `undo-offer.json` `{ from: to, to: from, kind }` for Go back and Remove (not for a normal update). Append the Features row (kind removed or restored, target = the row it undid).
5. Delete `journal.json`. Delete the checkout of any version that is neither current nor fallback (its objects stay; only the clone tree goes).
6. Prune (section 2.5) runs after stage, activate, rollback, Undo, and launch. A stage prune runs after the pending manifest and nonce are durable. No prune may start while a journal or migration journal is unsettled.

Undo = the same sequence with `journal.op = undo` and the offer's pair; on success the offer is cleared and the removed or restored row gets `undoneAt`.

### 2.4 Crash safety and recovery on relaunch

On every launch and before every Features operation, in this order: sweep `objects/tmp-*` and `checkouts/.../tmp-*`; if `gc/dirty` exists, rebuild `refs.sqlite` from the manifests and remove the marker; if `journal.json` exists, settle it: phase `building` means the pointer never moved, so remove the temporary checkout and delete the journal (nothing changed, the row reads D3's "Stopped before it finished · nothing was changed"); a journal whose `to` is already `active.json`'s current means the swap finished, so finish steps 4 to 6. A journal that cannot be settled twice (checkout verification keeps failing because an object is damaged) is `paused(stuck)` and offers "Keep the app as it is now" (owner approved or not, same decision as desktop A.5).

Launch (`launchDescriptorForActiveRevision`): verify the current checkout; if it fails, rebuild it from objects; if an object is damaged (hash mismatch), fall back to the fallback version exactly as today and mark the damaged object for re-download (its row reads "Not on this iPhone"). The person never sees a blank app because of a damaged file when a backup version exists.

Every multi-file step is "write to a temporary name, fsync, rename" on the same volume, the pattern `NativeRevisionStore.stage` and `removeRevisionCrashSafely` already use. Manifests and pointers are never edited in place.

### 2.5 Garbage collection, retention and measurement

Retained roles per app, unchanged from `NativeStorageRetentionPolicy.retainedSet` (R8.9): current, previous (fallback), pending (newest staged on current), and up to 2 pinned. A version built locally and absent from the catalog is protected too, as required by section 8 item 3. Define **K** as the global keep-count setting, default 2. K is the number of ordinary count slots: current and fallback occupy slots first, up to K; remaining slots go to the newest eligible downloadable older versions. Pending, pinned, local-only, and catalog-unavailable versions have separate protection and do not use additional K slots. If a protected version is also current or fallback, it occupies that slot once and remains protected even when K is lower than the number of protected roles. A version with no current catalog download offer is never freed by count or cap, even if that leaves more than K versions on disk. A per-app manifest count is therefore not a hard cap.

**Example with an eight-version history:** oldest to newest are V1 through V8; V8 is current, V7 is fallback, V6 is pinned, and V5 was built locally and is not in the catalog. V1 through V4 are downloadable. The table shows the result after a count prune, assuming the catalog still offers each version marked for count pruning.

| K | Retained by count | Retained on top of K | Freed by count |
|---:|---|---|---|
| 2 | V8 current, V7 fallback | V6 pinned, V5 local-only | V1, V2, V3, V4 |
| 3 | V8 current, V7 fallback, V4 | V6 pinned, V5 local-only | V1, V2, V3 |
| 5 | V8 current, V7 fallback, V4, V3, V2 | V6 pinned, V5 local-only | V1 |

If the catalog no longer offers a version shown under **Freed by count**, that version stays on the phone and K may be exceeded. The cap may retain fewer than K eligible old versions; pins, pending, fallback and local-only protection may retain more than K.

- Reference counts: `refs.sqlite` maps object to the number of manifests that list it. Stage increments; removing a version decrements; a count of zero makes the object collectable. Two apps listing the same object hold two references, so a shared library survives one app's removal (edge case 4.3).
- When objects are freed: run prune after each stage, activate, rollback, Undo, and launch, matching section 2.3 step 6, and immediately when K is lowered. Count pruning removes eligible downloadable versions beyond K, oldest excess first within each app, even when the byte cap is not exceeded. The 2 GB cap removes additional eligible kept-tier versions oldest `createdAt` first across apps using `planGlobalReclaim` when allocation is over cap. The stricter target wins: first satisfy K, then reclaim further for the cap. Never free a retained role, local-only revision, or revision the catalog cannot download again. When cap and count nominate different candidates, choose the oldest eligible candidate until both targets are satisfied or only protected/unavailable versions remain. Freeing a version means tombstone-rename its manifest, decrement its objects, delete objects that reach zero, delete the tombstone, keep its Features row, and show the row as **Not on this iPhone**. `bytesReclaimed` and `prunableAllocation` are the allocated bytes (`st_blocks`) of objects that reach zero, not logical version size. Shared objects count as reclaimed only when their last reference is removed. Do not free anything while a journal or migration is unsettled.
- Measurement (Storage screen, per app and total): sum of `st_blocks` over `objects/` attributed to apps by manifest references (an object shared by two apps is charged half to each for the per-app bars, and once in the total), plus checkouts whose `checkout.json.cloned` is false. Checkouts that are clones are not counted (an APFS clone's inode reports full `st_blocks` while sharing the blocks; the 2026-09-20 note already warns about this). "Your data" stays a separate number from `WKWebsiteDataStore` plus `reader-data`, as today.
- Full mark-and-sweep (verifies the counts): on launch when `gc/dirty` exists, after a migration, and at most once a day in the background: mark every object named by any manifest, sweep `objects/` for unreferenced files older than 10 minutes (so an in-flight stage is never swept), fix any count that disagrees. Budget: under 1 s at the cap (section 3).
- Pins count against the cap; if pinned plus current versions alone exceed it, nothing is freed by force and the Storage screen says so (section 1.4). Offloading (owner decision 2) frees a whole app's objects and checkout, keeps manifests, rows, pins, pointer and data, and sets `library.json.offloaded`.

### 2.6 The feature title (how "Added: Dark mode" reaches the phone)

Contract v1 manifests are exact-key (`CONTRACT.md`: unknown fields are rejected so a security field cannot be ignored). Proposal: contract v1.1 adds one optional manifest field `changes: [{ "title": string (1 to 120 chars, no control characters), "kind": "added" | "removed", "target": "<revisionId>" | null }]`, covered by `manifestHash` like every other manifest field (the publisher computes it, the shell recomputes it: `NativeSecurity.revisionIdentity`), emitted by `mobile-shell/publisher/index.mjs` from Iris desktop's `FeatureVersionRecord.name` and `kind` when the package comes from an edit, and by hand (`--change "Added: ..."`) otherwise. A shell that does not know the field refuses the package (exact keys), so the publisher emits it only when the manifest's `minShellVersion` is at or above the first shell version that accepts it. A package without `changes` shows "Update from <date>". The catalog's app page `whatsNew` (v2) stays the store-side sentence and is not used for rows, because it is per app, not per version.

### 2.7 Composition with what exists, and migration

- Public API of `NativeRevisionStore` stays (`stage`, `activate`, `rollback`, `activeRevisionId`, `fallbackRevisionId`, `revisionSummaries`, `readerDataDirectory`, `launchDescriptorForActiveRevision`, `pin`, `unpin`, `pinnedRevisionIds`, `storageAllocation`, `storageUsage`, `pruneStorage`, `prunableAllocation`, `removeSpecificRevisions`), so `NativeShellLibraryCoordinator`, the coordinator's global cap (`planGlobalCapEnforcement`, `enforceGlobalCap`), the Host views and existing callers keep compiling. `revisionSummaries()` reads manifests only (no content hashing); `storageAllocation()` reads `refs.sqlite`. Add coordinator accessors `versionKeepCount(defaults:)`, `planVersionKeepCount(_:defaults:)`, and `setVersionKeepCount(_:defaults:)` for the global K preference. Planning validates the declared choices and returns allocated `bytesReclaimed` for a decrease without changing preferences or files. Confirming calls `setVersionKeepCount`, saves K, and prunes immediately; cancellation makes no mutation. Raising K saves the preference without recreating freed files. Add these names to the version `PUBLIC_CONTRACT.md` before the independent test author starts.
- Contiguity: `validateDelivery`'s `base == current` and `activate`'s `base == previous.current` are unchanged. Delivery nonces are unchanged in place and meaning. Pins are unchanged (`pinned-revisions.json`, limit 2, `revisionNotAvailableToPin` now means "manifest present but objects freed" too).
- Migration, once per app, on first launch of the new shell, journaled in `state/<app>/<project>/migration.json` and resumable: for each `revisions/<rev>`: verify as today; for each file, `rename` it into `objects/<sha>` if that object does not exist yet (same volume, no copy, clone sharing preserved by APFS), else delete the duplicate; write the manifest from `metadata.json`; increment refs; for the current and fallback revisions, `rename` `revisions/<rev>/content` to `checkouts/.../<rev>/content` before moving files, and build their objects by cloning from the checkout instead. Write `features.json` rows from `createdAt` ("Update from <date>"; the first as "First version"). Remove `revisions/` last, write `store-format = 2`. A crash midway leaves both layouts partially present; the journal says which app and which revision, and the old layout is read-only until its record says done, so the app still opens from the old folder in the meantime. Time at the owner's phone (3 apps, 2 revisions each): under 2 s (renames only). Rolling back to an older shell after migration is not supported (TestFlight only today; note in the release checklist).
- iCloud backup: set `isExcludedFromBackup` on `objects/`, `checkouts/` and `gc/` at creation and after migration; `state/`, `manifests/`, `library.json` and `reader-data/` stay in the backup. A restore from backup lands in the "manifests present, objects missing" state, which is the same as offloaded: My apps rows read "Tap to download", Features rows "Not on this iPhone", data intact.

---

## 3. Scale math

S = 19.2 MB per version, n = 0.30 (measured). "Full copies" is today's logical layout and what a non-APFS volume would pay; today's APFS physical bytes for adjacent chains are close to the whole-file column but today's policy cannot keep more than 5 versions.

### 3.1 Bytes of app code on disk before any cap

| Apps x versions | Full copies (A x V x S) | Whole-file store, phase 1: A x S x (1 + n(V-1)) | Phase 2, cold objects compressed to 20 percent (estimate) | Phase 3, deltas at 5 percent (estimate) |
|---|---:|---:|---:|---:|
| 3 x 1 | 58 MB | 58 MB | 58 MB | 58 MB |
| 3 x 10 | 576 MB | 213 MB | 89 MB | 65 MB |
| 3 x 50 | 2.9 GB | 904 MB | 227 MB | 100 MB |
| 100 x 1 | 1.9 GB | 1.9 GB | 1.9 GB | 1.9 GB |
| 100 x 10 | 19.2 GB | 7.1 GB | 3.0 GB | 2.2 GB |
| 100 x 50 | 96 GB | 30 GB | 7.6 GB | 3.3 GB |
| 1,000 x 1 | 19 GB | 19 GB | 19 GB | 19 GB |
| 1,000 x 10 | 192 GB | 71 GB | 30 GB | 22 GB |
| 1,000 x 50 | 960 GB | 301 GB | 76 GB | 33 GB |

Reading: these no-cap rows describe storage demand, not the default retained count. With K=2, each app normally keeps current and fallback, plus protected pending, pinned, and local-only versions. The 2 GB cap can free further eligible downloadable versions beyond K. Retained roles alone (current plus backup, about 25 MB per app) exceed 2 GB at 80 apps, so over-cap messaging must describe protected versions and never promise forced removal. The former estimates of about 350, 1,700, and 6,900 extra versions under the cap apply only to **Keep all while there is room**, and remain storage estimates rather than the K=2 default.

### 3.2 Everything else

| Quantity | 3 apps | 100 apps | 1,000 apps | Budget |
|---|---|---|---|---|
| Manifests (versions with rows) at 1, 10, 50 versions | 3, 30, 150 | 100, 1,000, 5,000 | 1,000, 10,000, 50,000 | one file each, 5 to 11 KB; at 50,000 that is 400 MB, 0.13 percent of the objects it describes; versions freed by K or the cap keep a 300 byte row and may drop the file table |
| Features rows (`features.json`, 300 B each) | 45 KB at 50 versions | 1.5 MB total | 15 MB total, 15 KB per app | one read per page open |
| My apps refresh (`library.json`, 300 B per app) | under 1 ms | 30 KB, under 5 ms | 300 KB, under 50 ms | 500 ms at 100 x 5 (R8.10); proposed 500 ms at 1,000 x 50 |
| Features page open | one file read, 8 rows | same | same | 200 ms with 1,000 rows (lazy rows, 16 ms per frame), desktop A.7.1 |
| App launch | verify the current checkout: hash S = 19 MB | same | same | unchanged from today; about 60 ms of hashing on an A-series chip (estimate) |
| Go back or Remove (newest) | 26 to 109 clonefile calls plus verify | same | same | under 1 s |
| Memory | manifest 8 KB, rows 15 KB, index 1 KB | index 30 KB | index 300 KB; GC mark set at the cap about 100,000 references, 4 MB | Browse budget untouched (R8.4) |
| GC (mark and sweep) at the cap | 6 manifests | about 300 manifests, 6,000 to 20,000 objects | about 1,000 manifests with objects, same object count | under 1 s; incremental refcounts make the common path a few ms |
| Catalog and UI clutter | 3 rows in My apps | 100 rows, lazy list | 1,000 rows, lazy list (M2) | one row per app everywhere; Features page 8 rows plus Show all; Storage screen one row per app |

Fit with M4: `defaultGlobalCodeCapBytes` and `planGlobalReclaim` remain the global byte cap and planner. K is an additional per-app version-count ceiling; both policies select from the same eligible versions, and the stricter result wins. The scale table is a no-cap scenario unless stated otherwise. With K=2, the phone keeps current and fallback by default plus separately protected pinned, pending, and local-only versions. Keep all while there is room restores the former count policy, but not the section 8 safety protections.

---

## 4. Edge cases for long-term use

1. **Months of updates (50 versions of one app).** Rows: 50 x 300 B. With K=2, the current and fallback are retained by count; pins, pending, local-only revisions, and versions without a current catalog download offer are additionally protected. The count prune frees eligible downloadable history beyond K; the cap may free more eligible versions. Go back to a freed version offers Download only if the catalog still serves it. Old manifests keep their file table until their objects are freed, then keep only the row.
2. **An app removed and reinstalled.** Remove app deletes manifests, checkouts, pins, pointer, journal, offer, rows and the delivery-nonce markers (a reinstall of the same static package carries the same nonce; nonces protect one installed lifetime, which is how the contract's replay option is scoped), decrements refs, and keeps `reader-data` and the WKWebsiteDataStore identity (derived from appId, projectId and dataNamespace, never from a revision) unless the person chose "Also delete my data". Reinstall: same identity, the app finds its data. Objects the removed app shared with another app survive through the other app's references.
3. **Two apps sharing libraries.** Content addressing stores a shared file once; each app holds its own reference; measurement charges it half to each per-app bar and once in the total. Measured today: 34 KB across the three starters, so no promise is made about savings, only correctness.
4. **A version whose base is gone.** Manifests carry `baseRevisionId`; a freed base is only a missing manifest or missing objects, never a broken chain: the Features list still orders by `createdAt` and the ledger, `canRevert` still walks ancestors by id. Staging requires `base == current` and the current always has objects. Going back to a version whose base's objects are gone is fine (a checkout needs only its own manifest's objects).
5. **Low storage.** Section 1.4. Building a checkout on APFS needs no new bytes; the copy fallback checks free space first and refuses with the number needed.
6. **iCloud backup size.** Objects, checkouts and the refs database are excluded (rebuildable); rows, manifests, pointers, pins and the person's data are backed up. Backup size per app is the data plus under 1 MB. A restore lands in the offloaded state (section 2.7).
7. **OS purge of caches.** Nothing this design needs lives in `Caches` or `tmp`; only the catalog cache and icons do (M2). iOS does not purge Application Support. A test deletes `Caches` entirely and expects no change in Features or launch.
8. **Interrupted update.** Objects written, manifest not renamed: orphans swept, the package downloads again (nonce not yet recorded, so not a replay). Manifest renamed, refs not committed: `gc/dirty` rebuilds. Pointer swap journaled (section 2.4). Kill between stage and activate (R7.4 force-quit case): the pending version stays "Downloaded, not switched on yet".
9. **A feature removal that must survive app updates.** A removal done on the Mac is a new revision ("Removed: <title>") and every later update is built on it, so it survives by construction. A phone-side Remove (newest) is a Go back; the next catalog update is built on the newest published version, so Update first fast-forwards to the newest stored version and says so ("Updating puts back the changes you went back from"). If the person wants the removal to stick across updates, that is the Mac path, and the sheet in section 1.2 says so.
10. **Clock skew.** Order in the Features list and in GC comes from the ledger append order and manifest `createdAt` (package time), never from the phone clock; dates are display only (same rule as `FeatureVersionProjection`).
13. **Fewer versions than K, or K below protected roles.** Keep all available versions when there are fewer than K. If K is below current, fallback, pinned, pending, or local-only roles, retain those roles even when the count is exceeded. Pinning at K=2 is allowed up to the existing two-pin limit and adds the pin outside K. The fallback needed by Go back and Undo is never freed.
14. **Lowering and raising K.** Lowering K prunes immediately after its confirmation; raising K only changes future retention and never reconstructs a freed version. A freed version returns only after Download succeeds and the catalog still offers it.
15. **Migration and recovery.** Do not prune while a migration journal or swap journal is unsettled. Existing installs keep their current kept tier during installation and migration. After migration completes and the first launch has opened the app, the next ordinary prune applies K; before that prune, show: "Older versions will be cleared the next time Iris tidies storage."
16. **Website history.** The catalog may offer only the newest package and one prior package. Eligibility is checked against the current catalog, not inferred from revision order. A package no longer offered by the catalog stays on the phone even if that makes actual retention exceed K or the cap.
11. **Damaged object.** Found at launch or at checkout build: fall back to the backup version, mark the object missing, offer Download for the affected versions; never delete other versions' files because one is bad.
12. **Same package staged twice, or two stages racing.** Object writes are rename-over-identical; manifests are idempotent; the nonce is recorded once (second stage returns `alreadyStaged` as today).

---

## 5. Test plan (MiroFish style, like `tools/iris-mobile-user-sim` and `feature-version-tests`)

Personas: P1 non-technical (taps the first thing that looks right, reads only the first sentence), P2 hurried power user (double taps, backgrounds the app mid-operation, pins three versions), P3 edge user (disk at 95 percent, force quits between steps, restores from backup, clock set back a year). Every scenario runs at 3 seeds x 12 runs; failures land in a taxonomy (`no-progress-shown`, `data-touched`, `bytes-over-promised`, `version-lost`, `wrong-undo-target`, `manifest-half-written`, `orphan-object`, `refs-drift`, `checkout-not-cloned`, `backup-included`, `app-per-version`).

World (`DeviceWorld` extended, fakes only the OS boundary): free storage that shrinks mid-write, network offline or flaky, `clonefile` refused (copy volume), a crash at any named point (after object write, after manifest rename, after journal write, after checkout build, after pointer write, mid-GC, mid-migration), a "restore from backup" that deletes `objects/`, `checkouts/` and `gc/`, an OS purge that deletes `Caches`, clock skew, and iOS 17 versus 18.4 (existing).

Independent oracles (never the store's own numbers):
- The test's own copy of each package fixture: the current checkout's tree hash equals the fixture's tree hash after every operation; every version listed "on this iPhone" can be rebuilt byte for byte from `objects/` using the test's own file table.
- A Python script (`tests/oracle_store.py`, no Swift) that walks `objects/`, `manifests/` and `refs.sqlite` and recomputes reference counts and expected physical bytes; `refs-drift` when they disagree.
- `st_blocks` of `objects/` before and after Free up space: at least the promised number, never a file a kept version needs.
- `reader-data` tree hash and the WK identity UUID: unchanged by every operation except "Also delete my data".
- The Features page as the view renders it (state words, order, which buttons exist) equals the test's scripted history, and My apps has exactly one row per app after 50 versions (`app-per-version` kills any per-version listing).
- `NSURLIsExcludedFromBackupKey` read back from the resource values of `objects/`, `checkouts/`, `gc/` (true) and `state/`, `reader-data/` (false).

Seeded runs at scale (`revision-storage-benchmark`, new modes): synthetic stores at 3, 100 and 1,000 apps x 1, 10 and 50 versions generated from the measured distribution (mean 345 KB per file with the measured long tail, 30 percent of files replaced per version), reporting bytes on disk against the section 3 table (within 10 percent), library refresh, Features open, Go back, GC time and peak RSS, in release mode, on the Mac proxy; the device numbers are the main session's.

Mutation checks (break, confirm the named scenario fails, restore exact bytes, `sharedTreeUntouched`): drop the refs decrement (Free up space frees nothing: `bytes-over-promised`); delete a referenced object in sweep (`version-lost`); skip the journal (crash after pointer write leaves no fallback: `manifest-half-written`); count cloned checkouts in measurement (`bytes-over-promised`); forget backup exclusion (`backup-included`); order GC by phone clock (clock-skew run frees the current-minus-one first: `version-lost`); Undo re-activates the wrong side of the offer (`wrong-undo-target`); Remove enabled on an older row without the sheet (UI); Show all missing (UI); pin over the limit accepted; Remove app deletes data with the toggle off (`data-touched`); migration copies instead of renames (time budget); accept a `changes` title with control characters (validator).

### 5.1 Keep-count acceptance lines

Each line is a machine-decidable acceptance check for an independent test author. The test generates distinct package hashes and an independent expected revision order. For allocated-byte claims it walks the fixture store and uses `st_blocks * 512`, de-duplicating hardlinks by device and inode; it does not use logical file size or product-reported totals as the oracle. Public API checks use the `NativeRevisionStore` and `NativeShellLibraryCoordinator` surfaces listed in round 6 `PUBLIC_CONTRACT.md` section 1.2. The setting control is read through its accessibility identifiers and visible text.

1. **Default and selection:** with empty preferences, Storage shows **Versions kept per app**, selects **2 (Default)**, and the UI selection oracle reports K=2.
2. **Choice list and accessibility:** the visible options are exactly **2 (Default)**, **3**, **5**, and **Keep all while there is room**, with the identifiers and accessible label in section 1.6; at accessibility Dynamic Type each choice remains visible and operable.
3. **Global scope:** choose 3 for app A, then inspect app B; the settings/UI oracle and retained manifests show both use K=3.
4. **Persistence:** choose 5, terminate and relaunch the shell, and read K=5 from the public coordinator/settings result and selected accessibility value.
5. **Reset:** from K=5 activate **Reset to 2 (Default)**; selected value is 2 and the setting survives a second relaunch.
6. **Exact count:** stage eight distinct downloadable revisions with no extra roles and K=2; after public `pruneStorage()`, generated hashes show current, fallback, and no older downloadable revision retained solely by count. The Features ledger still has all eight rows.
7. **K=3 and K=5:** repeat the eight-hash fixture at K=3 and K=5; public revision summaries and independent manifest/object walk show respectively current plus fallback plus one and three newest eligible older versions.
8. **Fewer versions than K:** with three staged revisions and K=5, all three hashes remain after prune.
9. **Role precedence:** with K=1, independently generated hashes show current, fallback, pending, two pinned versions, and a local-only revision survive; result may exceed K and each protected role is present in `retainedSet` or its documented projection.
10. **Pin at default:** at K=2, pin a third historical downloadable revision within the two-pin allowance; `pinnedRevisionIds()` contains it after prune and its object hash remains readable.
11. **Never-free guard:** mark one old revision unavailable in the catalog and one as local-only; lower K and invoke prune. Both fixture hashes remain readable and their rows say **Kept on this iPhone (not available to download)** or **Pinned: kept until you unpin it** as applicable.
12. **Immediate lower:** at K=5 with eight eligible revisions, lower to 2 and confirm. Before confirmation, the exact sentence is **Keep 2 versions per app? Iris will free <amount> of allocated storage now. This is the space the files give back to your iPhone.** Buttons read **Keep 2 versions** and **Not now**. The preference becomes 2 and prune completes before the setting sheet closes. The exact result sentence is **Kept 2 versions per app. Iris freed <amount> of allocated storage.** The displayed reclaimed byte count equals the independent reduction in allocated object bytes from `st_blocks`, including shared-object last-reference behavior.
13. **Cancel lower:** repeat, choose **Not now**; K remains 5, object hashes and `st_blocks` are unchanged.
14. **Lower-count mutation:** lower K while no update follows. The test fails if any version over the new count remains solely because pruning waits for the next update.
15. **Raise does not restore:** after K=2 has freed an older fixture hash, raise K=5. The old hash remains absent, the row says **Not on this iPhone**, and Download is offered only when the catalog fixture still contains that package.
16. **Cap combination:** create a fixture where K=5 permits more history than the cap. After cap prune, the independent object allocation is at or below cap when eligible bytes suffice; the retained set is no larger than the stricter policy permits, and protected/unavailable hashes survive.
17. **Undo and Go back:** after count pruning, Go back and Undo restore the exact fixture hashes for the current and fallback versions; the fallback hash is present throughout.
18. **Unsettled journal:** inject a crash at every public recovery boundary with an unsettled journal; before recovery settles, `st_blocks`, manifest hashes, and the retained set show no pruning. After recovery, one normal prune satisfies K.
19. **Migration:** install the new shell over an eight-revision legacy fixture at K=2. During install and migration, every pre-migration hash remains. The first launch displays the migration sentence; the next ordinary prune applies K and `st_blocks` records the actual allocated reduction.
20. **Website limit:** catalog fixture offers only latest and one prior. After prune, any older hash absent from that catalog remains allocated and its Features row stays on this iPhone.

Mutation checks: kill a count-off-by-one mutant with checks 6 to 8; kill a mutant that frees a pinned or local-only version with checks 9 to 11; kill a mutant that frees fallback and breaks Go back with check 17; kill a mutant that defers a lowered K until the next update with check 14; kill a mutant that revives freed bytes when K is raised with check 15; kill a mutant that prunes through an unsettled journal with check 18.

UI tests (XCUITest, `IrisMobileShellUITests/FeaturesUITests.swift`, fixture `--iris-ui-test-fixtures features` seeded with 3 apps, one at 12 versions): every identifier in section 1.1 exists in the state where it is enabled and not otherwise; Remove opens the dialog; tap outside, Escape-equivalent (swipe down) and the default button leave the row unchanged; "Remove this feature" shows progress then "Removed" within 200 ms of each phase; Undo returns the row to "On this iPhone now"; Go back on an older row and Undo; the pin toggle flips its label and a third pin shows the limit sentence; Show all reveals the 9th row and Show fewer hides it; Free up space changes the space label by at least the promised number; Download on a freed row shows "Downloading" then "Go back"; Remove on an older row shows the Mac sheet and nothing else changes; Remove app with the data toggle off keeps "Your data" bytes on the Storage screen; the low-storage fixture disables Download and Update with the sentence; VoiceOver labels equal the row label rule; rotation and accessibility Dynamic Type keep every button on screen.

---

## 6. Units to build (after round 2's mobile integration unlocks `mobile-shell/**`; Sonnet builds by default, one Sonnet retry, then Opus, then Fable)

| Unit | Owns (disjoint) | Builds | Gate |
|---|---|---|---|
| MV1 object-store-core | new `Sources/IrisMobileShellCore/Versions/` (NativeObjectStore.swift, NativeVersionManifests.swift, NativeVersionRefs.swift (SQLite), NativeVersionJournal.swift, NativeFeatureLedger.swift, NativeStoreMigration.swift), `Tests/IrisMobileShellCoreTests/Versions*` | sections 2.1 to 2.5 and 2.7 as a self-contained module with the crash-point world and the Python oracle | `swift test --filter Versions`, oracle script, mutations 1 to 7 |
| MV2 revision-store-adapter and keep-count policy | `NativeRevisionStore.swift`, `NativeStorageBlockMeasurement.swift`, `NativeStorageRetentionPolicy.swift`, `NativeShellLibraryCoordinator.swift`, `NativeRevisionHistory.swift`; existing tests `NativeRevisionStorePruningTests.swift`, `NativeStarterInstallerResumeTests.swift`, `NativeStorageRetentionPolicyTests.swift` | public API on top of MV1; K-based retention, cap composition, catalog-download eligibility, count preference access, measured pruning, migration wiring; revise old kept-until-cap assertions to assert K and section 8 protections | focused prune/resume/retention suites, whole `swift test`, `mobile-ios-typecheck.sh` both flags, benchmark `multi-app`; section 5.1 acceptance 6 to 20 |
| MV3 feature-title-contract | `mobile-shell/contracts/**`, `mobile-shell/publisher/**`, `DeliveryPackageV1Validator.swift`, `DeliveryModels.swift`, `SecurityPrimitives.swift` | `changes` (section 2.6) end to end, publisher flag, validator, identity | `node --test` in contracts and publisher, `swift test --filter Delivery` |
| MV4 features-page and Storage setting | new `Sources/IrisMobileShellHost/Versions/` (FeaturesView.swift, FeaturesInteraction.swift reducer, FeaturesRows.swift), `NativeAccessibilityIdentifiers.swift`, `NativeStorageAppUsageView.swift`, `Store/StoreStorageView.swift` | section 1 end to end against MV2 API; Storage keep-count control, copy, confirmation, cancel, result, reset and accessibility identifiers | reducer and Storage UI tests on the persona world, `mobile-ios-typecheck.sh -D DEBUG`; section 5.1 acceptance 1 to 5 and 12 to 15 |
| MV5 persona-sim-and-scale | `tools/iris-mobile-user-sim/**` (new scenarios, world extensions), `tools/revision-storage-benchmark/**`, `round3/mobile-versions/tests/**` (oracle_store.py, mutants) | section 5's scenarios, seeded runs, mutation runner, the scale table check | RESULT.json with taxonomy, `MUTATIONS killed=N/N` |
| MV6 ui-tests | `IrisMobileShellUITests/FeaturesUITests.swift`, `NativeUITestFixtures.swift` (features and Storage keep-count fixtures) | section 5's XCUITest list plus keep-count choices, exact confirmation/result copy, cancel, persistence, reset, and accessibility sizing | `tests/uitests-typecheck.sh`; section 5.1 acceptance 1 to 5 and 12 to 15; the run is the main session's in Xcode |
| Integrator (one) | `NativeShellAppView.swift` (replace the "Versions and details" disclosure with the Features push), `IrisMobileShellApp.swift` (migration on launch, backup exclusion), `project.pbxproj`, `Package.swift` | applies each unit's INTEGRATION_HOOKS.md | full gates, then the main session builds to the phone |

Order: MV1 and MV3 first (no dependency between them), MV2 after MV1, MV4 and MV5 after MV2's API lands (they can start on the API in this spec with stubs), MV6 after MV4. The existing retention tests that encode "kept until the cap" and carry `PRE-2026-10-01-DECISION: revisit with the keep-count setting` must change: `NativeRevisionStorePruningTests.testMonthsOfUpdatesAcross20AppsStayWithinTheBoundAndEveryKeptRevisionOpens`, `NativeRevisionStorePruningTests.testPinnedOldRevisionSurvivesManyLaterUpdatesAndRevertToPreviousKeepsWorkingAfterPruning`, and `NativeStarterInstallerResumeTests.testThreePackageChainResumesPastAnAlreadyActivatedMiddlePackage`. Preserve their crash-safety, pin-protection, distinct-ID, and resume assertions while changing only the retention expectation to K and protected-role rules. The tests are locked to their separate author; this specification does not edit them. Phase 2 (cold-object compression with Apple's Compression framework, LZFSE) and phase 3 (deltas against the previous revision's object) are separate later units; their estimates in section 3 are marked as such and need their own measurement before any promise.

Separate facts rule for every handoff: source-level suite passes, native runs, installed state on the owner's phone and real journeys are reported apart; no unit calls a Mac-proxy pass "accepted".

---

## 7. Owner decisions

### 7.1 Open questions for the owner

1. **Should K offer only the four recommended choices, or arbitrary counts?** Recommendation: keep 2, 3, 5, and Keep all while there is room. If the owner wants any whole number, the Storage control needs input validation, bounds, and more accessibility/help copy; retention safety stays the same.
2. **Should keep count remain global, or become per app now?** Recommendation: global for this release, per-app later. If changed now, every app row needs its own control and the UI, preference migration, and acceptance matrix change; section 8 protections remain unchanged.
3. **Should 30-day offloading be enabled?** Recommendation: keep it off until explicitly approved, following section 8 item 4. If approved, it still cannot free a package the catalog no longer offers, and needs a separate consent/control and acceptance scope.
4. **Should the existing 2 GB code cap default remain 2 GB?** Recommendation: keep the current 2 GB default until the separate cap decision is answered. If changed, only the cap threshold and over-cap copy change; K and its protected roles do not.

1. Code cap default 2 GB (choices 1, 2, 4 GB): still open from the store design (decision 2 there).
2. Offloading: on by default for apps not opened in 30 days, only when over the cap, never pinned versions, with "Tap to download" on the row. Recommended: on.
3. Older packages are downloadable only while the current catalog offers them. Section 8 item 3 records the owner decision that the website keeps the latest package and maybe one prior, not the last 10. Without an offer, a freed version reads "No longer available"; this phone does not free it.
4. Remove app keeps the person's data by default, with an "Also delete my data" toggle off by default. Recommended: yes.
5. Removing an older feature from the phone as one tap needs a phone-to-Mac request channel (the contract's `MobileShellEditRequestV1` exists for phone-originated edits; the transport does not). Recommended: not this round; the sheet in section 1.2 ships instead.
6. The "Keep the app as it is now" escape hatch in `paused(stuck)`: same decision as desktop A.5, recommended approved on both.
7. Contract v1.1 `changes` field (section 2.6) ships now, while the shell is TestFlight only, rather than after a public release.

## 8. Owner decisions (2026-09-28, about 09:20, from the owner in chat; these override section 7)
1. Remove app keeps the person's data by default, with an "Also delete my data" toggle off by default. DECIDED.
2. Contract v1.1 `changes` (feature titles in packages) ships now, while the shell is TestFlight only. DECIDED.
3. publikhq.com keeps only the most recent package per app, maybe one version prior. It will NOT keep the last 10. Consequence for the design: the phone must never free (offload or garbage collect) any version it could not download again. That means: never free a pinned version, never free the fallback, never free a locally built version (for example one with a feature removed, which exists only on this phone), and treat only a package that the current catalog offers, at most the latest and one prior, as re-downloadable. The keep count in section 1.6 counts current and fallback toward K, with pinned, pending, and local-only revisions on top. Count pruning and the cap may free only eligible downloadable versions; a version the catalog no longer offers remains protected even if actual retention exceeds K or the cap. A freed version that is not re-downloadable must not exist. If space pressure cannot be resolved without freeing a protected or unavailable version, ask the person instead of freeing it. DECIDED.
4. Offloading (freeing the code of apps not opened in 30 days when over the cap): the owner asked what it means; explanation sent, answer pending. Build it behind a switch and default it OFF until the owner answers. PENDING.

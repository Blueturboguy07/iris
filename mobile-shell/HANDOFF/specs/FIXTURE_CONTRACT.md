# MV6 keep-count UI fixture contract

This contract is the only fixture seam needed by `KeepCountUITests.swift`. Implement it in `Sources/IrisMobileShellHost/NativeUITestFixtures.swift`. The fixture must use the real `NativeShellLibraryCoordinator`, revision store and installer paths. Do not substitute fake coordinator responses, fake manifests, or stub packages.

## Launch arguments and state lifecycle

- Start each isolated scenario with `--iris-ui-test-fixtures storage-keep-count`.
- Optional one-time preference seed: `--iris-ui-test-keep-count 2`, `3`, or `5`. Accept only these declared finite choices. If omitted, create an empty preference suite so normal default behavior is 2. Seed only when constructing a fresh fixture session.
- `--iris-ui-test-session <token>` names the isolated app data root and injected `UserDefaults` suite. The coordinator must receive that same suite for all keep-count reads, writes and lifecycle pruning. The saved choice uses the public key `iris.storage.versionsKeptPerApp` in that suite.
- On relaunch, retain `--iris-ui-test-fixtures storage-keep-count` and the same session token, omit the seed pair, and add `--iris-ui-test-preserve-state`. That mode must reuse the fixture's store, catalog, preference suite and sentinel without reseeding or clearing them. A normal fixture launch with a new session token must start clean.
- The XCTest Dynamic Type override `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL` must pass through unchanged.

## Seeded apps and revisions

Use the three existing app identities and display names below. Generate a distinct valid package for each revision with deterministic, nonidentical content, 1 to 4 KiB per package. Install and stage them through the coordinator and revision store so current/fallback pointers, ledger rows, package validation, and pruning are real.

| Identity | Display name | Fixture revisions | Catalog and role facts |
|---|---|---:|---|
| `publik.kneecap` / `storage-keep-count-fixture` | Kneecap | 8 | All eight distinct revisions are downloadable in the fixture catalog. The newest is current, the immediately older one is fallback, and the other six are ordinary eligible history. No pending or pinned revisions. |
| `publik.nut-ai` / `storage-keep-count-fixture` | Nut AI | 3 | All three distinct revisions are downloadable. Newest is current, previous is fallback, oldest is ordinary eligible history. No pending or pinned revisions. |
| `publik.freeharmony` / `storage-keep-count-fixture` | FreeHarmony | 1 | One valid locally built revision is current and absent from the catalog, so it is local-only and protected. |

Expose stable app row identifiers already defined by the app IDs. Features keeps a ledger row for every seeded revision. In Kneecap, order the eight rows oldest to newest with stable fixture revision identifiers so the row freed by lowering can be rediscovered after raising. Do not include unrelated starter apps or network-dependent catalog content.

The fixture's allocated-byte claim is not an oracle for XCUITest. UI assertions compare the amount in the confirmation with the same amount in the result. The independent Core test owns byte accounting. For this fixture, the eligible excess versions make the planned and completed freed allocation greater than zero, as allowed by SPEC 5.1 line 12; the UI test does not assert a numeric size.

## User-data sentinel

Create the sentinel at `reader-data/publik.kneecap/storage-keep-count-fixture/keep-count-sentinel.txt` with fixed contents `keep-count-user-data-survives`. It represents user data, not package code. Keep it unchanged across selection, pruning, reset, raising and fixture-preserving relaunch. Do not recreate it during `--iris-ui-test-preserve-state`, so a destructive reset or accidental rewrite is observable to the independent fixture check.

## Observable behaviors required by the UI suite

- Storage exposes the keep-count control and its four options using the identifiers and exact copy in SPEC 1.6. The control's accessibility label is `Versions kept per app`; its selected value reports the declared choice.
- Lowering from 5 to 2 asks for confirmation and completes pruning before showing the result and publishing selected value 2. `Not now` cancels without changing the saved value or presenting a result.
- At K=3, the three Nut AI ledger rows remain represented and the global setting continues to read 3 after visiting Features and returning to Storage.
- After Kneecap is pruned from 5 to 2, at least one freed downloadable row remains in the ledger as `Not on this iPhone`. Raising to 5 displays the exact SPEC 1.7 warning and never recreates the row's package files. Since the fixture catalog still offers the package, its Download action may be present.
- Reset from 5 uses the same lower-count confirmation and completed result path as choosing 2, then persists 2 through the fixture-preserving relaunch.

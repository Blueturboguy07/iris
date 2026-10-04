# long-media: MiroFish pack for unbounded video import

Round 3, unit M-longimport, 2026-09-28. A "pack" per this round's own
convention (`tools/iris-mobile-user-sim/packs/<name>`): a self-contained
addition next to the main `iris-mobile-user-sim` harness, owned by one unit,
rather than a change to that harness's own shared `Sources/MobileUserSimKit/Scenarios/`
directory (not owned by this unit).

## What this drives

The real, unmodified `NativeMediaImportPolicy` from `IrisMobileShellCore`
(the package one level up, `mobile-shell/native`), against a fake device
boundary: free storage over time, another app's concurrent writes, a slow
iCloud download with pauses, a provider that deletes its own temp file
early. See `Sources/LongMediaImportPack/MediaWorld.swift`'s own doc comment
for exactly which real Core functions are called and how.

This pack does **not** depend on `IrisMobileShellHost`: real move-vs-copy,
the real crash-reaper/launch sweep, and a byte-for-byte hash-match oracle
all need real file I/O and PhotosUI/UIKit types this macOS-hosted pack
cannot exercise. Those are covered by real XCTest instead, in
`IrisMobileShellApp/Tests/NativeMediaImportMoveAndCleanupTests.swift`.

## Personas and scenarios

3 personas (`MediaImportBuiltInPersonas`: non-technical, hurried power user,
edge user with a nearly full phone) and 7 scenarios
(`Sources/LongMediaImportPack/LongClipScenarios.swift`): local files from
45 s up to 60 min and 20 GB, a slow-but-healthy iCloud download, a provider
that deletes its temp file early, a nearly full phone, disk filling from
another app mid-import, a mid-batch cancel, and several clips combined up to
an hour.

## Running it

```
cd packs/long-media
swift test                                  # the sweep, under the normal gate
swift run long-media-pack --runs 100 --seeds 20260928,1,2,777
```

The executable writes a Markdown report (failure taxonomy included) to
`./long-media-pack-report.md` by default (`--out <path>` to change it), and
exits non-zero if any run failed.

## Reusing `MobileUserSimKit`

Only its genuinely generic pieces: `SeededGenerator`, `FailureClass`,
`ScenarioOutcome`, `PersonaInterview`. Not `RunEnvironment`/`MobileScenario`/
`MobilePersona`, which carry install/store-flow-specific fields this pack
does not need (and would misrepresent if reused for media import: e.g.
`MobilePersona.startingNetwork` includes `.catalogEmpty`/`.catalogStale`,
concepts specific to the store catalog, not a media pick).

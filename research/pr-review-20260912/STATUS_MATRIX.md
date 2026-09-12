# Review status matrix

The status column describes the strongest evidence available for the reviewed
9fb baseline and bounded installer correction. A source or fixture result never
upgrades a row to installed behavior by itself.

| Area | Evidence class | Status | Review meaning |
| --- | --- | --- | --- |
| Swift/native source build | Component | Passed | Fresh host compilation completed without errors. Warnings remain. This is not feature acceptance. |
| Standalone usability package on the public snapshot | Component | Build failed | A newly shared receipt helper calls `scrubbedVerificationOutputTail`, but the isolated package does not include its production definition. The native app/module builds; this package wiring needs a separate fix. Do not report the old usability count as a fresh pass. |
| Harness and defensive checks | Component | Passed for the recorded suites | Confinement, identity, review-boundary, input-budget, image, retention, and receipt checks passed in controlled hosts. This is not an exhaustive security audit. |
| Restart-safe Undo primitives | Controlled native fixture | Passed for named cases | Durable receipt, payload identity, source identity, interrupted-swap, dirty-source, and changed-backup cases were exercised in disposable Test fixtures. A forced crash through the real UI was not exercised. |
| Installer/artifact discovery correction | Controlled package and swap | Passed for tested layouts | `release/mac*` discovery, executable/bundle checks, stale-artifact refusal, and disposable replacement worked. Custom output layouts remain unproven. |
| NitroAI folder-scoped search | Installed native UI | Passed, narrow | Trial 17 exercised matching, folder isolation, empty results, clear, relaunch, Iris restart, and Saved app versions Undo. It is one small feature. |
| PlantGPT project search | Installed native UI | Passed, narrow and historical | Trial 11 exercised a small update, relaunch, restart Undo, and preserved project data. It does not establish complex feature generation. |
| Current 9fb UI smoke | Installed Test UI | Partial | Composer, registered app selection, saved-version records, and picker/general-chat boundaries were observed. Keychain-blocked chat and live complex behavior remain open. |
| Transfer intake and clarification | Installed Test UI | Observed | The notes/folders scope and preservation choices reached a readable plan in later trials. This proves intake only. |
| Transfer code admission | Independent review | Rejected in trials 18-21 | Review found lost provenance, order-sensitive matching, ambiguous retained-copy duplication, and missing consumer context. No candidate cleared admission. |
| Transfer native oracle | Controlled native route | Negative readiness only | Seven baseline checks ran: six passed and the expected transfer export control was absent. No positive transfer path ran. |
| Transfer package/install/relaunch | Installed feature | Not run | No transfer candidate was installed after review. |
| Transfer restart Undo | Installed feature | Not run | There is no complex-transfer receipt or post-transfer Undo to verify. |
| Repair-input reserve | Deterministic and live scheduling evidence | Passed as a harness mechanism | Old/new replay showed the new reserve refuses before transport when needed, then admits a charged repair and both mandatory native review bounds within the unchanged limits. Trial 21 used repair calls, but review still rejected the feature. |
| Existing app data on rejected transfer | Installed Test UI | Preserved | Failed transfer trials left the prior app and baseline notes visible. This is safe non-delivery, not successful import. |
| Normal Iris and normal profiles | Safety boundary | Preserved | The reviewed campaign stayed in Iris Test and registered disposable targets. No normal-app replacement or normal-profile migration is claimed. |
| Kneecap installation | Operational WIP | Unresolved | A dirty-source/clean-copy refusal was observed. Retry/resume is being fixed. No phone or signed-release acceptance exists. |

## Evidence vocabulary

- **Installed native UI** means actual controls in the isolated Iris Test app
  were used and the result was observed.
- **Controlled native fixture** means a linked host or disposable app/profile
  exercised a specific state boundary. It is stronger than a pure unit test,
  but it is not a user feature journey.
- **Component** means source, package, or deterministic checks without the
  requested installed behavior.
- **WIP** means the route is not complete enough to support an acceptance claim.

## Merge gate

The matrix remains red because the requested complex transfer has no native
success, no installed candidate, no restart persistence result, and no
restart-selected Undo result. A green source build, green defensive suite,
or a successful installer swap cannot clear those missing rows.

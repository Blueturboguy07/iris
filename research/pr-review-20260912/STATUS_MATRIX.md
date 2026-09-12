# Current review status matrix

As of September 12, 01:45 Pacific, through the follow-up source/build work on
the review branch. The latest installed Test hash remains
`5e2a0d454367171b48c8f65915447d6694a29551be578c2ea1b06c1e1978fcb2`,
independently rechecked; the new cleanup UI was exercised from a fresh Xcode
Test product but was not copied over the installed app. Earlier rows retain
their own run boundaries. Full details are in [INTEGRATED_CANDIDATE.md](INTEGRATED_CANDIDATE.md).

| Area | Evidence class | Current status and limit |
| --- | --- | --- |
| Upstream integration | Git and build | Conflicts resolved; PR is OPEN, DRAFT and MERGEABLE against `945d135`. No merge into main or release. |
| Iris Test build | Build/installed artifact | Existing installed Test build remains launched and unchanged in this follow-up; the fresh source build also completed with warnings and was inspected separately. Normal Iris unchanged. |
| Standalone usability wiring | Component | Initial snapshot failure fixed in `dc0dd62`; subsequent report records 134 tests/17 suites passing. |
| Harness and defensive checks | Component | Recorded suites pass, including later harness 112/5. They do not establish successful live model behavior or exhaustive security coverage. |
| Installer retry and shell ownership | Controlled controller/PTY plus native controls | Targeted regressions and real PTY tests pass. Native retry-window controls showed Working and Stop; full marketplace install remains unverified. |
| Kneecap source state | Read-only actual repository facts | Expected home copy exists with correct origin and pinned HEAD; lockfile and Finder metadata changes trigger refusal. Preserve changes. This is not installation or phone acceptance. |
| Ask/Edit and draft transitions | Actual Iris Test UI | Draft separation, target-change confirmation/Cancel and history-clear Cancel observed on the identified installed integration runs. |
| Current settings and saved-version display | Actual Iris Test UI | Settings and retained restored records observed after Test replacement. Displayed availability is not a new Undo execution. |
| Saved-login and permission continuity | Actual startup failure | Keychain read failure remains. Instructions and matching signatures do not prove it resolved. |
| Earlier NitroAI search | Historical actual UI | Narrow search, relaunch, restart and Undo passed. Search was deliberately undone; no current transfer feature is installed. |
| Earlier PlantGPT search/lifecycle | Historical actual UI | Narrow update/relaunch/restart Undo preserved project data. Not complex feature proof. |
| New disposable QA app lifecycle | Actual UI plus later failure | Dashboard reached, but subsequent relaunch failed with missing helper/invalid app metadata. Shared launchability checks were hardened; fresh successful full lifecycle remains unproven. |
| Recovery primitives | Controlled disposable fixtures | Named receipt, identity, interrupted-swap, dirty-source and changed-backup cases passed. Forced UI crash and recovery after a new accepted complex change were not observed. |
| Backup cleanup | Test-only UI plus controlled fixtures | One selected registered Test project can show a conservative preview and require explicit confirmation. Recent/newest/protected/unreadable copies are retained; no automatic installation/delivery/Undo caller exists and no valuable backup was removed. Successive deliveries are not generally bounded. |
| Review-context selection | Component | Bounded possible-consumer selection tested under unchanged context limits. No measured live feature-success or dollar-cost improvement. |
| Transfer intake | Actual Test UI | Scope, choices and readable plan observed. Intake only. |
| Transfer correctness | Independent review rejection | Trials 18–21 rejected provenance/order/repeated-copy defects. No accepted transfer, install or post-transfer Undo. |
| Transfer oracle | Controlled negative readiness | Baseline tests reached the absent export control; no positive transfer path completed. |
| Spatial and concurrent workflows | WIP | Accurate visible highlights and overlapping install/edit behavior remain unaccepted. |
| Normal Iris/user data | Scope boundary | No normal-app upgrade, discarded user edits or valuable backup cleanup in the recorded work. |

## How to interpret this matrix

**Actual UI** means real controls were operated through computer use; **controlled fixture/component** evidence locates and prevents particular failures. Neither implies an unperformed user journey. The source commit, installed binary and individual test run are separate identities.

The branch is mechanically mergeable but remains a draft for product review. Select changes using their stated evidence and limitations. No successful complex transfer, general automatic retention, physical phone install, new complete Undo cycle or comprehensive permission-continuity result is claimed. Historical first-snapshot failures remain available at immutable `e79b401`; this matrix supersedes their presentation as current failures.

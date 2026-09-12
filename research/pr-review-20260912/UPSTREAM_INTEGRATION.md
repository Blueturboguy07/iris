# Upstream integration boundary

The review snapshot starts from Iris 0.9.9 (`84dd908`), preserving the source
lineage of the tested experimental app. Fresh fetch found upstream at `945d135`.
It includes twelve later commits affecting 31 files, including overlaps with
the lab's guide, shell, catalog and chat changes. A draft may have merge
conflicts. It is not safe to replace upstream files wholesale with this snapshot.

## Relevant existing upstream work

| Commit | Existing correction | Relationship to the current finding |
| --- | --- | --- |
| `8ace12b` | Rebuild a dead PTY, ignore idle EOF, surface terminal failure and clear stopped autopilot | Relevant to frozen terminal recovery. Does not acquire synchronous ownership for repeated Try again requests. Reuse during integration. |
| `b377a77` | Tear down an old guide's automation when another guide opens | Relevant to mixed guide/session state. Preserve it when integrating retry cancellation. |
| `34a3ebd` | Bind primary actions to the rendered step; credential completion requires a changed Keychain write | Relevant to stale clicks and false completion. Distinct from retry single-flight ownership. |
| `60a575a` | Clear Back latch when the reader asks Iris to run a step | Preserve deliberate navigation semantics alongside cancellation. |
| `a0ce673`, `05c1486` | Park watched long-running steps, stream their output and avoid implying completion | Relevant to terminal visibility and honest progress. Preserve while retaining compact lab UI. |
| `1914155`, `6fcd23f` | Surface guide cards, size cold-launch panels, finish cards and report rejected links | Relevant to missing or stale guide surfaces. |
| `945d135` | Discover install-guide actions and a chat guide-opening tool | Keep explicit execution consent and the Test installation boundary. |
| `3c78434` | Guide link allowlist updates | Retain validated destinations. |
| `141be0f` | Stale LaunchServices registration cleanup | Deployment integration requires separate identity checks; no normal-app cleanup in this review. |
| `4ea955e` | Regression-test compile repair | Preserve the upstream test correction. |

## Promotion rule

Keep the tested snapshot ref immutable. Integrate upstream in a separate
reviewable branch/commit, resolve behavior rather than choosing one whole file,
and rerun guide retry/navigation, Ask/Edit, catalog, saved-version delivery and
Undo regressions. Build and interact with the separate Iris Test app before
calling the integrated candidate native-tested. No merge or release is authorized
by this draft.

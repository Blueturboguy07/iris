# Iris PR review package

Current status, September 12 at 09:40 UTC: **draft for review, with upstream conflicts resolved**. GitHub reports the branch mergeable against `945d135`. Mergeability is not release readiness; no PR merge or release has occurred.

This index reflects code through `9267ebf`. The latest installed Iris Test
debug-library SHA-256 is `2186fd84c07b38dcfdf8942f0b88d4bc4e61e0600a04637047346115cc81e304`.
Regular Iris remains unchanged. Later commits must identify their own source,
build and installed evidence rather than inherit every earlier result.

## What a reviewer can use now

- Installer fixes address overlapping retries, stale guide/terminal completions, stopped operations and bounded shell recovery. Controlled tests include real disposable PTY processes. A native terminal-controls fixture exercised retry progress and Stop; this is not a complete marketplace install.
- Actual Iris Test interaction covered Ask/Edit draft separation, project-change confirmation and Cancel, history-clear confirmation and Cancel, retained saved-version records and settings. The integrated report distinguishes the candidate and transition used for each observation.
- Earlier narrow NitroAI search and PlantGPT update/restart/Undo journeys preserved fixture data. Search was deliberately undone for recovery testing. The accepted PlantGPT `0db25ba…` source/artifact still exists, but the registered checkout is at base and its accepted-edit coordinator state is not replayable; these historical successes do not establish a new complex feature or a fresh full lifecycle pass on the latest build.
- The standalone usability-package wiring failure in the first snapshot was fixed. Follow-up evidence reports 134 tests in 17 suites passing; the later harness report records 112 tests in 5 suites. Counts describe those component runs, not successful user journeys.
- The new source-state explanation uses bounded read-only repository facts. The observed Kneecap copy exists, has the required revision, and has local changes. It must not be described as missing merely because the source-pin gate refused it.

## What remains work in progress

- No accepted complex notes/folders transfer. Candidates were rejected before installation, and the paid repeat campaign is stopped.
- Full Kneecap marketplace installation and physical phone deployment are unverified. Iris Test deliberately refuses marketplace autopilot. Existing user checkouts and local edits are protected.
- Backup cleanup now has an explicit Test-only, one-project preview and
  confirmation flow. The real UI removed one disposable obsolete backup while
  retaining recent/newest and existing rollback records, and restart preserved
  the truthful unavailable record. There is still no automatic lifecycle caller
  and successive successful deliveries remain retained; general automatic
  storage bounds are not solved.
- The managed replacement path has a default 2 GiB logical backup admission
  check, repeated before the swap. Over-budget updates can be refused before
  replacement. This is not automatic reclamation, an atomic concurrency-wide
  disk ceiling, or a cap on source/build caches. The default policy excludes
  destinations outside the managed backup root.
- A disposable NitroAI QA app reached its dashboard, then failed a later relaunch with a missing helper/invalid app metadata. Launchability checks were strengthened afterward. Do not count the failed relaunch as a successful lifecycle pass.
- Saved-login Keychain access still failed on this machine. Recovery instructions do not establish fixed credential or permission continuity. Precise spatial highlighting and concurrent installation/editing remain unaccepted.
- Build warnings remain. A matching signature, successful build or mergeable Git branch does not cover these missing behaviors.

## Read in this order

1. [STATUS_MATRIX.md](STATUS_MATRIX.md): current evidence levels and unresolved paths.
2. [INTEGRATED_CANDIDATE.md](INTEGRATED_CANDIDATE.md): changes, installed artifacts, actual computer-use observations and test findings. Its recorded suites belong to their named runs; do not combine them into a new unperformed acceptance run.
3. [REVIEWER_PRECAUTIONS.md](REVIEWER_PRECAUTIONS.md): isolation, data, permissions and recovery limits.
4. [KNEECAP_SETUP.md](KNEECAP_SETUP.md): the source-pin diagnosis and phone/build prerequisites.
5. [TEST_FINDINGS.md](TEST_FINDINGS.md): earlier accepted and rejected campaign outcomes.

The whole-system plan in [iris-test-whole-system-plan.md](../../docs/testing/iris-test-whole-system-plan.md) describes the broader intended lifecycle. Tonight's scope remains the user-approved installer, review handoff and efficiency work; a model comparison or another paid feature attempt is not required by that plan.

## Historical snapshot and safe review

The first public snapshot `e79b401` preserves the 174-source aggregate behind the earlier `9fb3...` Test artifact. Its [build lineage](BUILD_LINEAGE.md), [source manifest](SOURCE_MANIFEST.json) and initial failures remain historical. The manifest inventories that frozen snapshot, not every later commit. Upstream changes were subsequently integrated and checked; an old statement that conflicts were unresolved or package wiring still failed must not be read as current status.

Review source and checks inside the existing Test-only boundaries. Private runtime logs, credentials, profiles, compiled apps and valuable user copies are excluded. Do not overwrite normal Iris, weaken the source-pin gate, discard local changes, delete protected backups, merge the PR into main or publish a release from this review package. Preserve immutable tested refs and report new source/build/UI results separately.

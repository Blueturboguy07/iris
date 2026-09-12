# One real planner-to-editor check

This is a command-line host, not an installed Iris app. It compiles the real
`HarnessFeatureWorkflow`, `CodexMaintainProvider` and `MaintainTierCFixer`.
It deliberately does not construct the app coordinator, account service,
recovery stores, app inventory, packaging, installation or publishing routes.

Allowed tasks are staged `t5-js-filter-ops` and `t7-js-export-queue` fixtures.
The first is a small wiring check. The second exercises persistent queue,
cancellation, retry, restart and status-facade behavior with injected workers.
Neither proves spatial awareness, physical UI usability, installed-app
behavior, broad complex-feature reliability or superiority over another model.

## Boundaries

- The fixture must be a clean, symlink-free Git copy with no remote and HEAD
  matching the staging record. Never point the host at the canonical fixture.
- An explicit `IRIS_HARNESS_SCRATCH` names the existing `scratch` child of the
  staged run. Preflight and run both require it to be empty initially.
  macOS Foundation ignores TMPDIR in some launch contexts, so the
  headless build uses this path for profiles, Git backups and Codex scratch.
- Headless trace goes to stdout, not the installed Iris log.
- All engine commands, including build/tests, use the real no-network
  write-confined sandbox. Login scripts and global Git config are not loaded.
  Each command has its own process group, cleaned up on exit or timeout.
- The Codex process still needs its provider network connection. Its own
  read-only sandbox stays enabled, web search is disabled, and an additional
  read boundary denies the lab source/oracle tree. This is not a VM or proof
  against every malicious process on the same Mac.
- Astra Medium plans, Astra Low implements and reviews. Ten calls maximum,
  one million submitted input bytes maximum, ten-minute session deadline.
  Missing token usage is unknown, not zero. These are not a hard token cap.
  The experimental executor stops editing with one call remaining for review.
  It still runs the configured checks, never treats that boundary as DONE, and
  cannot retry a failed suite using the review reserve. Time/input limits may
  still prevent review; no reservation guarantees successful acceptance.
- Questions stop the run without an edit. `NEEDS ANSWERS` is incomplete, even
  though the host exits normally. No default answers are silently chosen.

## Build and stage

From the lab root, create a fresh `iris-harness-host-*` scratch directory with
`mktemp -d`, then pass its absolute path to:

```sh
node iris-macos/tools/harness-feature-host/build.mjs <build-directory>
python3 iris-macos/tools/edit-battery/bin/battery.py stage t5-js-filter-ops
```

Keep the returned `run_dir`, create its `scratch` child, and record the SHA-256
of `run.json` and the initial Git commit outside the model's writable paths.
Do not use `stage --into` with an existing directory: that old staging command
deletes its target.

Invoke the generated binary with `IRIS_HARNESS_SCRATCH` set to that scratch
child and `--preflight <run_dir>` first. This makes no model call. Only after
it passes, use `--run <run_dir>` with the same environment. Save stdout outside
the model's writable directories. The host writes `plan.json`, `usage.json`
and, if the editor ran, `engine-result.txt` and `prompt-projection.json` to the
outer run directory. The projection file counts original versus submitted
conversation UTF-8 bytes and compacted assistant turns across editing/review
requests. It excludes system prompts, provider framing and tokenization; do not
present this as total token or dollar savings.

`--checks` runs inert output-budget, behavior-review and executor-context checks without a model
call. It creates and removes one tiny private Git fixture to verify that new
files enter the review and that the real index remains unchanged. It does not
construct app services. The context replay validates its patch with the real
file-edit parser, then tests receipts and preserved user instructions;
its printed byte reduction is synthetic, not live model usage.
`HarnessReviewReserveChecks.swift` exercises the real executor with inert model
replies in two scenarios inside a private Git fixture: a final edit without DONE must reach review,
and a failed suite must stop without spending that review call or claiming
success. No network model or application services are used by these checks.
`RepairTestCheckpointChecks.swift` covers post-write confined diagnostic
feedback, cancellation, exhausted editing capacity and an absent declared suite.
`CommandFreshnessChecks.swift` runs identical commands before/after a real edit,
then confirms unchanged, byte-identical and rejected edits do not permit stale
repeats. A second real-loop fixture retains the lifetime investigation gate.
These are inert executor regressions, not successful model-generated features.
`RepairCandidateIdentityChecks.swift` separately checks exact Git content,
same-size binary changes with preserved timestamps, new files, branch identity,
unchanged real index and private-index cleanup. It uses a disposable headless
Git fixture and links the current native module.
`UnadmittedRepairChecks.swift` covers the native-admission repair boundary with
inert model replies. It must run only with an isolated Test-environment adapter:
`IRIS_UNADMITTED_FIXTURE_ROOT` must be a fresh `iris-unadmitted-env-*` child of `/Users/Shared`,
and the actual support, log and command-scratch roots must all be beneath it.
An existing registry is refused. Never run this probe against the installed
Iris Test profile. Headless skip output is not a passing native-path test.
`VerificationDiagnosticChecks.swift` checks early-error retention, noisy output,
secret redaction before selection and the unchanged 2,000-character cap through
the real receipt path. None of these probes establishes native app behavior.
For t7, stage `t7-js-export-queue` instead. The host selects only
the task request, documentation path and verification commands from the lab
manifest; oracle and reference metadata never enter the prompt. Usage output
also lists each settled call's phase and reported token families.
The host atomically checkpoints usage after each admission and settlement.
In-flight calls are counted separately and keep aggregate token fields unknown;
earlier settled per-call records remain available after an interrupted run.
Checkpoint write failures are printed, never silently presented as durable data.

## Independent grade

First verify `run.json` still has its captured digest. Inspect the actual
changed files, then grade the outer run directory, never the bare work path:

```sh
python3 iris-macos/tools/edit-battery/bin/battery.py grade t5-js-filter-ops <run_dir>
```

Require all of: oracle exit 0, integrity true, no out-of-scope files, the exact
target-behavior and regression counts declared for that fixture, and no
unclassified records. For t5 the counts are 10 and 6 respectively; for t7 they
are 15 and 4.
The engine saying `appliedAndRebuilt` is not the grade. No app package or
installed copy is produced by this host.

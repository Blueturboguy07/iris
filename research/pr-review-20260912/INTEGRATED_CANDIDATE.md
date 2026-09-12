# Integrated Iris Test candidate

This is a source candidate, not a release or a claim that every edge case works.
The ordinary Iris app and valuable user app copies are outside this test target.

## End-to-end plan

Improve one continuous experience: explain the requested outcome, ask only for
missing decisions, inspect the relevant source within the existing budget,
implement and verify the change, deliver a runnable test copy, and retain a
clear path back to the previous version. Installation and editing must retain
separate ownership even when their windows or asynchronous work overlap.

The current work adds no new model stage, service, or larger model-context cap.
Parallel workers have narrow file ownership; the root agent reviews their
interaction, builds one combined candidate, and operates the actual Iris Test
UI. A passing fixture or source check is recorded separately from native use.

The broader working contract for the whole lifecycle, including nontechnical
intake, model routing, real computer-use acceptance and defensive testing, is
in [`docs/testing/iris-test-whole-system-plan.md`](../../docs/testing/iris-test-whole-system-plan.md).

## Parallel swarm run

Three bounded Luna max-effort reviews ran against this same isolated checkout:

- harness-goal audit: retained the existing deterministic contract and recorded
  live-model, installed-app, and cost gaps instead of fabricating results;
- lifecycle review: added one shared launchability predicate across package,
  install/replace, restore, relaunch, and Test registry paths;
- defensive review: hardened run-log and memory egress against path escape,
  control characters, prompt injection, and credential-shaped values.

The root pass then integrated those commits, added the bounded unavailable-probe
clarification, rebuilt through Xcode, installed only **Iris Test**, and exercised
the actual controls. Agents did not run paid feature requests or touch regular
Iris data.

## Current integration scope

| Area | Change | Required proof |
| --- | --- | --- |
| Guide ownership | Old fetches, buttons, retries and stopped drive tasks cannot publish into a newer guide | Held asynchronous controller regressions and native navigation |
| Terminal recovery | Bounded replacement shells, stale callback rejection, explicit retry without replaying the interrupted command | Real disposable PTY tests, runner tests and native controls |
| Setup explanation | Fresh bounded origin, revision and changed-path facts explain a source-pin refusal without changing the checkout | Injected and read-only Git checks; unknown facts remain unknown |
| Review context | Include possible relative-import consumers from the existing bounded repository map | Context selection/cap checks; no claim of improved feature success without a new accepted feature |
| Saved app versions | Protect current, recent, ambiguous and overlapping backup identities; explicit Test-only cleanup of obsolete restored payloads | Disposable receipt-backed delivery/cleanup tests; no valuable backup deletion |
| Existing experience | Preserve Ask/Edit separation, drafts, catalog, clear-history confirmation, delivery and restart-safe Undo | Existing regression suites plus actual Iris Test interaction |

## Evidence and remaining limits

- Prior installed Test binary: `ec39b2ec604e957158b53e679be1f8430fc3bd72126f95de829d0c76e0bb8299`.
  It was retained as a recoverable local application backup when the integrated
  candidate below replaced only Iris Test.
- Backup cleanup is explicit and is not automatically called by installation,
  delivery or Undo. Iris Test Settings now exposes a one-project-at-a-time
  preview and confirmation flow; normal Iris does not expose it. Successive
  installed deliveries still retain their backups. This is not a general
  automatic storage-growth solution.
- Cleanup checks cannot make a separate recovery writer or external filesystem
  mutation atomic with receipt deletion. Mid-pass unlink failure has not been
  forced in a deterministic test. No valuable profile cleanup was attempted.
- Test intentionally refuses marketplace installations. A controller/PTY probe
  is not full Kneecap installation or physical phone acceptance.
- Earlier paid transfer trials produced no accepted complex feature. They are
  not repeated merely to inflate test counts. Costs and live outcomes must be
  attributed to an identified run, not inferred from static tests.

## Installed candidate and fresh checks, September 12 UTC

The fresh follow-up integration candidate is installed and launched as **Iris
Test**,
bundle identifier `com.publikhq.iris.test`. Its debug-library SHA-256 is
`2186fd84c07b38dcfdf8942f0b88d4bc4e61e0600a04637047346115cc81e304`, Mach-O
UUID `F09A3B7A-0F49-3332-AC8A-B49554FCA20D`. Xcode GUI build completed with
zero errors and the existing warning set; this is not a warning-free release.
The prior installed candidate is recoverable at
`/private/tmp/iris-test-before-cleanup-ui.20260912-014457`.

Regular Iris was not replaced. Its debug-library SHA-256 remains
`34f3cf4f202973486eeebc8d927925121e37aa719b723c50520719063b0e32c2`.
No target-app installation or valuable backup cleanup was performed in this
integration pass. The fresh Xcode Test product was copied to
`/Applications/Iris Test.app` only after the old Test bundle was moved to the
recoverable backup above. Normal Iris was not replaced.

Fresh checks:

- The final 175-source headless native module compiled. Source aggregate:
  `129b03b583a6c3ec7118a574e703512e940e594254301a0c4804a5d36661b2b6`.
- The upstream-merged 175-source headless native module compiled with 262
  warnings. Guide/controller/shell regressions: 68 tests in 5 suites passed,
  including actual disposable PTY processes and held asynchronous ownership
  cases. The merged build preserves the ownership and timeout fixes and adds the
  catalog-guide/recovery changes from upstream.
- Harness package: 112 tests in 5 suites passed. Usability package: 134 tests
  in 17 suites passed. Those suites were rerun during final integration; the
  subsequent timeout change touches only Runner and its focused guide tests.
- Full inert executor checks passed before the final timeout-only correction.
  The final module's defensive checks passed: candidate policy 7 groups,
  candidate boundary 2 groups and image-input boundary 2 groups. These are
  confined tests, not proof that all attacks are prevented.
- Standalone backup retention 7 groups, registry 6 groups, Test app delivery 3
  groups, and saved version lifecycle checks passed against the current
  combined module. The canonical shared-scratch correction in the delivery
  fixture removes a test-only `/private/tmp` alias failure; it does not loosen
  production path checks. Repository context and source-refusal checks remain
  recorded from the preceding combined module.

Actual computer use after installation, with screenshots inspected:

1. Opened the eye and chose NitroAI Iris Test through Settings.
2. Entered an explicitly unsent QA feature draft, switched to Ask, then back
   to Edit. Ask remained general; Edit restored the draft and feature mode.
3. Chose PlantGPT with that draft present. Iris explained the target change
   before moving it. Cancel retained the NitroAI target and draft.
4. Removed only the temporary QA text, then selected PlantGPT. Its title and
   input placeholder changed to the correct project.
5. Opened History, opened Clear history confirmation, and chose Cancel.
   The same saved conversations remained. No history was deleted.
6. Opened General settings. Start minimized remained selected. Expanded and
   scrolled Saved app versions: the NitroAI and PlantGPT restored records and
   previous-file availability remained visible after Iris Test replacement.
7. On the upstream-merged build, Settings also exposed the guide-name field,
   Mac app catalog rows and the explicit Ask-me-each-step / Run-installs-for-me
   controls. Iris Test still refuses marketplace installation, as intended for
   this isolated target.
8. On the exact fresh Xcode Test product, expanded Saved app versions showed
   the Test-app picker and the conservative “Review cleanup…” action. The
   confirmation explained that recent, newest, recovery-protected and
   unreadable copies are kept, and Cancel returned to the records without
   deleting anything.
9. A separate registered NitroAI Iris QA fixture was launched through
   computer use after its prior disposable swap. The real onboarding screen
   was completed to the app dashboard, where Dashboard, Settings, note-source
   actions, search and the empty-library state were visible. This is evidence
   of a real disposable app launch and UI reachability, not proof that a new
   feature was delivered by Iris.
10. After quitting that fixture, a direct relaunch attempt failed with the
   Electron fatal error `Unable to find helper app`; inspection showed the
   swapped disposable bundle had no valid `Contents/Info.plist`. This is a
   campaign failure, not a successful lifecycle result. The power-user host
   now reuses the production launchability predicate for package and swap
   admission, so a malformed artifact is refused before replacement.

This proves those installed control transitions and retained records. It does
not prove a new complex feature, a fresh full installer run, terminal-minimized
behavior during a concurrent install/edit, or a new update/relaunch/Undo cycle.
The rebuilt app still reported a machine-local Keychain read failure
(`status=-25293`) on startup; Settings now gives the plain-language
“Always Allow” recovery instruction, but this pass does not claim the
underlying macOS access issue is fixed for every machine. No paid feature
request was submitted during this integration acceptance pass.
The earlier recorded narrow native lifecycle successes remain separate.

## Findings that changed this pass

1. Retry failures were not one bug. Terminal startup, a previously stopped
   drive task, late guide responses and a long-running side process could each
   update state after a newer operation started. Each asynchronous owner now
   has a bounded identity check rather than adding another orchestration layer.
2. A source-pin refusal is not proof that a repository is missing or outdated.
   The current Kneecap checkout matches its guide pin but has local changes.
   Fresh read-only origin, revision and status facts make that distinction
   explicit. No automatic reset, stash or reclone is used.
3. A successful source edit is not a delivered app. Saved-version records retain
   the distinction between prepared, installed and restored app files. Cleanup
   is limited to explicitly selected Test-only obsolete restored payloads and
   refuses ambiguous or overlapping identities.
4. Review context can miss code that calls a changed function. A bounded scan of
   relative imports from the already collected repository map adds possible
   consumers without increasing the 24-file/64 KiB model context limit. This is
   static context selection, not a proven increase in model feature success.
5. Review caught a side-process timeout that could leave a misleading running
   state. The fix surfaces timeout or unexpected interruption for the current
   owner only, with explicit retry and no automatic command replay.
6. Conversation compaction previously treated source-like successful output
   such as `return false` or `throw new Error(...)` as negative evidence merely
   because it contained a broad marker. The classifier now requires explicit
   diagnostic phrasing for those tokens, with regression coverage for both
   source-like success and real `Error:` output.
7. The disposable campaign host accepted a bundle by identity alone during
   swap. Its package and swap paths now require the same Info.plist,
   executable and freshness checks used by production artifact discovery.
8. Optional request-probe failures no longer disappear as a silent all-quiet
   result. They remain non-blocking but produce one deterministic,
   plain-language reversible-posture question; explicit irreversibility still
   takes precedence.
9. Run-log and memory records now sanitize control characters, credential-shaped
   values, newlines, and hostile app slugs at both storage and prompt egress.

## Verification interpretation

Nontechnical intake regressions exercise consequential questions, preserving
answers, scope changes and stale responses. They do not establish that every
real model asks good questions. The actual successful feature, delivered app,
retained document and restart-selected Undo must still be observed together for
each acceptance target. Prior successful native lifecycle checks do not turn
the unsuccessful complex-feature trials into accepted outcomes.

The remaining long-running protocol limit is explicit: it has no separate
process-admission callback. Starting means the command was queued, not that a
service became healthy. A late failure is shown only while that step still owns
the runner; later guide progress must not be overwritten by an older process.

## Acceptance loop

Use a failing observed case to select a bounded fix, review overlapping state,
run focused and existing regression checks, then build the separate Test app.
Operate its actual controls and inspect screenshots. Record both successful
transitions and remaining failures. Pair those results with confined defensive
checks for path, credential, command, cancellation and delivery boundaries.
Do not label a code commit or successful build as installed behavior acceptance.

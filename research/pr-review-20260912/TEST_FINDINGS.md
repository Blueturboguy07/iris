# Sanitized test findings

These findings are limited to the evidence retained in the harness-v2 reports.
They intentionally omit raw logs, run identifiers, private fixture contents,
absolute machine paths, and account or credential data.

Fresh review-snapshot check on September 11: the standalone harness package
compiled and executed 110 tests across five suites with zero failures. This
tests intake, scope/decision state, projection, budgets and cancellation, not
an installed complex feature. Separately, actual interaction with the recorded
Test app confirmed truthful noninstallation, History expansion, Clear history
confirmation, cancellation preserving saved entries, and general Ask routing.

The fresh standalone usability package did not compile: its linked
`EditVerificationReceipt.swift` now calls `scrubbedVerificationOutputTail`, but
that package does not include the production helper. Native module compilation
still passes because it includes the helper. This is an actionable test-package
wiring regression, not a passing usability suite and not evidence that the GUI
receipt path itself fails. Keep it as a separate follow-up from the tested source
snapshot.

## 1. Transfer identity is the blocking correctness defect

The transfer request requires identity distinct from display labels, timestamps,
or current content. The observed implementation instead had several ambiguous
paths:

- An early trial could merge distinct folders when names and creation times
  matched.
- A later repair protected an incoming ID but still allowed a destination ID
  collision to reuse an unrelated destination entity.
- The next review found that repeated imports with multiple retained copies
  could create additional folders and notes on every repeat.
- A source provenance field was discarded during parsing, so onward transfer
  could not preserve the identity needed for a later conflict.

Two retained local reduced reproducers confirmed order-sensitive folder mapping
and repeated-copy growth of three, four, five, then six folders for unchanged
imports. They are reduced causal diagnostics, not a reconstruction or acceptance
of the complete reverted feature. The general missing contract separates origin
identity, local instance identity, content equality, parent references, and copy
lineage. A fresh identifier alone cannot satisfy that contract.

## 2. Review evidence was initially packed for the wrong stage

The transfer oracle bodies and immutable native helpers could crowd out product
types, repository initialization, download code, or the actual consumer. The
stage-aware selector now gives code admission product dependencies first and
defers protected native fixture bodies to final behavior review. The existing
file, hash, registration, revision, coverage, and byte limits remain.

This correction is a review-context improvement, not proof that final transfer
evidence is complete. Trial 21 still recorded omitted consumer context and was
correctly rejected. A reviewer must not infer that an omitted file was inspected
because a neighboring test or helper was present.

## 3. Native transfer readiness is a negative control

The disposable transfer oracle can launch its protected route and validate its
registration. Its baseline run completed seven checks, with six passing and one
expected missing export control. That result proves safe refusal and readiness
plumbing only. The positive export, two-profile import, duplicate/copy, restart,
and transaction-abort paths did not run against a completed feature.

The target app's existing export surface was also observed to report success
after a cancelled native Save dialog. That is a target-app truthfulness finding,
not an Iris transfer success or an Iris fix.

## 4. The input reserve fixed a measured scheduling failure

The earlier scheduler held review calls but not enough serialized input space
for the first correction. The bounded fix preserves one review-stage bound,
the latest settled edit size, and existing evidence headroom before first
verification, with a feasibility guard for small jobs. At verification entry,
the temporary reserve is released; mandatory native review bounds remain.

Deterministic replay failed against the old scheduler and passed against the
new one. The passing replay admitted and charged a repair, then fit both full
native review bounds inside the original call and submitted-byte limits. Trial
21 independently used two repair requests before semantic review rejected the
candidate. This proves a correction opportunity, not lower cost, better model
reasoning, or a working transfer.

## 5. Small feature lifecycle evidence is real but narrow

Trial 17 used the installed NitroAI app for folder-scoped search, then quit and
reopened the app, restarted Iris, selected Saved app versions Undo, and observed
the old app plus preserved pre- and post-update notes. An earlier PlantGPT trial
covered a small project-search update and the same recovery path. These journeys
are useful evidence for delivery and recovery mechanics, but neither is a
stateful cross-computer transfer or a complex generated feature.

## 6. Installer correction is bounded

The package-discovery fix recognized the tested `release/mac*` layouts, checked
the expected app identity and executable, and rejected stale artifacts. A
disposable package and atomic replacement used this path successfully, with a
recoverable prior Test bundle. It does not cover arbitrary build-output layouts,
all packaging scripts, or the transfer feature's behavior.

## 7. Kneecap remains a separate safety issue

Runtime recorded a source-pin refusal, then concurrent shell requests rejected
while an earlier command remained pending. A later inspection found an existing
dirty checkout; its later state is not proof of the original refusal's cause.
The classifier describes the source guard without claiming that a folder was
verified or missing. A retry ownership correction is under test. No source reset,
reclone, deletion, phone install, or signed-release acceptance is permitted by
this package.

## Findings disposition

| Finding | Current disposition |
| --- | --- |
| Transfer identity/provenance | Open blocker; requires a general identity contract and a new accepted candidate. |
| Missing final consumer context | Open evidence risk; do not waive the final review or raise limits without a causal plan. |
| Missing transfer UI control in oracle baseline | Open readiness gap; native positive checks cannot run until the supported route exists. |
| Input reserve mismatch | Bounded fix verified as a harness mechanism; retain existing gates. |
| Installer artifact discovery | Bounded fix verified for tested layouts; not a general packaging guarantee. |
| Kneecap clean-copy refusal | Separate operational WIP; preserve dirty source and wait for retry/resume fix. |

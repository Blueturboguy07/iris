# Iris PR review package

Status: **not merge-ready**.

Follow-ups after frozen snapshot `e79b401`: [installer retry ownership](FOLLOWUP_RETRY_OWNERSHIP.md) and [standalone package wiring](FOLLOWUP_PACKAGE_WIRING.md). The latter now passes 134 tests. The baseline findings below remain historical; these follow-ups do not establish full installer or complex-feature acceptance.

This package contains the source snapshot behind the currently installed Iris
Test artifact, plus separately labeled follow-up commits when available. The
first snapshot's 174 compiled native source files match the recorded tested
source aggregate. It is a review package, not a release or feature-completion
claim. See [BUILD_LINEAGE.md](BUILD_LINEAGE.md) for exact identifiers.

Lineage warning: the package is tied to the tested experimental snapshot, not
to the current upstream/main tip. Upstream has advanced since that snapshot.
Treat this as a draft PR with an explicit integration warning. Any conflict
resolution or upstream fix must be rebuilt, rechecked, and installed in Iris
Test before its behavior can join this evidence.

## Decision in one minute

- Native source compilation, the fresh 110-test harness suite, signing checks,
  and recorded controlled recovery probes pass. A fresh standalone usability
  package build failed on missing shared-helper wiring; that is disclosed WIP.
- A small NitroAI search journey, and an earlier small PlantGPT journey, were
  exercised through the installed Test app, relaunch, Iris restart, and Saved
  app versions Undo. Those are narrow lifecycle proofs.
- The requested notes/folders transfer feature was rejected in trials 18-21.
  It was never accepted, installed, or exercised by the native transfer suite.
- The repair-input reserve works in deterministic replay and did provide live
  repair calls in trial 21, but it did not fix the remaining transfer identity
  defect or missing consumer evidence.
- No live complex-transfer success exists. The paid feature loop stopped after
  the trial 21 review rejection; no unchanged retry is part of this package.

Therefore a reviewer may inspect the implementation and its defensive tests,
but must not mark the branch ready to merge or describe the transfer feature as
working.

## Read in this order

1. [STATUS_MATRIX.md](STATUS_MATRIX.md) for the evidence class of each claim.
2. [TEST_FINDINGS.md](TEST_FINDINGS.md) for causal findings and their limits.
3. [REVIEWER_PRECAUTIONS.md](REVIEWER_PRECAUTIONS.md) for safe Test setup,
   rollback, and evidence rules.
4. [BUILD_LINEAGE.md](BUILD_LINEAGE.md) for snapshot and artifact identity.
5. [UPSTREAM_INTEGRATION.md](UPSTREAM_INTEGRATION.md) for overlapping fixes.

The detailed campaign reports remain historical evidence. They contain local
operator details and should not be copied into a public issue, release note,
or PR description.

## What the installer correction proves

The bounded correction recognizes the tested conventional macOS artifact
layouts `release/mac`, `release/mac-arm64`, and `release/mac-universal`, checks
the declared executable and bundle identity, rejects stale artifacts, and
keeps an actionable bounded diagnostic. It was exercised at the disposable
package and atomic-swap boundary. Arbitrary custom output layouts, complex
feature behavior, and cross-computer transfer are outside that proof.

## What is safe to review now

Review source and controlled checks under the existing Test-only architecture:

- `iris-macos/tools/harness-feature-host/` contains the disposable host and
  lifecycle checks. Its README is the source of the current host invocation.
- `iris-macos/tools/transfer-native-oracle/` contains the independent transfer
  oracle contract and negative readiness route. It has not produced a positive
  transfer result.
- [TEST_FINDINGS.md](TEST_FINDINGS.md) summarizes the narrow installed search
  journey and the rejected transfer stages. Raw campaign reports are excluded.

Do not start another paid transfer attempt from this package. A future retry
needs a supported real export/import route, durable identity semantics, and
consumer-visible evidence before it can be useful.

## Separate operational item: Kneecap

Kneecap is not evidence for or against the transfer feature. Its installation
follow-up remains unresolved. Historical runtime recorded a source-pin refusal
and later commands rejected because a prior shell command was still pending.
A later filesystem inspection found an existing dirty checkout. This does not
establish exactly which condition caused the historical source-pin refusal.
The classifier describes the refusal without claiming that a folder is missing.

The retry/resume path is still being fixed. Preserve the existing checkout and
all local changes. Do not reset, stash, delete, reclone, or repeatedly retry a
deterministic refusal. A documented Mac-to-iPhone/Xcode route exists, but no
signed release, trusted physical device, USB-C transfer, or phone acceptance
was observed. See [KNEECAP_SETUP.md](KNEECAP_SETUP.md); this package makes no
device claim.

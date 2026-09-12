# Harness goal audit

Date: 2026-09-12

Scope: the isolated Iris harness in this checkout. This is a deterministic
source and fixture audit. It is not a paid model run, an installed-app claim,
or a computer-use acceptance result.

## Result

The harness has a coherent path for lightweight intake through bounded
planning, typed execution, independent review, and honest usage reporting.
No production code change is justified by this audit. The existing checks are
already broad enough to protect the requested contract, while the remaining
gaps require real model, installed-app, or user-observed evidence rather than
another local abstraction.

## Goal-to-evidence map

| User goal | Current mechanism | Deterministic evidence | Boundary that remains |
| --- | --- | --- | --- |
| Lightweight nontechnical intake | `HarnessFeatureWorkflow` asks for product choices, rejects repository-answerable implementation questions, and requires user-observable acceptance criteria | `HarnessNontechnicalIntakeAcceptanceTests.swift`, including vague paste, transfer, search, import, and background-job requests | Fake replies prove state handling, not that a real model asks good questions |
| Clarification gaps | Stable question IDs, bounded follow-ups, explicit free-text resolution, contradiction rejection, stale-plan and scope-reconciliation guards | `HarnessClarificationWorkflowTests.swift`, `HarnessDecisionProjectionTests.swift` | No live reader interaction or real model clarification quality |
| Typed execution and review | `HarnessModelSession` admits one physical attempt per reservation; `HarnessCodexAdapter` selects phase routes; structured edits flow through the existing executor; `HarnessBehaviorAssessment` requires criterion-level test references and a passing suite | `HarnessFeatureWorkflowTests.swift`, `HarnessBehaviorAssessmentTests.swift`, `HarnessReviewInputBudgetTests.swift`, and headless host review wiring | No complex feature was accepted or delivered in this audit |
| Bounded budgets | `HarnessRunLedger` charges every admitted call and serialized input byte, retains uncertain failures, and rejects new work after stop; review input and call reserves are held before editing; reply and deadline limits are enforced | `HarnessRunLedgerTests.swift`, `HarnessModelSessionTests.swift`, `HarnessCodexConversationBudgetTests.swift`, `HarnessReviewInputBudgetTests.swift`, and headless review-reserve/repair-window checks | This is a hard call/byte boundary, not a provider token or dollar ceiling |
| Usage and cost accounting | `IrisTestRunUsage` records payload-free per-call counts, token families, in-flight unknowns, and settled aggregates; `AssistantSpendLedger` prices only known metered own-key routes and never invents `$0.00` | Headless `UsageAttributionChecks.swift` passed UTF-8 attribution, failed-call accounting, unsettled aggregate omission, and legacy-shape checks | Harness Codex runs intentionally report `estimatedCostUSD: null`; provider billing and requested model identity are not confirmed, so a dollar total would be misleading |
| Actual acceptance evidence | Behavior coverage is separate from build success or model `DONE`; exact revision, clean review, passing suite, and criterion-level references are required before automatic delivery; manual-test candidates stay out of automatic delivery | `HarnessBehaviorAssessmentTests.swift`, `HarnessFeatureWorkflowTests.swift`, and headless review-reserve/native-wiring checks | Installed target-app behavior, physical UI, restart persistence, and user-observed complex-feature success remain unverified |

## Checks run

From the repository root:

```sh
swift test --package-path iris-macos/tools/harness-tests
```

Result: 112 tests passed in 5 suites.

The no-model native host was also compiled into a fresh disposable directory
and run with `--checks`:

```sh
node iris-macos/tools/harness-feature-host/build.mjs <fresh iris-harness-host-* directory>
<fresh directory>/iris-harness-feature-host --checks
```

Result: build exit 0, 175 native sources compiled, 262 compiler warnings, and
all inert checks passed. The checks covered usage attribution, output and
review-input budgets, review wiring, review-reserve failure and success,
verification diagnostics, repair-window admission, command freshness, and
early verification checkpoints. No model transport was invoked.

## Deliberately unverified live paths

- Real model question quality for nontechnical requests.
- A new complex feature that reaches a real target-app consumer and behaves
  correctly with populated data.
- Automatic delivery of a newly accepted feature into a disposable installed
  app, followed by relaunch and restart-selected Undo for that same feature.
- Physical UI, cross-app, restart, network, or phone/device acceptance.
- A provider-confirmed model identity, provider invoice, or trustworthy dollar
  cost for the Codex subscription route.

These are acceptance gates, not failures of the deterministic harness checks.
The existing whole-system plan and status matrix remain the authoritative
places for installed and computer-use evidence.

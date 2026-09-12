# Iris lab PR source scope audit

Audit date: 2026-09-11

This is a sanitized inventory for review. It does not authorize staging or
commit. The worktree is intentionally dirty and contains source, tests,
research notes, generated outputs, and private fixture captures.

## Git boundary

- Repository: `iris-harness-lab`
- Branch: `codex/iris-harness-lab`
- Remotes: `origin` is the fork; `upstream` is the source repository.
- Baseline: `18dd318987c4e00809680a2e9ed8197ec5117ee7`.
- Current HEAD: `98369a7012680291080b7a2d18ce1134501fdd80`, a descendant of the baseline.
- Against `upstream/main` (`84dd908...`), the committed branch delta is 210
  files, 20,365 added lines, and 1,460 deleted lines. The largest groups are
  `iris-macos/tools` (92 files), `iris-macos/leanring-buddy` (77), and
  `iris-macos/leanring-buddyTests` (29), plus four research documents and
  verification/configuration files. This upstream comparison is the relevant
  PR scope; the older 18dd snapshot is the lab experiment baseline only.
- The status contains 72 tracked-path changes and 93 untracked status entries.
  Full untracked enumeration is 1,579 paths, including 1,379 paths below
  `iris-macos/.build/`.
- The `9fb3ea4e...` value recorded by Trial 20 and Trial 21 is an installed
  test dylib digest, not a Git object or source baseline. It is not usable as
  PR ancestry.
- The current worktree also has uncommitted changes in
  `iris-macos/leanring-buddy/GuideAutopilotRunner.swift` and
  `iris-macos/leanring-buddy/GuideSessionController.swift`. Keep those source
  changes separate from the clean-branch copy until their intended review
  scope is confirmed.

## Reviewable Iris source and tests

The following tracked paths are technical source or tests changed from the
baseline. They are candidates for a deliberate PR inventory, subject to the
privacy checks below.

`iris-macos/leanring-buddy/`:

`AppInventorySectionView.swift`, `AppInventoryService.swift`,
`AppRelaunchService.swift`, `ChatTranscriptStore.swift`,
`CodexMaintainProvider.swift`, `CompanionManager.swift`,
`CompanionPanelView.swift`, `DeliveredEditUndoRecovery.swift`,
`DeliveredEditUndoRecoveryStore.swift`, `EditVerificationReceipt.swift`,
`FeatureEditAdversarialReviewer.swift`, `FeatureEditRepositoryContext.swift`,
`FeatureEditRequestProbe.swift`, `FeatureEditVerificationAudit.swift`,
`GuideAutopilotOutputBuffer.swift`, `GuideAutopilotRunner.swift`,
`GuideAutopilotShellSession.swift`, `GuideAutopilotTakeoverPanel.swift`,
`GuideAutopilotTerminalView.swift`, `GuideSessionController.swift`,
`GuideStepPointing.swift`, `HarnessBehaviorAssessment.swift`,
`HarnessCodexAdapter.swift`, `HarnessComparison.swift`,
`HarnessConversationProjection.swift`, `HarnessExecutionJournal.swift`,
`HarnessFeatureWorkflow.swift`, `HarnessFixtureEnvironment.swift`,
`HarnessModelSession.swift`, `HarnessRunLedger.swift`, `HarnessTaskState.swift`,
`KeychainStore.swift`, `MaintainBuildScriptGuard.swift`,
`MaintainDiagnosticProbe.swift`, `MaintainFeatureRequests.swift`,
`MaintainFileEditApplier.swift`, `MaintainFixCommit.swift`,
`MaintainPoolClient.swift`, `MaintainSandbox.swift`, `MaintainShellRunner.swift`,
`MaintainTierCFixer.swift`, `OnDemandEditCard.swift`,
`OnDemandEditCoordinator.swift`, `OnDemandEditInterruptedRunRecovery.swift`,
`OnDemandEditRunLog.swift`, `OverlayEyeInputBar.swift`,
`OverlayEyeInputBarDraftStore.swift`, `OverlayEyeInputBarDropTarget.swift`,
`PatchQueue.swift`, `RepoRecipe.swift`, `RepoRecipeNodeWebDetector.swift`,
`RepoRecipeRustTauriDetector.swift`, `RepoRecipeService.swift`,
`SelectionTextField.swift`, `VerificationHarness.swift`,
`leanring_buddyApp.swift`.

Tracked tests:

`iris-macos/leanring-buddyTests/AppInventoryTests.swift`,
`AppRelaunchInstalledDeliveryTests.swift`,
`FeatureEditAdversarialReviewerTests.swift`,
`FeatureEditRepositoryContextTests.swift`, `GuideAutopilotRunnerTests.swift`,
`OnDemandEditEvidenceDisciplineTests.swift`, `OnDemandEditMemoryTests.swift`,
`OnDemandEditTests.swift`, `PublikTest2PackagingDmgToleranceReproTests.swift`,
`RepoRecipeServiceTests.swift`, `Test7DirtyCloneReproTests.swift`.

Tracked tool and fixture source:

- `iris-macos/tools/codex-provider-contract-tests/ProviderContractChecks.swift`
- `iris-macos/tools/codex-provider-contract-tests/TypecheckStubs.swift`
- `iris-macos/tools/edit-battery/fixtures/t7-js-export-queue/` (oracle, work
  source, package metadata, and regression test)
- `iris-macos/tools/harness-feature-host/HarnessFeatureHost.swift`,
  `HarnessReviewReserveChecks.swift`, `build.mjs`
- `iris-macos/tools/harness-tests/Sources/IrisHarness/` (the eight harness
  source files)
- `iris-macos/tools/harness-tests/Tests/IrisHarnessTests/` (the ten harness
  tests)
- `iris-macos/tools/account-session-tests/Package.swift`,
  `iris-macos/tools/usability-tests/Package.swift`, and
  `iris-macos/tools/edit-battery/manifest.json`.

Untracked technical source and tests that are part of the Iris lab candidate,
not build output:

- `iris-macos/Package.swift`
- `iris-macos/leanring-buddy/`:
  `AppDeliveryReceiptStore.swift`, `FailedEditReviewArchive.swift`,
  `HarnessNativeVerificationSequence.swift`, `Info-Test.plist`,
  `InterruptedUndoResumeIdentity.swift`, `Iris-Test.entitlements`,
  `IrisTestAppDelivery.swift`, `IrisTestEnvironment.swift`,
  `IrisTestNativeVerification.swift`, `IrisTestProjectRegistry.swift`,
  `IrisTestRunUsage.swift`, `IrisTestVerificationPlan.swift`,
  `MaintainSavedChangeRechecker.swift`, `PendingEditCandidateIdentity.swift`,
  `RepoRecipeShippingEvidence.swift`, `SavedAppVersionsSection.swift`,
  `SavedEditDeliveryIdentity.swift`.
- `iris-macos/leanring-buddyTests/IrisTestRunUsageTests.swift` and
  `SpatialGuidanceRegressionTests.swift`.
- `iris-macos/tools/codex-provider-process-tests/`:
  `ProcessLifecycleChecks.swift`, `README.md`, `TypecheckStubs.swift`.
- `iris-macos/tools/environment-tests/Tests/IrisEnvironmentTests/IrisTestEnvironmentTests.swift`.
- All 36 untracked checks and helpers under
  `iris-macos/tools/harness-feature-host/`, including the delivery, native,
  repair, context, policy, toolchain, memory, usage, and diagnostic checks.
- `iris-macos/tools/harness-feature-host/build-unadmitted-repair.mjs`.
- `iris-macos/tools/harness-tests/Tests/IrisHarnessTests/`:
  `HarnessCodexConversationBudgetTests.swift`,
  `HarnessDecisionProjectionTests.swift`,
  `HarnessNontechnicalIntakeAcceptanceTests.swift`,
  `HarnessReviewInputBudgetTests.swift`.
- `iris-macos/tools/maintain-test-harness/TestContainmentProbe.swift`.
- `iris-macos/tools/transfer-native-oracle/`:
  `README.md`, `cases.mjs`, `transfer-fixture.mjs`, `transfer.test.mjs`.

The clean PR branch must also account for the source and test paths inherited
from the 18dd snapshot but changed relative to `upstream/main`. The complete
194-path technical set is:

- App sources in `iris-macos/leanring-buddy/`: `AGENTS.md`,
  `AccountService.swift`, `AssistantRequestDiagnostics.swift`,
  `CatalogAppIconLoader.swift`, `CatalogAppIconView.swift`,
  `CatalogMacCompatibility.swift`, `ChatActionTools.swift`, `ClaudeAPI.swift`,
  `ClaudeCodeLogin.swift`, `CodexEditModelPicker.swift`,
  `CodexEditModelSelection.swift`, `DesignSystem.swift`,
  `EditTerminalStartMinimizedPreference.swift`,
  `GuideAutopilotAvailability.swift`, `GuideAutopilotCommandShape.swift`,
  `GuidePanelView.swift`, `GuidePointing.swift`,
  `GuidePointingFreshness.swift`, `IrisChatLoadingBar.swift`, `IrisEyeView.swift`,
  `KeychainReadPolicy.swift`, `MaintainClonePathLock.swift`,
  `MaintainModelProvider.swift`, `MenuBarPanelManager.swift`,
  `MenuBarPanelPlacement.swift`, `OverlayEyeGuideCard.swift`,
  `OverlayEyeInteraction.swift`, `OverlayEyeRestingPlace.swift`,
  `OverlayIrisEyeView.swift`, `OverlayWindow.swift`,
  `PatchQueueCheckedRemoval.swift`, `SavedUndoRecoverySection.swift`,
  `SettingsPanelRouting.swift`, and `SettingsPanelSceneRedirect.swift`.
- Additional app tests in `iris-macos/leanring-buddyTests/`:
  `AppRelaunchPackagingCommandTests.swift`,
  `AssistantRequestDiagnosticsTests.swift`,
  `Bug10GlobalPackageInstallPathReproTests.swift`,
  `CatalogAppIconTests.swift`, `CatalogMacCompatibilityTests.swift`,
  `ChatActionCancellationTests.swift`, `ChatTranscriptResetTests.swift`,
  `CodexCLILoginTests.swift`, `CodexEditModelSelectionTests.swift`,
  `ComposerConnectionPresentationTests.swift`, `EditBatteryLiveTests.swift`,
  `EditVerificationReceiptTests.swift`, `GuideAutopilotCommandShapeTests.swift`,
  `GuidePointingTests.swift`, `GuidePresentationRegressionTests.swift`,
  `IrisEyeTests.swift`, `KeychainReadPolicyTests.swift`,
  `OverlayEyeDragTests.swift`,
  `PublikTest2EditTerminalMinimizePreferenceTests.swift`,
  `SettingsPanelBehaviorTests.swift`, `Test7TakeoverResizeTests.swift`,
  `Test8DiscoveryTests.swift`, `VerificationAbsenceTests.swift`,
  `leanring_buddyTests.swift`.
- Account-session package and sources:
  `iris-macos/tools/account-session-tests/Package.swift`,
  `Sources/IrisAccountSession/AccountService.swift`,
  `DependencyStubs.swift`, `KeychainReadPolicy.swift`, `KeychainStore.swift`,
  and `Tests/IrisAccountSessionTests/AccountSessionTests.swift` plus
  `TestSupport.swift`.
- Chat-action package and sources:
  `iris-macos/tools/chat-action-tests/Package.swift`,
  `Sources/IrisChatActions/AutopilotAutonomyGrant.swift`,
  `ChatActionTools.swift`, `FixtureBoundaries.swift`,
  `GuideAutopilotOutputBuffer.swift`, `GuideAutopilotRiskAssessment.swift`,
  and its `Tests/IrisChatActionsTests/ChatActionCancellationTests.swift`.
- Usability package sources under
  `iris-macos/tools/usability-tests/Sources/IrisUsability/`:
  `AssistantRequestDiagnostics.swift`, `CatalogAppIconLoader.swift`,
  `CatalogMacCompatibility.swift`, `ChatTranscriptStore.swift`,
  `CodexEditModelSelection.swift`, `ComposerConnectionPresentation.swift`,
  `DeliveredEditUndoArchive.swift`, `DeliveredEditUndoRecovery.swift`,
  `DeliveredEditUndoRecoveryStore.swift`, `EditVerificationReceipt.swift`,
  `GuideAutopilotAvailability.swift`, `GuidePointingFreshness.swift`,
  `KeychainReadPolicy.swift`, `MaintainClonePathLock.swift`,
  `MenuBarPanelPlacement.swift`, `OverlayEyeRestingPlace.swift`,
  `PatchQueueCheckedRemoval.swift`, and `SettingsPanelRouting.swift`.
- Usability tests under
  `iris-macos/tools/usability-tests/Tests/IrisUsabilityTests/`:
  `AssistantRequestDiagnosticsTests.swift`, `CatalogAppIconTests.swift`,
  `CatalogMacCompatibilityTests.swift`, `ChatTranscriptResetTests.swift`,
  `CodexEditModelSelectionTests.swift`, `ComposerConnectionPresentationTests.swift`,
  `DeliveredEditUndoArchiveTests.swift`,
  `DeliveredEditUndoRecoveryStoreTests.swift`,
  `DeliveredEditUndoRecoveryTests.swift`, `DeliveredEditUndoSourceTests.swift`,
  `EditVerificationReceiptTests.swift`, `GuidePresentationRegressionTests.swift`,
  `KeychainReadPolicyTests.swift`, `OverlayEyeDragTests.swift`,
  `PatchQueueCheckedRemovalTests.swift`, `SettingsPanelBehaviorTests.swift`,
  and `StoppedUndoCloneProtectionTests.swift`.

This list is the source/test allowlist candidate. It does not include the
generated `.build` tree, private research captures, or the two uncommitted
retry-race files called out above.

## Exclude or separately review

- Exclude all `iris-macos/.build/` contents. They are compiler products,
  module caches, indexes, object files, and derived source, not PR source.
- Do not stage `research/harness-v2/power-user-2026-09-07/` as a source tree.
  Its logs, usage records, UI JSON, library JSON, generated backup source,
  patches, and package traces are private or generated fixture artifacts.
- Keep `research/redteam-2026-09-07/` research-only. Reports and campaign
  outputs may be retained as sanitized evidence, but logs, JSON usage/profile
  captures, binary probes, temporary run directories, and private fixture
  outputs are not source PR material.
- The three reproducible harness scripts
  `research/harness-v2/provision-plantgpt-locked.mjs`,
  `trial19-folder-order-repro.mjs`, and `trial21-ambiguous-copy-repro.mjs`
  are reviewable research code only, not product source.
- The tracked research additions `research/harness-v2/AUDIT.json`,
  `IMPLEMENTATION.md`, `PLAN.md`, and `WHIMPRFLOW_BENCHMARK.md` require
  sanitization before inclusion because they contain machine paths and links
  to private checkouts.

## Privacy and sanitization findings

No live API key, access token, private key, or provider credential was found
in the candidate source or tests. Credential-shaped values are synthetic test
canaries and still deserve review:

- `iris-macos/leanring-buddy/GuideAutopilotOutputBuffer.swift` contains
  redaction regexes and credential-shaped examples.
- `iris-macos/leanring-buddy/MaintainTierCFixer.swift` contains credential
  redaction logic and task text handling.
- `iris-macos/leanring-buddyTests/OnDemandEditMemoryTests.swift` contains
  synthetic token-shaped assertions.
- `iris-macos/tools/harness-feature-host/HarnessReviewReserveChecks.swift`
  contains synthetic header and secret-shaped canaries.
- Untracked `iris-macos/tools/harness-feature-host/PowerUserHost.swift` and
  `VerificationDiagnosticChecks.swift` contain synthetic secret-shaped test
  data. Keep them clearly marked as generated canaries or replace them with
  runtime-generated sentinels before a public PR.

Newly introduced or untracked hard-coded local paths requiring sanitization or
environment-derived fixture roots include:

- `AGENTS.md`, `iris-macos/AGENTS.md`,
  `iris-macos/leanring-buddy/MaintainSandbox.swift`,
  `iris-macos/leanring-buddyTests/GuideAutopilotRunnerTests.swift`, and
  `PublikTest2PackagingDmgToleranceReproTests.swift`.
- `iris-macos/tools/codex-provider-contract-tests/README.md`,
  `iris-macos/tools/harness-feature-host/HarnessFeatureHost.swift` and
  `README.md`.
- `iris-macos/tools/harness-feature-host/AppDeliveryChecks.swift`,
  `AppDeliveryReceiptChecks.swift`, `BackupRetentionChecks.swift`,
  `InterruptedUndoResumeIdentityChecks.swift`, `IrisTestAppDeliveryChecks.swift`,
  `IrisTestGitPreflightChecks.swift`, `IrisTestNativeVerificationChecks.swift`,
  `IrisTestProjectRegistryChecks.swift`, `IrisTestToolchainChecks.swift`,
  `MaintainFixCommitChecks.swift`, `MaintainSandboxToolchainChecks.swift`,
  `MaintainSavedChangeRecheckerChecks.swift`,
  `PendingEditCandidateIdentityChecks.swift`, `PlantGPTBuildPreflight.swift`,
  `PowerUserHost.swift`, `RepairCandidateIdentityChecks.swift`,
  `SourceCheckoutRefusalChecks.swift`, `UnadmittedRepairChecks.swift`, and
  `build-unadmitted-repair.mjs`.
- `iris-macos/tools/maintain-test-harness/TestContainmentProbe.swift` and
  `iris-macos/tools/transfer-native-oracle/transfer-fixture.mjs`.

These paths contain either a developer home directory, an installed-app path,
an application-support path, a fixed temporary directory, or a private
research checkout. Use `FileManager.temporaryDirectory`, an explicit fixture
root, or a repository-relative placeholder. Do not copy the observed local
paths into a PR description.

Inherited baseline path and canary references exist in older unchanged Iris
tests and runtime code. They are not evidence that the current candidate added
a credential. The newly added and modified paths above are the ones requiring
review before staging.

User-like fixture content is present in the power-user JSON/log captures and
in the transfer-oracle and power-user host fixtures. It is synthetic or test
data, but it can reveal note titles, note bodies, task requests, saved paths,
or run metadata. Exclude the captured artifacts and keep only minimal,
sanitized fixture literals in source/tests.

## Bounded context and cost findings

- `FeatureEditRepositoryContext.swift` discovers only one forward local import
  hop. It cannot discover reverse consumers of changed storage/helpers. Trial
  21 therefore omitted the real listing consumer while preserving the changed
  tests and product evidence. A bounded reverse-consumer priority slot is the
  smallest general fix; do not increase the 24-file or 64 KiB limits.
- The real NitroAI consumers are `Dashboard.tsx` for listing and `NoteView.tsx`
  for editing. A guessed `src/pages/Editor.tsx` does not exist.
- `HarnessConversationProjection.swift` still classifies any successful output
  containing broad substrings such as `false` or `error` as negative evidence.
  A successful source read containing `return false` or `throw new Error` can
  therefore be retained indefinitely. This remains unfixed and should be
  labeled as an open context-budget issue, not silently changed during PR
  cleanup.
- Trial 21 reports 15 calls, 1,543,541 submitted input bytes, 681,899 reported
  input tokens including 186,240 cached, 9,981 output tokens, 1,041 reasoning
  tokens, and 500.24 seconds. Provider-confirmed dollar cost and model identity
  were unavailable. These are campaign observations, not acceptance proof.

## Merge readiness

The dirty source is not yet committable. First separate reviewable Iris source
and tests from research artifacts, replace machine-specific paths, check the
synthetic credential canaries, and preserve explicit omissions. Do not use
`git add --all`; stage an allowlist only after this audit is resolved.

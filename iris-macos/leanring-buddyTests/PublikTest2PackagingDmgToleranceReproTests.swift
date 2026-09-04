//
//  PublikTest2PackagingDmgToleranceReproTests.swift
//  leanring-buddyTests
//
//  PUBLIK TEST 2 — "Iris couldn't build a runnable copy of WhimprFlow (the
//  packaging build failed: … Running bundle_dmg.sh … failed to bundle project:
//  error running bundle_dmg.sh)."
//
//  WHAT WENT WRONG (Iris 0.9.8). After an on-demand edit, delivery rebuilds the
//  app from the clone with `tauri build` and then installs the fresh `.app` over
//  the reader's copy. A Tauri build bundles the `.app` FIRST and only then wraps
//  it in a `.dmg` — and that `.dmg` step (`bundle_dmg.sh`, which drives Finder
//  over AppleScript) fails on its own in an automated, headless context even
//  when the `.app` compiled and bundled perfectly. `packageFreshBuildFromClone`
//  guarded on the build's overall EXIT CODE first (`guard build.succeeded`), so
//  a build that failed ONLY at the DMG step — with a launchable `.app` already
//  sitting in `bundle/macos` — was reported as a packaging failure and the whole
//  edit delivery aborted. The reader saw "Iris couldn't build a runnable copy",
//  the fix was never installed, and the edit read as still-broken. Akrit hit it
//  repeatedly ("Same error as before").
//
//  THE FIX makes the `.app` win over the exit code: the pure `packagingVerdict`
//  delivers a FRESH launchable `.app` whatever the build's exit code was, and
//  only falls back to a failure — with the build's error tail — when no fresh
//  `.app` was produced. Iris installs the `.app` and never touches the `.dmg`,
//  so a DMG failure must not block a delivery whose real artifact exists.
//
//  Safe against delivering broken code: a genuine compile failure stops the
//  build BEFORE the `.app` is bundled, so no fresh `.app` appears and the
//  verdict is a failure — which the `noFreshAppMeansFailure` cases pin.
//

import Testing
@testable import Iris

@Suite
@MainActor
struct PublikTest2PackagingDmgToleranceReproTests {

    // MARK: - THE REPRO: a DMG-step failure with a good .app still delivers

    /// The exact WhimprFlow case: the `.app` was produced, but the build exited
    /// non-zero because `bundle_dmg.sh` failed. Delivery must proceed with the
    /// `.app`. Before the fix this returned a packaging failure.
    @Test func aFreshAppDeliversEvenWhenTheDmgStepFailedTheBuild() {
        let verdict = AppRelaunchService.packagingVerdict(
            freshLaunchableAppBundlePath: "/clone/target/release/bundle/macos/WhimprFlow.app",
            buildSucceeded: false,
            buildOutputTail: "Running bundle_dmg.sh\nfailed to bundle project: error running bundle_dmg.sh"
        )
        #expect(
            verdict == .deliverTheFreshApp(
                artifactPath: "/clone/target/release/bundle/macos/WhimprFlow.app"
            ),
            "a launchable .app was produced but the DMG step failed the build; Iris aborted delivery instead of using the .app it already had"
        )
    }

    /// The ordinary success path is unchanged: a fresh `.app` from a fully
    /// successful build delivers.
    @Test func aFreshAppFromASuccessfulBuildDelivers() {
        let verdict = AppRelaunchService.packagingVerdict(
            freshLaunchableAppBundlePath: "/clone/target/release/bundle/macos/WhimprFlow.app",
            buildSucceeded: true,
            buildOutputTail: ""
        )
        #expect(
            verdict == .deliverTheFreshApp(
                artifactPath: "/clone/target/release/bundle/macos/WhimprFlow.app"
            )
        )
    }

    // MARK: - No fresh .app is still an honest failure (compile errors, etc.)

    /// A real build failure that produced NO `.app` (a compile error stops before
    /// bundling) is still a packaging failure — and the build's error tail is the
    /// diagnostic worth showing.
    @Test func noFreshAppAndAFailedBuildIsAFailureCarryingTheTail() {
        let verdict = AppRelaunchService.packagingVerdict(
            freshLaunchableAppBundlePath: nil,
            buildSucceeded: false,
            buildOutputTail: "error[E0425]: cannot find value `foo` in this scope"
        )
        guard case .noLaunchableApp(let reason) = verdict else {
            Issue.record("a failed build with no .app should be a packaging failure, got \(verdict)")
            return
        }
        #expect(
            reason.contains("E0425"),
            "the failure should carry the build's own error so the reader (and the repair loop) can see it, got: \(reason)"
        )
    }

    /// The pathological case the old success-path guarded: a build that reported
    /// success but left nothing launchable. Still a failure, with its own honest
    /// wording rather than a stale error tail.
    @Test func noFreshAppButASucceededBuildIsAFailureWithoutATail() {
        let verdict = AppRelaunchService.packagingVerdict(
            freshLaunchableAppBundlePath: nil,
            buildSucceeded: true,
            buildOutputTail: "warning: some noise that is not an error"
        )
        #expect(
            verdict == .noLaunchableApp(
                reason: "the build finished but Iris couldn't find a launchable app it produced"
            )
        )
    }

    /// An empty tail on a failed build still fails cleanly, with a plain reason
    /// rather than an empty one.
    @Test func aFailedBuildWithNoOutputStillReadsAsAPackagingFailure() {
        let verdict = AppRelaunchService.packagingVerdict(
            freshLaunchableAppBundlePath: nil,
            buildSucceeded: false,
            buildOutputTail: "   \n  "
        )
        #expect(verdict == .noLaunchableApp(reason: "the packaging build failed"))
    }
}

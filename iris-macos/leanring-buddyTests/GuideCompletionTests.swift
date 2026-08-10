//
//  GuideCompletionTests.swift
//  leanring-buddyTests
//
//  When a guide finishes, Iris opens the app it just installed and refreshes
//  the "Your publik apps" list. Which app to open is read off the branch — the
//  bundle id the guide already watches for in the foreground — so that read is
//  what these tests pin down. Get it wrong and a finished install either opens
//  nothing or launches the wrong app.
//

import Foundation
import Testing
@testable import Iris

struct GuideCompletionTests {

    private static func step(
        kind: IrisStepKind,
        watch: IrisStepWatch?
    ) -> IrisGuideStep {
        IrisGuideStep(id: "s", kind: kind, title: "t", body: "b", watch: watch)
    }

    private static func branch(
        steps: [IrisGuideStep],
        setupSteps: [IrisGuideStep] = []
    ) -> IrisGuideBranch {
        IrisGuideBranch(
            platform: .macos,
            target: nil,
            label: "macOS",
            shell: .terminal,
            setupSteps: setupSteps,
            steps: steps,
            unsupported: nil
        )
    }

    @Test func bundleIdComesFromTheForegroundAppTheGuideWatchesFor() {
        let branch = Self.branch(steps: [
            Self.step(kind: .terminal, watch: IrisStepWatch(expect: [.toolVersion(tool: "node")])),
            Self.step(kind: .verify, watch: IrisStepWatch(expect: [.foregroundApp(bundleId: "com.publikhq.cue")])),
        ])
        #expect(branch.installedDesktopAppBundleId == "com.publikhq.cue")
    }

    @Test func aMainStepWinsOverASetupStep() {
        // The app's own "is it running" check lives in the main steps; a setup
        // step's foreground check (e.g. a prerequisite app) must not shadow it.
        let branch = Self.branch(
            steps: [Self.step(kind: .verify, watch: IrisStepWatch(expect: [.foregroundApp(bundleId: "com.publikhq.cue")]))],
            setupSteps: [Self.step(kind: .terminal, watch: IrisStepWatch(expect: [.foregroundApp(bundleId: "com.apple.Terminal")]))]
        )
        #expect(branch.installedDesktopAppBundleId == "com.publikhq.cue")
    }

    @Test func noForegroundExpectationMeansNothingToOpen() {
        // A local-web or credential flow watches a URL host or a tool version,
        // never a foreground app, so there is no Mac app to launch.
        let branch = Self.branch(steps: [
            Self.step(kind: .open, watch: nil),
            Self.step(kind: .terminal, watch: IrisStepWatch(expect: [.urlHost(host: "localhost")])),
        ])
        #expect(branch.installedDesktopAppBundleId == nil)
    }
}

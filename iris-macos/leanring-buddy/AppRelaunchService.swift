//
//  AppRelaunchService.swift
//  leanring-buddy
//
//  The rebuild → relaunch half of the on-demand edit tool (design §4), built
//  to Option A ("run straight from the clone's build output") and ONLY Option A:
//  it never writes into, copies over, or otherwise touches an installed/signed
//  `.app` bundle. It packages a fresh, launchable artifact FROM the user's own
//  source clone and launches THAT as a distinct instance. The signed copy in
//  /Applications (if any) is left exactly as it was — so this can never break a
//  notarization seal or overwrite something Iris did not build.
//
//  Why a separate PACKAGE step at all: the verification build the engine runs
//  before committing is a COMPILE-CHECK (Tauri `cargo build --release`, Electron
//  `npm run build`) — it proves the source compiles, but it does NOT produce a
//  double-clickable `.app`. The pipeline that produces one (`cargo tauri build`,
//  the repo's own electron-builder/forge packaging script) is different, heavier,
//  and — this is the honest catch the adversarial review names (#1/#2) — is NOT
//  what "verified" covered. So the artifact this service produces is UNVERIFIED
//  beyond "it packaged and a launchable bundle exists". That is why the whole
//  relaunch is gated behind its own explicit destructive consent upstream, and
//  why the sequence below refuses to terminate the running app until the fresh
//  artifact is proven to exist on disk.
//
//  The command STRINGS here are code-authored, never model-authored — exactly
//  like `VerificationCommands`. The model edits source files; it never chooses
//  or rewrites the package command. That authorship split is what keeps this
//  step safe to run un-jailed.
//
//  IMPORTANT — this path is UNVERIFIED until it is exercised on a real machine
//  against a real source-clone app. It has no unit coverage in the maintain
//  harness (which is pure-Foundation and cannot spawn `cargo tauri build` or
//  open a real bundle), and the terminate→wait→launch mechanics have never been
//  run against a foreign app before. Treat the first real relaunch as a
//  supervised dogfood, not a proven flow.
//

import AppKit
import Foundation

/// The outcome of packaging a fresh, launchable artifact from the clone. The
/// coordinator caches the `artifactPath` across the (possible) force-quit
/// consent so a heavy build is never run twice for one relaunch.
enum AppRelaunchPackagingResult: Sendable {
    /// A launchable `.app` exists on disk at `artifactPath`, produced by this
    /// build (newer than the moment the build started, so a stale bundle from a
    /// prior build is never mistaken for the fresh one). Nothing has been
    /// terminated yet — the running app is still up and untouched.
    ///
    /// `signingSummary` is one plain-English sentence about the artifact's code
    /// signature, and it is load-bearing for expectations rather than decoration:
    /// macOS keys TCC grants (screen recording, camera, mic, folders) to the
    /// SIGNATURE, so an ad-hoc-signed rebuild is a brand new app to the system
    /// and the reader's permissions reset. The coordinator shows this sentence so
    /// that outcome is disclosed before it surprises them.
    case artifactReady(artifactPath: String, signingSummary: String)
    /// This stack has no relaunchable macOS artifact at all — a Next.js web app,
    /// a swiftMacOS/`.other` app with no build vocabulary, or an Electron repo
    /// that declares no macOS packaging script Iris recognizes. Honest refusal,
    /// never a broken half-build.
    case stackHasNoRelaunchableArtifact(reason: String)
    /// The package command ran but failed, or produced no launchable bundle.
    /// Nothing was terminated — the running app is still up.
    case packagingFailed(reason: String)
    /// A precondition was missing (an unusable clone path). Nothing happened.
    case ineligible(reason: String)
}

/// The outcome of terminating the running instance and launching the fresh
/// build. Every case leaves the user with a running app OR an honest reason —
/// never a dimmed desktop with nothing open.
enum AppRelaunchLaunchResult: Sendable {
    /// The fresh build from the clone is now running. If an old instance was up
    /// it was terminated first; if none was up, the fresh build was simply
    /// launched. Because this is a from-source (unsigned / ad-hoc-signed) build
    /// with the app's own bundle id, macOS may treat it as a different signed
    /// identity and NOT carry over camera / mic / accessibility / folder grants
    /// — the coordinator discloses that honestly in the result copy.
    case relaunchedFreshBuild
    /// The running app declined to quit — almost always an unsaved-work "Save?"
    /// dialog holding the quit event. Iris did NOT force-kill through it (that
    /// can corrupt the app's own on-disk state mid-write, adversarial #5) and
    /// did NOT launch the fresh build. The old app is still up and unharmed; the
    /// coordinator surfaces a SECOND explicit "force quit anyway?" consent, and
    /// only that tap allows `forceTerminate`.
    case runningAppWouldNotQuit
    /// The fresh build failed to launch after the old app was terminated, so
    /// Iris re-opened the prior build the old instance came from — the user is
    /// never left with no app. `reason` is user-safe.
    case launchFailedPriorAppRestored(reason: String)
    /// A precondition was missing at launch time (no known `macBundleId`, an
    /// unreadable artifact). Nothing was terminated.
    case ineligible(reason: String)
}

@MainActor
final class AppRelaunchService {

    /// How long the packaging build may run before Iris gives up. A real
    /// `cargo tauri build` with a frontend bundle, or an electron-builder DMG
    /// pass, can take many minutes — far longer than the compile-check
    /// verification build — so this is deliberately generous.
    private let packagingDeadline: TimeInterval

    /// How long to wait for the running app to quit cleanly after `terminate()`
    /// before concluding it will not (an unsaved-work dialog is holding it).
    /// Short, because a well-behaved app quits in well under this.
    private let gracefulQuitTimeout: TimeInterval

    /// How Iris gets a code-signing identity that is IDENTICAL on every rebuild,
    /// or nil when there is none to be had. Injected rather than called directly
    /// so packaging stays testable without a keychain, and defaulted to nil so
    /// this service behaves exactly as it did before anything wires it up: no
    /// signing attempt, no keychain access, no consent prompt.
    ///
    /// Why it matters: macOS keys TCC grants to a code signature. A packaging
    /// build with no identity produces a different ad-hoc signature every time,
    /// so every rebuild looks like a new app and the reader re-grants screen
    /// recording, camera, mic and folder access each round. One stable identity
    /// makes the rebuild the SAME app to the system. See
    /// `IrisLocalSigningIdentity` and `scripts/deploy-iris-local.sh`.
    var resolveSigningIdentity: (() async -> StableSigningIdentity?)?

    init(packagingDeadline: TimeInterval = 1500, gracefulQuitTimeout: TimeInterval = 10) {
        self.packagingDeadline = packagingDeadline
        self.gracefulQuitTimeout = gracefulQuitTimeout
    }

    // MARK: - Stack eligibility

    /// Whether this stack can produce a relaunchable macOS artifact AT ALL —
    /// gated on relaunchability, not on merely "has a build command" (adversarial
    /// #6: a Next.js app has `npm run build` but no relaunchable macOS binary).
    /// The coordinator uses this to decide whether to even offer the relaunch
    /// consent; a false here degrades to the honest manual "Relaunch <App>
    /// yourself to pick it up" terminal state.
    static func stackCanProduceARelaunchableMacArtifact(_ stack: BreakAppStack) -> Bool {
        switch stack {
        case .tauri, .electron:
            return true
        case .nextjs, .swiftMacOS, .other:
            // Next.js is a web app — "relaunch" is undefined (there is no macOS
            // binary). swiftMacOS / `.other` have no packaging vocabulary Iris
            // knows. Refusing up front is the honest posture for this slice.
            return false
        }
    }

    // MARK: - Step 1: package a fresh, launchable artifact FROM the clone

    /// Run the code-authored, per-stack PACKAGE command in the clone and assert
    /// it produced a launchable `.app`. This does the heavy, un-jailed build; it
    /// terminates NOTHING. The caller only proceeds to terminate+launch once this
    /// returns `.artifactReady` — so the running app is never quit for a build
    /// that then fails (adversarial #2).
    func packageFreshBuildFromClone(
        clonePath: String,
        appStack: BreakAppStack
    ) async -> AppRelaunchPackagingResult {
        guard Self.stackCanProduceARelaunchableMacArtifact(appStack) else {
            return .stackHasNoRelaunchableArtifact(
                reason: "this kind of app has no rebuildable macOS copy for Iris to relaunch"
            )
        }
        guard let runner = try? MaintainShellRunner(repoRootPath: clonePath) else {
            return .ineligible(reason: "the clone path is not usable for a rebuild")
        }

        // Resolve the code-authored package command for this stack against this
        // repo. An Electron repo with no recognized macOS packaging script has
        // no honest command to run, so it refuses here rather than guess.
        guard let packageCommand = Self.packageCommand(forStack: appStack, clonePath: clonePath) else {
            return .stackHasNoRelaunchableArtifact(
                reason: "this app doesn't declare a macOS packaging step Iris recognizes"
            )
        }

        // Everything with an mtime at or after this instant is "from this
        // build". A pre-existing bundle from a prior build is older, so it can
        // never be mistaken for the fresh artifact (the honest "assert it exists"
        // is "assert a bundle THIS build produced exists", not "some bundle
        // exists").
        let buildStartedAt = Date()
        let build = try? await runner.run(packageCommand, deadline: packagingDeadline)
        guard build?.succeeded == true else {
            let tail = build?.outputTail.suffix(400).trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .packagingFailed(
                reason: tail.isEmpty ? "the packaging build failed" : "the packaging build failed: \(tail)"
            )
        }

        guard let artifactPath = Self.newestLaunchableAppBundle(
            forStack: appStack, clonePath: clonePath, producedAtOrAfter: buildStartedAt
        ) else {
            // The build reported success but no fresh `.app` appeared where this
            // stack puts one — treat as a packaging failure, never as "ready".
            return .packagingFailed(
                reason: "the build finished but Iris couldn't find a launchable app it produced"
            )
        }

        // Give the fresh bundle a signature that will be the same next rebuild,
        // if an identity is available. This can only IMPROVE the artifact — a
        // signing failure leaves the ad-hoc bundle exactly as the build produced
        // it, so it never turns a successful package into a failed one.
        let signingSummary = await signFreshArtifactWithAStableIdentityIfAvailable(artifactPath: artifactPath)
        return .artifactReady(artifactPath: artifactPath, signingSummary: signingSummary)
    }

    // MARK: - Stable signing (so a rebuild is not a new app to macOS)

    /// What the reader is told when the fresh build could not be given a stable
    /// signature. Deliberately blunt: the permission reset is the consequence
    /// they will actually notice, so it is named rather than implied.
    static let adHocSigningSummary =
        "ad-hoc — macOS will treat this build as a new app, so its permissions may reset"

    /// Sign the packaged artifact with the injected stable identity, and return
    /// the one-sentence summary that travels with the packaging result. With no
    /// seam wired up (the default) this signs nothing and reports the honest
    /// ad-hoc sentence.
    private func signFreshArtifactWithAStableIdentityIfAvailable(artifactPath: String) async -> String {
        guard let resolveSigningIdentity else { return Self.adHocSigningSummary }
        guard let identity = await resolveSigningIdentity() else { return Self.adHocSigningSummary }
        let outcome = await IrisLocalSigningIdentity.signApplicationBundle(
            atPath: artifactPath, identity: identity
        )
        return Self.signingSummary(forSigningOutcome: outcome, identity: identity)
    }

    /// Pure: the sentence for a signing outcome. A failure still reports the
    /// ad-hoc consequence FIRST — what the reader needs to know is what will
    /// happen to their permissions, not which tool complained.
    static func signingSummary(
        forSigningOutcome outcome: SigningOutcome,
        identity: StableSigningIdentity
    ) -> String {
        switch outcome {
        case .signed:
            return "signed with \(identity.codesignIdentityName) — macOS should keep this app's existing permissions"
        case .failed(let reason):
            return "\(adHocSigningSummary) (signing with \(identity.codesignIdentityName) failed: \(reason))"
        }
    }

    // MARK: - Packaging-metadata verification

    /// Check that the packaged artifact really carries the packaging metadata an
    /// edit claimed to add — an Info.plist key, an entitlement. This is the
    /// answer to packaging-metadata edits verifying as no-ops: the verification
    /// build is a COMPILE CHECK, and a plist key added to the wrong file (or
    /// misspelled, or added to a source template the packaging step overwrites)
    /// compiles perfectly. Empty array = every expectation held.
    ///
    /// Forwards to `IrisLocalSigningIdentity`, which owns the argv-invoked tool
    /// runner and the entitlements parsing this needs, so callers that already
    /// think in terms of packaging can reach it here.
    static func verifyPackagedMetadata(
        artifactPath: String,
        expectations: PackagingExpectations
    ) async -> [String] {
        await IrisLocalSigningIdentity.verifyPackagedMetadata(
            artifactPath: artifactPath, expectations: expectations
        )
    }

    // MARK: - Step 2: terminate the running instance, then launch the fresh build

    /// Terminate the currently running instance of `macBundleId` (if any) and
    /// launch the freshly built artifact from the clone. The order is fixed and
    /// load-bearing: terminate FIRST, wait for real exit, THEN launch — because
    /// opening an app that is already running only activates the stale process
    /// (the `openTheFreshlyInstalledApp` gap), and because launching the fresh
    /// build before the old one dies would leave two instances sharing one
    /// bundle id (adversarial #3b).
    ///
    /// `allowForceQuit` is false on the first attempt. If the app will not quit
    /// cleanly, this returns `.runningAppWouldNotQuit` WITHOUT killing it — the
    /// caller must obtain a second explicit consent and call again with
    /// `allowForceQuit: true`, which is the only path to `forceTerminate`.
    ///
    /// `macBundleId` is required and must be a REAL catalog bundle id — the
    /// caller only reaches here when the tri-state resolved to a known id, never
    /// a guessed one.
    func terminateRunningInstanceThenLaunchFreshBuild(
        macBundleId: String,
        freshBuildArtifactPath: String,
        allowForceQuit: Bool
    ) async -> AppRelaunchLaunchResult {
        let trimmedBundleId = macBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundleId.isEmpty else {
            return .ineligible(reason: "Iris doesn't have a bundle id for this app, so it won't guess one to relaunch")
        }
        let artifactURL = URL(fileURLWithPath: freshBuildArtifactPath)
        guard FileManager.default.fileExists(atPath: freshBuildArtifactPath) else {
            return .ineligible(reason: "the freshly built app is no longer on disk")
        }

        // Capture the running instance up front, by bundle id, ONCE — and from
        // here on operate on that exact handle, never re-looking-up by bundle id
        // (adversarial #3b: after the fresh build launches under the same id, a
        // re-lookup could resolve to either instance). Its own `bundleURL` is the
        // prior build we re-open if the fresh launch fails, so the user is never
        // left with nothing.
        let runningInstance = NSRunningApplication
            .runningApplications(withBundleIdentifier: trimmedBundleId).first
        let priorBundleURL = runningInstance?.bundleURL

        if let runningInstance {
            let quit = await terminateAndWaitForExit(runningInstance, allowForceQuit: allowForceQuit)
            switch quit {
            case .exited:
                break
            case .stillRunningNeedsForceConsent:
                // Do NOT force-kill through the unsaved-work dialog, and do NOT
                // launch a second instance. The old app is still up and unharmed.
                return .runningAppWouldNotQuit
            case .stillRunningAfterForce:
                // We were allowed to force and still couldn't kill it. The old
                // app is somehow still alive — launching the fresh build now
                // would collide on bundle id, so stand down and say so honestly.
                return .launchFailedPriorAppRestored(
                    reason: "Iris couldn't quit the running app, so it left it alone"
                )
            }
        }

        // The old instance is gone (or was never up). Launch the fresh build as
        // a distinct new instance straight from the clone's build output.
        if let launched = await WindowPositionManager
            .launchNewInstance(ofApplicationAt: artifactURL), !launched.isTerminated {
            return .relaunchedFreshBuild
        }

        // The fresh build did not start. Never leave the user with no app: put
        // back the prior build the old instance came from, if we know it.
        if let priorBundleURL {
            _ = await WindowPositionManager.launchNewInstance(ofApplicationAt: priorBundleURL)
        }
        return .launchFailedPriorAppRestored(
            reason: "the freshly built app didn't start, so Iris reopened your original copy"
        )
    }

    // MARK: - Terminate + wait mechanics

    private enum TerminationOutcome {
        case exited
        case stillRunningNeedsForceConsent
        case stillRunningAfterForce
    }

    /// Ask the app to quit, then poll for real exit up to `gracefulQuitTimeout`.
    /// On timeout: if forcing is not yet consented, report that a force consent
    /// is needed; if it IS consented, escalate to `forceTerminate` and poll once
    /// more. This mirrors the Ctrl-C-then-escalate shape the autopilot uses for a
    /// stuck shell, but applied — for the first time — to a foreign app.
    private func terminateAndWaitForExit(
        _ application: NSRunningApplication,
        allowForceQuit: Bool
    ) async -> TerminationOutcome {
        if application.isTerminated { return .exited }

        application.terminate()
        if await waitForExit(application, within: gracefulQuitTimeout) {
            return .exited
        }

        // It did not quit cleanly. Without an explicit force consent this is
        // where we stop — the caller asks the user before anything is killed.
        guard allowForceQuit else {
            return .stillRunningNeedsForceConsent
        }

        application.forceTerminate()
        if await waitForExit(application, within: gracefulQuitTimeout) {
            return .exited
        }
        return .stillRunningAfterForce
    }

    /// Poll the running application's `isTerminated` flag until it exits or the
    /// deadline passes. Polling (rather than KVO) keeps this a plain, testable
    /// loop with no observer lifetime to manage.
    private func waitForExit(
        _ application: NSRunningApplication,
        within timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if application.isTerminated { return true }
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s between checks
        }
        return application.isTerminated
    }

    // MARK: - Per-stack package commands (code-authored, never model-authored)

    /// The package command for a stack, resolved against this repo. Returns nil
    /// when the stack has no honest packaging command for this repo (an Electron
    /// repo with no recognized macOS packaging script), so the caller refuses
    /// rather than run something that can't produce a bundle.
    ///
    /// These strings are the design §4a recipes for the first slice; the Tauri
    /// workspace-layout ambiguity (`target/` vs `src-tauri/target/`) is resolved
    /// at the ARTIFACT-DISCOVERY step below by searching both, so the command
    /// itself stays layout-agnostic.
    private static func packageCommand(forStack stack: BreakAppStack, clonePath: String) -> String? {
        switch stack {
        case .tauri:
            // Produces target/.../bundle/macos/<Name>.app. The tauri CLI is
            // almost always a LOCAL devDependency (@tauri-apps/cli →
            // node_modules/.bin/tauri), not the global `cargo tauri` subcommand
            // — a real dogfood run (whimprflow, Aug 23 2026) failed packaging
            // with "no such command: tauri" because `cargo-tauri` was not
            // installed while the repo's own `ui/node_modules/.bin/tauri`
            // (used by its dev.sh) was right there. So prefer the repo's own
            // CLI and fall back to the global cargo subcommand only if no local
            // one exists.
            return tauriPackagingCommand(clonePath: clonePath)
        case .electron:
            // The repo's OWN packaging script — Iris never invents an
            // electron-builder/forge invocation, it runs the one the project
            // declares, in a conservative priority order.
            guard let script = electronPackagingScript(clonePath: clonePath) else { return nil }
            return "npm run \(script)"
        case .nextjs, .swiftMacOS, .other:
            return nil
        }
    }

    /// The best available `tauri build` invocation for THIS clone: a local
    /// `node_modules/.bin/tauri` (the common case — `@tauri-apps/cli` is a
    /// devDependency), else `npx --no-install tauri` when a package.json
    /// declares that CLI, else the global `cargo tauri` subcommand. Run from
    /// the clone root, where the CLI finds `src-tauri/tauri.conf.json` and its
    /// `beforeBuildCommand` builds the frontend first.
    static func tauriPackagingCommand(clonePath: String) -> String {
        let fileManager = FileManager.default
        // Local CLI bins, in the layouts Tauri projects actually use (root,
        // the frontend package, and the crate dir).
        for relativeBinPath in [
            "node_modules/.bin/tauri",
            "ui/node_modules/.bin/tauri",
            "app/node_modules/.bin/tauri",
            "frontend/node_modules/.bin/tauri",
            "src-tauri/node_modules/.bin/tauri",
        ] {
            let absoluteBinPath = (clonePath as NSString).appendingPathComponent(relativeBinPath)
            if fileManager.isExecutableFile(atPath: absoluteBinPath) {
                // Quote the relative path so a space in the clone path is safe;
                // run from the clone root (the runner's working directory).
                return "'\(relativeBinPath)' build"
            }
        }
        // A package.json that declares @tauri-apps/cli but whose node_modules
        // are not installed yet: npx --no-install resolves the local bin
        // without reaching the network (the jail is off for packaging, but we
        // still never want an implicit download).
        if declaresTauriCLIDependency(clonePath: clonePath) {
            return "npx --no-install tauri build"
        }
        // Last resort: the global cargo subcommand (works only if the user
        // installed tauri-cli with `cargo install`).
        return "cargo tauri build"
    }

    /// Whether any package.json in the usual spots lists `@tauri-apps/cli`.
    private static func declaresTauriCLIDependency(clonePath: String) -> Bool {
        for relativeManifest in ["package.json", "ui/package.json", "app/package.json", "frontend/package.json"] {
            let manifestPath = (clonePath as NSString).appendingPathComponent(relativeManifest)
            guard let data = FileManager.default.contents(atPath: manifestPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for field in ["dependencies", "devDependencies"] {
                if let deps = json[field] as? [String: Any], deps["@tauri-apps/cli"] != nil {
                    return true
                }
            }
        }
        return false
    }

    /// The first packaging script an Electron repo declares, in priority order.
    /// A repo that declares none has no macOS packaging step Iris recognizes.
    private static func electronPackagingScript(clonePath: String) -> String? {
        let packageJSONPath = (clonePath as NSString).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: packageJSONPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return nil }
        // Ordered most-specific-macOS first, then general packaging, then forge.
        for candidate in ["dist:mac", "build:mac", "package:mac", "dist", "package", "make"] {
            if scripts[candidate] != nil { return candidate }
        }
        return nil
    }

    // MARK: - Artifact discovery (assert a launchable bundle exists)

    /// The newest launchable `.app` this stack's build produces under the clone,
    /// requiring it to be at least as new as `producedAtOrAfter` so a stale
    /// bundle from an earlier build is never returned. A launchable bundle is a
    /// directory that actually contains `Contents/MacOS` — not just any `.app`
    /// name. Nil = no fresh, launchable bundle was found.
    private static func newestLaunchableAppBundle(
        forStack stack: BreakAppStack,
        clonePath: String,
        producedAtOrAfter: Date
    ) -> String? {
        let fileManager = FileManager.default
        let cloneAsNSString = clonePath as NSString

        // The conventional output directories per stack. Both Tauri workspace
        // layouts are searched, which is how the command stays layout-agnostic.
        let candidateBundleParentDirectories: [String]
        switch stack {
        case .tauri:
            candidateBundleParentDirectories = [
                "target/release/bundle/macos",
                "src-tauri/target/release/bundle/macos",
                "target/universal-apple-darwin/release/bundle/macos",
            ]
        case .electron:
            candidateBundleParentDirectories = [
                "dist/mac",
                "dist/mac-arm64",
                "dist/mac-universal",
                "out", // electron-forge nests one level deeper; handled below
            ]
        case .nextjs, .swiftMacOS, .other:
            return nil
        }

        var newestBundlePath: String?
        var newestModificationDate = Date.distantPast

        func considerAppBundle(atPath bundlePath: String) {
            // A launchable bundle really has an executables directory; a bare
            // `.app`-named folder does not count.
            let macOSDirectory = (bundlePath as NSString).appendingPathComponent("Contents/MacOS")
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: macOSDirectory, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return }
            let modificationDate = (try? fileManager.attributesOfItem(atPath: bundlePath)[.modificationDate] as? Date) ?? nil
            let effectiveDate = modificationDate ?? Date.distantPast
            // Only accept a bundle this build produced (or refreshed).
            guard effectiveDate >= producedAtOrAfter else { return }
            if effectiveDate >= newestModificationDate {
                newestModificationDate = effectiveDate
                newestBundlePath = bundlePath
            }
        }

        for relativeParent in candidateBundleParentDirectories {
            let parentDirectory = cloneAsNSString.appendingPathComponent(relativeParent)
            guard let entries = try? fileManager.contentsOfDirectory(atPath: parentDirectory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                considerAppBundle(atPath: (parentDirectory as NSString).appendingPathComponent(entry))
            }
            // electron-forge writes to out/<Name>-darwin-<arch>/<Name>.app, so
            // also look one directory deeper under `out`.
            if relativeParent == "out" {
                for entry in entries {
                    let nestedDirectory = (parentDirectory as NSString).appendingPathComponent(entry)
                    guard let nestedEntries = try? fileManager.contentsOfDirectory(atPath: nestedDirectory) else { continue }
                    for nested in nestedEntries where nested.hasSuffix(".app") {
                        considerAppBundle(atPath: (nestedDirectory as NSString).appendingPathComponent(nested))
                    }
                }
            }
        }
        return newestBundlePath
    }
}

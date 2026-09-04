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

    // MARK: - Working out what a clone actually is

    /// What a source clone looks like from outside, reduced to the few facts
    /// that decide its stack. Separated from the filesystem so the ruling is a
    /// pure function and can be tested against a real repository's shape
    /// without one existing.
    struct CloneStackEvidence: Equatable, Sendable {
        var packageJSONContents: String?
        var hasTauriConfig: Bool = false
        var hasElectronBuilderConfig: Bool = false
        var hasNextConfig: Bool = false
        var hasSwiftPackageOrXcodeProject: Bool = false
    }

    /// Which stack a clone is, from its own contents.
    ///
    /// This exists because the stack was a NINE-ENTRY HARDCODED TABLE keyed by
    /// catalog slug, and anything missing from it fell to `.other` — which
    /// `stackCanProduceARelaunchableMacArtifact` refuses. NitroAI was never in
    /// the table, so Iris edited its source twice, committed both times, and
    /// left the installed app byte-identical, reporting only that it "can't
    /// rebuild this kind of app yet". It is an Electron app; it always could.
    /// A curated table is still consulted first, but a slug it has never heard
    /// of now gets looked at rather than written off.
    ///
    /// Ordered, and the order carries the interesting case: NitroAI has BOTH a
    /// `src-tauri/` directory and electron-builder, because the Tauri shell was
    /// started and abandoned. What it SHIPS is Electron (`main` is
    /// `electron/main.mjs`, `dist:mac` runs electron-builder, and the only
    /// artifacts in `release/` are dmgs). So Electron evidence wins over a
    /// Tauri directory that may be vestigial — a packaging config and a
    /// declared dependency are stronger evidence than a directory existing.
    static func stackDerived(from evidence: CloneStackEvidence) -> BreakAppStack {
        let dependencies = dependencyNames(inPackageJSON: evidence.packageJSONContents)

        if evidence.hasElectronBuilderConfig
            || dependencies.contains("electron")
            || dependencies.contains("electron-builder") {
            return .electron
        }
        if evidence.hasTauriConfig || dependencies.contains("@tauri-apps/cli") {
            return .tauri
        }
        if evidence.hasNextConfig || dependencies.contains("next") {
            return .nextjs
        }
        if evidence.hasSwiftPackageOrXcodeProject {
            return .swiftMacOS
        }
        return .other
    }

    /// Every dependency named by a package.json, both kinds, as a set. Returns
    /// empty for anything unparseable — a malformed manifest is not evidence of
    /// a stack, and guessing from one is how the wrong packager gets run.
    static func dependencyNames(inPackageJSON contents: String?) -> Set<String> {
        guard let contents,
              let data = contents.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var names: Set<String> = []
        for key in ["dependencies", "devDependencies"] {
            guard let table = root[key] as? [String: Any] else { continue }
            names.formUnion(table.keys)
        }
        return names
    }

    /// Read the evidence off a clone on disk.
    static func cloneStackEvidence(
        atPath clonePath: String,
        fileManager: FileManager = .default
    ) -> CloneStackEvidence {
        func exists(_ relativePath: String) -> Bool {
            fileManager.fileExists(atPath: "\(clonePath)/\(relativePath)")
        }
        return CloneStackEvidence(
            packageJSONContents: try? String(
                contentsOfFile: "\(clonePath)/package.json", encoding: .utf8
            ),
            hasTauriConfig: exists("src-tauri/tauri.conf.json"),
            hasElectronBuilderConfig: ["electron-builder.cjs", "electron-builder.js",
                                       "electron-builder.json", "electron-builder.yml"]
                .contains(where: exists),
            hasNextConfig: ["next.config.js", "next.config.mjs", "next.config.ts"]
                .contains(where: exists),
            hasSwiftPackageOrXcodeProject: exists("Package.swift")
        )
    }

    /// The stack of the clone at `clonePath`, or `.other` when nothing there
    /// says.
    static func stackOfClone(
        atPath clonePath: String,
        fileManager: FileManager = .default
    ) -> BreakAppStack {
        stackDerived(from: cloneStackEvidence(atPath: clonePath, fileManager: fileManager))
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

        // THE ARTIFACT IRIS NEEDS IS THE `.app`, NEVER THE `.dmg` — so the fresh
        // `.app` is checked BEFORE the build's exit code, not after.
        //
        // A Tauri build makes the `.app` first and only THEN tries to wrap it in
        // a `.dmg`, and that DMG step (`bundle_dmg.sh`, which drives Finder over
        // AppleScript) routinely fails in an automated, headless context even
        // though the `.app` compiled and bundled cleanly. The old code guarded on
        // `build.succeeded` first, so a build that failed ONLY at the DMG step —
        // with a perfectly launchable `.app` already sitting in bundle/macos —
        // was reported as a packaging failure and the whole edit delivery
        // aborted. Reported (Publik Test 2, 2026-09-03, and again the same
        // session): "Iris couldn't build a runnable copy of WhimprFlow (the
        // packaging build failed: … bundle_dmg.sh)". Iris installs the `.app`
        // over the reader's copy and never touches the `.dmg`, so a DMG failure
        // must not block a delivery whose real artifact was produced.
        //
        // This is safe against delivering broken code: a genuine compile failure
        // stops the build BEFORE the `.app` is bundled, so no FRESH `.app`
        // (mtime ≥ buildStartedAt) appears and the verdict falls through to the
        // honest failure. The only way a fresh `.app` exists is that compilation
        // AND `.app` bundling both succeeded and only a later packaging step
        // (the `.dmg`) failed. The rule lives in a pure function so it is tested
        // without spawning `cargo tauri build`.
        switch Self.packagingVerdict(
            freshLaunchableAppBundlePath: Self.newestLaunchableAppBundle(
                forStack: appStack, clonePath: clonePath, producedAtOrAfter: buildStartedAt
            ),
            buildSucceeded: build?.succeeded == true,
            buildOutputTail: build?.outputTail ?? ""
        ) {
        case .deliverTheFreshApp(let artifactPath):
            let signingSummary = await signFreshArtifactWithAStableIdentityIfAvailable(
                artifactPath: artifactPath
            )
            return .artifactReady(artifactPath: artifactPath, signingSummary: signingSummary)
        case .noLaunchableApp(let reason):
            return .packagingFailed(reason: reason)
        }
    }

    /// What a packaging build's result means, decided by the ARTIFACT and not by
    /// the build's exit code. Pure, so the "a `.dmg` failure with a good `.app`
    /// still delivers" rule can be tested without a real `cargo tauri build`.
    enum PackagingVerdict: Equatable {
        /// A fresh, launchable `.app` exists — deliver it, whatever the build's
        /// overall exit code was.
        case deliverTheFreshApp(artifactPath: String)
        /// No launchable `.app` was produced. Carries the honest reason.
        case noLaunchableApp(reason: String)
    }

    /// The `.app` wins over the exit code. A Tauri build bundles the `.app`
    /// before it tries the `.dmg`, and the `.dmg` step fails on its own in an
    /// automated context — so a fresh `.app` means success even when the build as
    /// a whole reported failure (Publik Test 2's "packaging build failed:
    /// bundle_dmg.sh"). Only when NO fresh `.app` was produced does the exit code
    /// matter, and then its output tail is the useful diagnostic.
    static func packagingVerdict(
        freshLaunchableAppBundlePath: String?,
        buildSucceeded: Bool,
        buildOutputTail: String
    ) -> PackagingVerdict {
        if let artifactPath = freshLaunchableAppBundlePath {
            return .deliverTheFreshApp(artifactPath: artifactPath)
        }
        if buildSucceeded {
            return .noLaunchableApp(
                reason: "the build finished but Iris couldn't find a launchable app it produced"
            )
        }
        let tail = buildOutputTail.suffix(400).trimmingCharacters(in: .whitespacesAndNewlines)
        return .noLaunchableApp(
            reason: tail.isEmpty ? "the packaging build failed" : "the packaging build failed: \(tail)"
        )
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

    // MARK: - Step 2b: deliver the fresh build OVER the installed app

    /// The outcome of trying to replace the reader's INSTALLED copy of an app
    /// with the freshly built one. This is the founder's Sep 2 2026 override of
    /// the original Option-A design (this file's header): after a green build,
    /// the app the reader actually opens should carry the change — not a
    /// parallel copy left in the clone's build dir that they have to be told to
    /// open by an absolute path. When there is no separate installed copy to
    /// replace, this reports so honestly and the caller falls back to launching
    /// the build-dir artifact, exactly as before.
    enum InstalledDeliveryResult: Sendable, Equatable {
        /// The installed bundle at `installedPath` now holds the fresh build.
        /// The bundle that was there was snapshotted to `backupPath` FIRST, so
        /// the delivery is undoable by restoring it. `grantsMayReset` is true
        /// when the fresh build's signing identity differs from the installed
        /// copy's (or either is unsigned/ad-hoc), so macOS may treat it as a
        /// different app and reset its TCC grants — disclosed, never hidden.
        case replacedInstalledApp(installedPath: String, backupPath: String, grantsMayReset: Bool)
        /// No installed copy of this bundle id exists apart from the clone's own
        /// build output, so there is nothing to replace. Not an error — the
        /// caller launches the build-dir artifact as it always did.
        case noInstalledCopyToReplace
        /// An installed copy exists but replacing it failed (an unwritable
        /// /Applications, a copy or swap error). Nothing was left half-installed
        /// — the installed app is intact — and the caller falls back to the
        /// build-dir artifact.
        case deliveryFailed(reason: String)
    }

    /// Replace the installed copy of `macBundleId` with the freshly built
    /// artifact. The installed copy is found by bundle id, EXCLUDING anything
    /// inside `clonePath` (the build output is not "the installed app"), and
    /// preferring /Applications. The swap is atomic: the current bundle is
    /// snapshotted for undo, the fresh build is staged beside the installed app,
    /// and `FileManager.replaceItemAt` moves it into place — so a failure leaves
    /// the installed app exactly as it was.
    func installFreshBuildOverInstalledApp(
        macBundleId: String,
        freshBuildArtifactPath: String,
        clonePath: String
    ) async -> InstalledDeliveryResult {
        let bundleId = macBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleId.isEmpty,
              FileManager.default.fileExists(atPath: freshBuildArtifactPath) else {
            return .deliveryFailed(reason: "the freshly built app is not on disk to install")
        }
        let appBundleName = URL(fileURLWithPath: freshBuildArtifactPath).lastPathComponent
        guard let installedPath = Self.installedAppPath(
            forBundleId: bundleId, appBundleName: appBundleName, excludingClonePath: clonePath
        ) else {
            return .noInstalledCopyToReplace
        }
        // Read both signing identities BEFORE the swap, so the disclosure is
        // about the app being replaced rather than the one that replaced it.
        let freshTeam = await Self.developerTeamIdentifier(atPath: freshBuildArtifactPath)
        let installedTeam = await Self.developerTeamIdentifier(atPath: installedPath)
        let grantsMayReset = freshTeam == nil || installedTeam == nil || freshTeam != installedTeam

        let backupPath = Self.deliveryBackupPath(forBundleId: bundleId, appBundleName: appBundleName)
        let swap = await Task.detached(priority: .userInitiated) {
            Self.atomicallyReplaceBundle(
                installedPath: installedPath,
                withBundleAt: freshBuildArtifactPath,
                snapshotTo: backupPath
            )
        }.value
        switch swap {
        case .success:
            return .replacedInstalledApp(
                installedPath: installedPath, backupPath: backupPath, grantsMayReset: grantsMayReset
            )
        case .failure(let reason):
            return .deliveryFailed(reason: reason)
        }
    }

    /// Put the pre-delivery installed bundle back (used by undo). Best-effort and
    /// atomic where it can be: the backup is staged beside the installed app and
    /// moved into place. Returns whether the installed app is once again the
    /// original.
    func restoreInstalledAppFromBackup(installedPath: String, backupPath: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: backupPath) else { return false }
        return await Task.detached(priority: .userInitiated) {
            Self.atomicallyReplaceBundle(
                installedPath: installedPath,
                withBundleAt: backupPath,
                snapshotTo: nil
            ).isSuccess
        }.value
    }

    // MARK: - Delivery helpers (nonisolated: pure filesystem + argv tool work)

    /// The installed copy of `bundleId` to replace, or nil when the only copy is
    /// the clone's own build output. Considers Launch Services' registered copy
    /// and `/Applications/<Name>.app` on disk, both filtered so nothing inside
    /// `clonePath` is ever returned, and prefers a copy in /Applications.
    nonisolated static func installedAppPath(
        forBundleId bundleId: String,
        appBundleName: String,
        excludingClonePath clonePath: String
    ) -> String? {
        let registered = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleId)?.path
        let applicationsCopy = "/Applications/\(appBundleName)"
        let applicationsPath = FileManager.default.fileExists(atPath: applicationsCopy)
            ? applicationsCopy : nil
        return chooseInstalledBundlePath(
            registeredPath: registered, applicationsPath: applicationsPath, clonePath: clonePath
        )
    }

    /// Pure: pick which candidate is "the installed app" to replace. Anything
    /// inside `clonePath` (the build output) is excluded; a copy under
    /// /Applications wins over any other registered location. nil when no
    /// candidate survives — the caller then leaves the installed side untouched.
    nonisolated static func chooseInstalledBundlePath(
        registeredPath: String?,
        applicationsPath: String?,
        clonePath: String
    ) -> String? {
        let clonePrefix = clonePath.hasSuffix("/") ? clonePath : clonePath + "/"
        func outsideClone(_ path: String) -> Bool {
            !clonePath.isEmpty ? (path != clonePath && !path.hasPrefix(clonePrefix)) : true
        }
        var candidates: [String] = []
        if let registeredPath, outsideClone(registeredPath) { candidates.append(registeredPath) }
        if let applicationsPath, outsideClone(applicationsPath), !candidates.contains(applicationsPath) {
            candidates.append(applicationsPath)
        }
        return candidates.first { $0.hasPrefix("/Applications/") } ?? candidates.first
    }

    /// Where a pre-delivery snapshot of an installed bundle is kept so a delivery
    /// can be undone. One slot per bundle id under Application Support, replaced
    /// each delivery — only the most recent delivery is undoable, which matches
    /// the single "Undo this change" affordance the card shows.
    nonisolated static func deliveryBackupPath(forBundleId bundleId: String, appBundleName: String) -> String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        let safeId = bundleId.replacingOccurrences(of: "/", with: "_")
        return base
            .appendingPathComponent("Iris/edit-delivery-backups/\(safeId)")
            .appendingPathComponent(appBundleName)
            .path
    }

    // Not private so the live filesystem round-trip test can drive the real
    // swap on real (temp) bundles — this is the one genuinely-unverified,
    // corruption-risking primitive, so it earns direct coverage.
    nonisolated enum BundleSwapOutcome: Sendable, Equatable {
        case success
        case failure(reason: String)
        var isSuccess: Bool { if case .success = self { return true } else { return false } }
    }

    /// Snapshot the current installed bundle to `snapshotPath` (when given),
    /// `ditto` the replacement beside the installed app, then atomically move it
    /// into place with `FileManager.replaceItemAt`. `ditto` (not a plain copy)
    /// preserves the code signature and extended attributes. Blocking — call off
    /// the main actor. The installed app is left intact on any failure.
    nonisolated static func atomicallyReplaceBundle(
        installedPath: String,
        withBundleAt source: String,
        snapshotTo snapshotPath: String?
    ) -> BundleSwapOutcome {
        let fileManager = FileManager.default
        let installedURL = URL(fileURLWithPath: installedPath)
        let installedDirectory = installedURL.deletingLastPathComponent()
        let bundleName = installedURL.lastPathComponent

        // 1. Snapshot the current installed bundle for undo.
        if let snapshotPath {
            let snapshotURL = URL(fileURLWithPath: snapshotPath)
            try? fileManager.createDirectory(
                at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: snapshotURL)
            guard dittoBundle(from: installedPath, to: snapshotPath) else {
                return .failure(reason: "couldn't snapshot the installed app before replacing it")
            }
        }

        // 2. Stage the replacement beside the installed app (same volume, so the
        //    swap is atomic), then move it into place. A leftover stage from a
        //    prior interrupted run is cleared first.
        let stagingURL = installedDirectory.appendingPathComponent(".iris-delivery-\(bundleName)")
        try? fileManager.removeItem(at: stagingURL)
        guard dittoBundle(from: source, to: stagingURL.path) else {
            return .failure(reason: "couldn't stage the build next to the installed app")
        }
        do {
            _ = try fileManager.replaceItemAt(installedURL, withItemAt: stagingURL)
            return .success
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            return .failure(reason: "couldn't move the build into place: \(error.localizedDescription)")
        }
    }

    /// Copy an app bundle with `ditto`, which preserves the code signature and
    /// extended attributes a plain file copy can drop. Returns success.
    nonisolated private static func dittoBundle(from source: String, to destination: String) -> Bool {
        runArgvTool(executablePath: "/usr/bin/ditto", arguments: [source, destination]).succeeded
    }

    /// The Developer Team identifier a bundle is signed with, or nil when it is
    /// unsigned / ad-hoc / unreadable. Used ONLY to disclose whether a delivery
    /// may reset TCC grants — never to gate the delivery itself.
    nonisolated static func developerTeamIdentifier(atPath path: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let result = runArgvTool(
                executablePath: "/usr/bin/codesign", arguments: ["-dvvv", path]
            )
            guard result.succeeded else { return nil }
            for line in result.output.components(separatedBy: .newlines) {
                guard let range = line.range(of: "TeamIdentifier=") else { continue }
                let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                return (value.isEmpty || value == "not set") ? nil : value
            }
            return nil
        }.value
    }

    /// Launch one tool by absolute path with an argument array — no shell, so
    /// nothing in an argument is reinterpreted as a command. Drains stdout+stderr
    /// as the process runs (readDataToEndOfFile), so it can't deadlock on a full
    /// pipe. Blocking; call off the main actor.
    nonisolated private static func runArgvTool(
        executablePath: String, arguments: [String]
    ) -> (succeeded: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (false, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
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
    /// Test-only passthrough. `packageCommand` stays private — which stacks Iris
    /// can package is an internal decision — but whether a stack is packageable
    /// is exactly what decides if the blocked card may offer a rebuild, so it
    /// needs to be assertable.
    static func packageCommandForTesting(forStack stack: BreakAppStack, clonePath: String) -> String? {
        packageCommand(forStack: stack, clonePath: clonePath)
    }

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

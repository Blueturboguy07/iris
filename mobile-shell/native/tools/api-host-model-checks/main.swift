import CryptoKit
import Foundation

/// Source-linked Host-state acceptance. No WKWebView is instantiated: the real
/// model, Core coordinator, signature verifier and installation store run, while
/// the OS availability constant is the explicit supported-platform test input.
@main
@MainActor
struct APIHostModelChecks {
    static var count = 0

    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw CheckFailure("repository path required") }
            let repository = URL(fileURLWithPath: CommandLine.arguments[1])
            let base = repository.appendingPathComponent("outputs/iris_kneecap_user_test_20260916/seamless_mobile_20260918/resumed_20260918/core-acceptance/api-install-binding-20260919/host-state-fixtures")
            let root = base.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let resources = repository.appendingPathComponent("mobile-shell/native/IrisMobileShellApp/Resources")
            let initial = try Data(contentsOf: resources.appendingPathComponent("SafeDemo.irisapp"))
            let update = try Data(contentsOf: resources.appendingPathComponent("SafeDemoUpdate.irisapp"))
            try await approvedInstallAndExistingOpen(root: root.appendingPathComponent("install"), initial: initial)
            try await failureAndExplicitRetry(root: root.appendingPathComponent("retry"), initial: initial, update: update)
            try await oldSetupDoesNotRevive(root: root.appendingPathComponent("no-revive"), initial: initial, update: update)
            try await verifiedFallbackSurvivesHistoryFailure(root: root.appendingPathComponent("fallback-allowed"), initial: initial, update: update, revoked: false)
            try await verifiedFallbackSurvivesHistoryFailure(root: root.appendingPathComponent("fallback-refused"), initial: initial, update: update, revoked: true)
            try await retryAfterActivatedContentRecheckFailure(root: root.appendingPathComponent("activation-retry"), initial: initial)
            print("Host API installation state: \(count)/\(count) checks passed against actual model/Core sources. No WebKit, simulator, native app, provider or network execution.")
        } catch {
            print("Host API installation state FAILED: \(error)")
            exit(1)
        }
    }

    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        count += 1
        guard try value() else { throw CheckFailure(label) }
    }

    static func wait(_ label: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard condition() else { throw CheckFailure("timed out: " + label) }
    }

    static func approve(_ model: NativeShellAppModel) async throws -> NativeShellPackageReview {
        model.reviewBundledDemo()
        try await wait("package review") { model.review != nil || model.errorMessage != nil }
        guard let review = model.review else { throw CheckFailure(model.errorMessage ?? "review missing") }
        model.approveLocallyAndOpen(review: review)
        model.reviewSheetDidClose()
        try await wait("installation settled") { !model.isInstalling }
        return review
    }

    static func seed(_ bytes: Data, coordinator: NativeShellLibraryCoordinator) async throws -> NativeShellLaunchOutcome {
        let review = try await coordinator.reviewImport(packageBytes: bytes)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(reviewToken: review.reviewToken, packageSHA256: review.packageSHA256)
        try await coordinator.activate(identity: review.identity, revisionId: review.revisionId)
        return try await coordinator.launchActive(identity: review.identity)
    }

    static func approvedInstallAndExistingOpen(root: URL, initial: Data) async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("apps"))
        let signer = SignedAPITestFixture()
        let store = try NativePackagedAPIInstallationStore(rootURL: root.appendingPathComponent("api"), verifier: signer.verifier())
        var preparationCalls = 0
        var resolverCalls = 0
        let model = NativeShellAppModel(coordinator: coordinator, bundledDemoPackage: initial,
            preparePackagedAPIForLaunch: { launch in
                preparationCalls += 1
                guard let identity = launch.identity else { throw CheckFailure("identity missing") }
                _ = try store.install(signer.package(identity: identity, revision: launch.revisionId), for: launch)
            },
            packagedAPIAdapterForLaunch: { launch in
                resolverCalls += 1
                return store.adapterConfiguration(for: launch)
            })
        try check(preparationCalls == 0 && resolverCalls == 0, "constructor must not install or resolve an API")
        model.reviewBundledDemo()
        try await wait("review appears") { model.review != nil }
        try check(preparationCalls == 0, "review is not API installation permission")
        guard let review = model.review else { throw CheckFailure("review missing") }
        model.approveLocallyAndOpen(review: review)
        // Deliberately wait before the review sheet's dismissal callback.
        try await wait("staging before sheet dismissal") { !model.isInstalling }
        try check(model.launch == nil && preparationCalls == 0, "no API or app presentation before review sheet is dismissed")
        model.reviewSheetDidClose()
        guard let outcome = model.launch else { throw CheckFailure(model.errorMessage ?? "approved launch missing") }
        try check(preparationCalls == 1 && resolverCalls == 1, "approved install resolves exactly once")
        guard case .verifiedBundle(let installed) = model.launchPackagedAPIAdapter else { throw CheckFailure("signed API not selected") }
        try check(installed.revisionId == outcome.launchedRevisionId, "API matches approved content")
        try check(try store.installed(for: outcome.launch) == installed, "signed binding persisted")
        model.refresh()
        try await wait("library refresh") { !model.library.isEmpty }
        try check(preparationCalls == 1 && resolverCalls == 1, "refresh does not change the live API snapshot")
        model.closeApp(); model.appSheetDidClose()
        try check(model.launchPackagedAPIAdapter == .notConfigured, "closed presentation releases API snapshot")
        let reopenedStore = try NativePackagedAPIInstallationStore(rootURL: root.appendingPathComponent("api"), verifier: signer.verifier())
        let reopened = NativeShellAppModel(coordinator: coordinator,
            preparePackagedAPIForLaunch: { _ in preparationCalls += 1 },
            packagedAPIAdapterForLaunch: reopenedStore.adapterConfiguration)
        reopened.open(identity: outcome.identity)
        try await wait("ordinary reopen") { reopened.launch != nil || reopened.errorMessage != nil }
        try check(reopened.launchPackagedAPIAdapter == .verifiedBundle(installed), "fresh model re-verifies durable binding")
        try check(preparationCalls == 1, "ordinary reopen is resolver-only")
        reopened.closeApp(); reopened.appSheetDidClose()
        let revokedStore = try NativePackagedAPIInstallationStore(rootURL: root.appendingPathComponent("api"), verifier: NativePackagedAPIVerifier())
        let revoked = NativeShellAppModel(coordinator: coordinator, packagedAPIAdapterForLaunch: revokedStore.adapterConfiguration)
        revoked.open(identity: outcome.identity)
        try await wait("revoked key rejection") { revoked.errorMessage != nil }
        try check(revoked.launch == nil, "revoked key must prevent opening rather than silently drop the API")
        try check(revoked.retryAction == .open(outcome.identity), "API rejection exposes a real open retry")
        let after = try await coordinator.libraryEntry(identity: outcome.identity)
        try check(after?.currentRevisionId == outcome.launchedRevisionId, "revocation leaves content selection intact")

        // An independently installed, unconfigured app must not gain its first
        // adapter from a prepare callback on an ordinary Open or same-revision import.
        let plainCoordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("plain-apps"))
        let plain = try await seed(initial, coordinator: plainCoordinator)
        var unauthorizedPrepares = 0
        let ordinary = NativeShellAppModel(coordinator: plainCoordinator, bundledDemoPackage: initial,
            preparePackagedAPIForLaunch: { _ in unauthorizedPrepares += 1 })
        ordinary.open(identity: plain.identity)
        try await wait("unconfigured ordinary open") { ordinary.launch != nil }
        try check(unauthorizedPrepares == 0 && ordinary.launchPackagedAPIAdapter == .notConfigured, "ordinary open cannot grant a first API")
        ordinary.closeApp(); ordinary.appSheetDidClose()
        _ = try await approve(ordinary)
        try check(ordinary.launch != nil && unauthorizedPrepares == 0, "same-revision import fast path cannot grant a first API")
        ordinary.closeApp(); ordinary.appSheetDidClose()
    }

    static func failureAndExplicitRetry(root: URL, initial: Data, update: Data) async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("apps"))
        let old = try await seed(initial, coordinator: coordinator)
        let signer = SignedAPITestFixture()
        let store = try NativePackagedAPIInstallationStore(rootURL: root.appendingPathComponent("api"), verifier: signer.verifier())
        let data = try await coordinator.readerDataDirectory(identity: old.identity, namespace: "iris.synthetic.api-state")
        let note = data.appendingPathComponent("synthetic-note")
        try Data("preserve".utf8).write(to: note)
        var attempts = 0
        var fail = true
        let model = NativeShellAppModel(coordinator: coordinator, bundledDemoPackage: update,
            preparePackagedAPIForLaunch: { launch in
                attempts += 1
                if fail { throw NativePackagedAPIError.invalidSignature }
                _ = try store.install(signer.package(identity: old.identity, revision: launch.revisionId), for: launch)
            }, packagedAPIAdapterForLaunch: store.adapterConfiguration)
        let review = try await approve(model)
        try check(model.launch == nil && attempts == 1, "failed setup never publishes the app")
        try check(model.errorMessage?.contains("app is installed") == true, "post-activation failure is described truthfully")
        try check(model.retryAction == .open(old.identity), "Retry is the real open action")
        let installed = try await coordinator.libraryEntry(identity: old.identity)
        try check(installed?.currentRevisionId == review.revisionId && installed?.revisions.count == 2, "failed API setup retains installed update and history")
        try check(try String(contentsOf: note, encoding: .utf8) == "preserve", "reader data retained after failure")
        fail = false
        model.retry()
        try await wait("explicit API retry") { model.launch != nil || model.errorMessage != nil }
        try check(model.launch?.launchedRevisionId == review.revisionId && attempts == 2, "Retry completes the exact approved setup")
        guard let launch = model.launch else { throw CheckFailure("retry launch missing") }
        try check(try store.installed(for: launch.launch) != nil, "retried API is durable")
        try check(try String(contentsOf: note, encoding: .utf8) == "preserve", "reader data retained after retry")
        model.closeApp(); model.appSheetDidClose()
    }

    static func verifiedFallbackSurvivesHistoryFailure(root: URL, initial: Data, update: Data, revoked: Bool) async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("apps"))
        let first = try await seed(initial, coordinator: coordinator)
        let signer = SignedAPITestFixture()
        let apiRoot = root.appendingPathComponent("api")
        let installer = try NativePackagedAPIInstallationStore(rootURL: apiRoot, verifier: signer.verifier())
        let installed = try installer.install(signer.package(identity: first.identity, revision: first.launchedRevisionId), for: first.launch)
        let second = try await seed(update, coordinator: coordinator)
        let originalFirstBytes = try Data(contentsOf: first.launch.entrypointURL)
        let corruptedSecondBytes = Data("owned synthetic corrupt active revision".utf8)
        try corruptedSecondBytes.write(to: second.launch.entrypointURL)
        let resolver = try NativePackagedAPIInstallationStore(rootURL: apiRoot,
            verifier: revoked ? NativePackagedAPIVerifier() : signer.verifier())
        var preparationCalls = 0
        var resolverCalls = 0
        let model = NativeShellAppModel(coordinator: coordinator,
            preparePackagedAPIForLaunch: { _ in preparationCalls += 1 },
            packagedAPIAdapterForLaunch: { launch in
                resolverCalls += 1
                return resolver.adapterConfiguration(for: launch)
            })
        model.open(identity: first.identity)
        try await wait("fallback presentation or API refusal") { model.launch != nil || model.errorMessage != nil }
        try check(resolverCalls == 1, "unusable history must not prevent validation of the independently verified fallback API")
        try check(preparationCalls == 0, "fallback is resolver-only, never a new API installation grant")
        if revoked {
            try check(model.launch == nil, "a rejected fallback API must leave the app unopened")
            try check(model.errorMessage?.contains("packaged API") == true, "the actual fallback API rejection must remain visible")
            try check(model.notice == nil, "API refusal must not be overwritten by a false fallback-open success message")
            try check(model.retryAction == .open(first.identity), "fallback API rejection retains the actual Retry action")
        } else {
            try check(model.launch?.launchedRevisionId == first.launchedRevisionId && model.launch?.didFallback == true,
                      "a verified fallback must open even if another stored revision makes history refresh fail")
            try check(model.launchPackagedAPIAdapter == .verifiedBundle(installed), "fallback selects its own verified API")
            try check(model.notice?.contains("history") == true, "the incomplete history verification must be disclosed")
            try check(model.errorMessage == nil, "history warning must not replace a successful verified fallback with a failed open")
            model.closeApp(); model.appSheetDidClose()
        }
        try check(try Data(contentsOf: first.launch.entrypointURL) == originalFirstBytes, "fallback content is unchanged")
        try check(try Data(contentsOf: second.launch.entrypointURL) == corruptedSecondBytes, "failed history is not silently deleted to permit fallback")
    }

    static func retryAfterActivatedContentRecheckFailure(root: URL, initial: Data) async throws {
        let inspection = try DeliveryPackageV1Validator().inspect(packageBytes: initial)
        let identity = NativeShellAppIdentity(appId: inspection.appId, projectId: inspection.projectId)
        let appRoot = root.appendingPathComponent("apps")
        let files = TransientPostActivationReadFailure(root: appRoot, identity: identity)
        let coordinator = NativeShellLibraryCoordinator(rootURL: appRoot, fileManager: files)
        let signer = SignedAPITestFixture()
        let store = try NativePackagedAPIInstallationStore(rootURL: root.appendingPathComponent("api"), verifier: signer.verifier())
        var preparationCalls = 0
        let model = NativeShellAppModel(coordinator: coordinator, bundledDemoPackage: initial,
            preparePackagedAPIForLaunch: { launch in
                preparationCalls += 1
                _ = try store.install(signer.package(identity: identity, revision: launch.revisionId), for: launch)
            }, packagedAPIAdapterForLaunch: store.adapterConfiguration)
        let review = try await approve(model)
        try check(files.failuresInjected == 1, "the failure must occur at a real file read after activation")
        try check(model.launch == nil && preparationCalls == 0, "failed Core recheck must not execute API or publish an app")
        try check(model.errorMessage?.contains("app was installed") == true, "content activation is not misreported as a rollback")
        let before = try await coordinator.libraryEntry(identity: identity)
        try check(before?.currentRevisionId == review.revisionId && before?.revisions.count == 1, "activated content/history remain intact")
        let pointerBytes = try Data(contentsOf: files.activePointerURL)
        model.retry()
        try await wait("Retry open or refresh completed") { model.launch != nil || model.errorMessage != nil || !model.library.isEmpty }
        try check(model.launch?.launchedRevisionId == review.revisionId, "Retry after activated-content recheck failure must actually open, not only refresh history")
        try check(preparationCalls == 1, "Retry must finish the exact approved API setup once after the Core recheck succeeds")
        guard let launch = model.launch else { throw CheckFailure("Retry launch missing") }
        try check(try store.installed(for: launch.launch) != nil, "approved API setup was recorded after retry")
        try check(try Data(contentsOf: files.activePointerURL) == pointerBytes, "open retry must not restage or move the active revision")
        model.closeApp(); model.appSheetDidClose()
    }

    static func oldSetupDoesNotRevive(root: URL, initial: Data, update: Data) async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("apps"))
        let old = try await seed(initial, coordinator: coordinator)
        let signer = SignedAPITestFixture()
        let store = try NativePackagedAPIInstallationStore(rootURL: root.appendingPathComponent("api"), verifier: signer.verifier())
        var attempts = 0
        var fail = true
        let model = NativeShellAppModel(coordinator: coordinator, bundledDemoPackage: update,
            preparePackagedAPIForLaunch: { launch in
                attempts += 1
                if fail { throw NativePackagedAPIError.invalidSignature }
                _ = try store.install(signer.package(identity: old.identity, revision: launch.revisionId), for: launch)
            }, packagedAPIAdapterForLaunch: store.adapterConfiguration)
        let updated = try await approve(model)
        try check(model.launch == nil && attempts == 1, "new retry capability starts with a failed approved setup")
        model.revert(identity: old.identity, revisionId: old.launchedRevisionId)
        try await wait("revert") { model.library.first?.currentRevisionId == old.launchedRevisionId }
        model.activate(identity: old.identity, revisionId: updated.revisionId)
        try await wait("restore newer revision") { model.library.first?.currentRevisionId == updated.revisionId }
        fail = false
        model.open(identity: old.identity)
        try await wait("ordinary open after revision switches") { model.launch != nil || model.errorMessage != nil }
        try check(attempts == 1, "revision switches invalidate the old setup capability")
        try check(model.launchPackagedAPIAdapter == .notConfigured, "ordinary open remains unconfigured")
        guard let launch = model.launch else { throw CheckFailure("ordinary content open missing") }
        try check(try store.installed(for: launch.launch) == nil, "no silent first binding after intervening actions")
        try check(model.library.first?.revisions.count == 2, "both content revisions remain in history")
        model.closeApp(); model.appSheetDidClose()
    }
}

private struct CheckFailure: Error { let message: String; init(_ message: String) { self.message = message } }

private final class TransientPostActivationReadFailure: FileManager, @unchecked Sendable {
    let activePointerURL: URL
    private let contentPrefix: String
    private let stateLock = NSLock()
    private var injected = false
    var failuresInjected: Int { stateLock.withLock { injected ? 1 : 0 } }

    init(root: URL, identity: NativeShellAppIdentity) {
        activePointerURL = root.appendingPathComponent("state/\(identity.appId)/\(identity.projectId)/active.json")
        contentPrefix = root.appendingPathComponent("content/\(identity.appId)/\(identity.projectId)/revisions").path + "/"
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let atActivatedContent = path.hasPrefix(contentPrefix) && path.hasSuffix("/content/index.html")
            && FileManager.default.fileExists(atPath: activePointerURL.path)
        let fail = stateLock.withLock { () -> Bool in
            guard atActivatedContent, !injected else { return false }
            injected = true
            return true
        }
        if fail { throw NSError(domain: "IrisSyntheticPostActivationRead", code: 1) }
        return try super.attributesOfItem(atPath: path)
    }
}

import Foundation

// Round 6, unit R6-mobile-prep-B (route G8), MA2 hook 5: the package generator
// and library seeder behind the DEBUG launch argument
// `--iris-ui-test-my-apps <n>` (SPEC 5.6). The whole file compiles only in
// DEBUG builds, so a Release build has no generator, no fixture names and no
// seeding entry point (release-hygiene.sh and the Release compile check that).
//
// What it does: builds n tiny, REAL `iris.mobile-shell.package+json` packages
// (the same envelope the desktop CLI writes: canonical content hash, revision
// id, embedded approval) and installs them through the real
// `NativeShellLibraryCoordinator` (review, local approval, stage, activate), so
// My apps has n genuine installed apps to organise: real display names, real
// library entries, real storage rows. Nothing here talks to the network.
#if DEBUG

public enum MyAppsUITestSeed {
    /// The first names people see. Chosen so the SPEC 5.6 search case ("cl")
    /// matches a handful of apps and not all of them. Apps beyond this list
    /// are "Fixture App <n>".
    public static let leadingNames: [String] = [
        "Clock Studio", "Clipboard", "Cloud Notes", "Clover Garden",
        "Budget Buddy", "Recipe Box", "Daily Journal", "Kitchen Timer",
        "Habit Tracker", "Trail Maps", "Photo Frames", "Study Music",
    ]

    /// Highest count the launch argument may ask for (SPEC 5.6 uses 12, 100, 1,000).
    public static let maximumCount = 2_000

    /// `--iris-ui-test-my-apps <n>`: two tokens, like the other fixture flags.
    public static let launchArgumentFlag = "--iris-ui-test-my-apps"

    /// The count the launch asked for, or nil when the flag is absent or its
    /// value is not a whole number from 1 to `maximumCount`. A bad value falls
    /// through to a normal launch (a test-setup mistake should show up as a
    /// missing fixture, not as a silently different one).
    public static func requestedCount(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int? {
        guard let flag = arguments.firstIndex(of: launchArgumentFlag) else { return nil }
        let next = arguments.index(after: flag)
        guard next < arguments.count, let value = Int(arguments[next]), (1...maximumCount).contains(value) else { return nil }
        return value
    }

    /// The isolated Application Support folder name for this count, so the
    /// fixture library never mixes with a real one or another fixture's.
    public static func storageNamespace(
        forCount count: Int,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String {
        guard let token = fixtureSessionToken(arguments: arguments) else { return "ui-test-my-apps-\(count)" }
        return "ui-test-session-\(token)-my-apps-\(count)"
    }

    /// A session is opt-in and accepts only 8...40 ASCII lowercase letters,
    /// digits or hyphens. Missing pairs preserve legacy namespaces; an invalid
    /// pair fails loudly in DEBUG so fixture state cannot leak into that namespace.
    public static func fixtureSessionToken(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let flag = arguments.firstIndex(of: "--iris-ui-test-session") else { return nil }
        precondition(flag + 1 < arguments.count, "--iris-ui-test-session requires a valid token.")
        let token = arguments[flag + 1]
        precondition(
            (8...40).contains(token.utf8.count)
                && token.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
            "--iris-ui-test-session token must contain 8 to 40 lowercase ASCII letters, digits, or hyphens."
        )
        return token
    }

    /// Call before seeding, with the coordinator's namespace root.
    /// The only removable sibling prefixes are exactly:
    /// ui-test-session-
    /// usage-ui-test-session-
    /// permissions-ui-test-session-
    /// Legacy fixtures and normal/acceptance libraries are never selected.
    public static func sweepStaleSessions(
        namespaceRoot: URL,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws {
        guard let token = fixtureSessionToken(arguments: arguments), namespaceRoot.isFileURL else { return }
        let currentPrefix = "ui-test-session-\(token)-"
        guard namespaceRoot.lastPathComponent.hasPrefix(currentPrefix) else { return }
        let parent = namespaceRoot.deletingLastPathComponent()
        guard parent.lastPathComponent == "IrisMobileShell" else { return }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let parentValues = try parent.resourceValues(forKeys: keys)
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else { return }
        // The current namespace may not exist yet on its first launch.
        // Only enumerate its real parent, never traverse a symlink sibling.
        let prefixes = ["ui-test-session-", "usage-ui-test-session-", "permissions-ui-test-session-"]
        var sweptLibraryNamespaces = Set<String>()
        for sibling in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: Array(keys)) {
            let name = sibling.lastPathComponent
            guard prefixes.contains(where: name.hasPrefix), !name.contains(currentPrefix) else { continue }
            do {
                let values = try sibling.resourceValues(forKeys: keys)
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                // removeItem unlinks any nested symlinks; it never traverses them.
                try FileManager.default.removeItem(at: sibling)
                if name.hasPrefix("ui-test-session-") {
                    sweptLibraryNamespaces.insert(name)
                }
            } catch {
                continue
            }
        }

        guard !sweptLibraryNamespaces.isEmpty else { return }
        let appContainer = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        let library = appContainer.appendingPathComponent("Library", isDirectory: true)
        let preferences = library.appendingPathComponent("Preferences", isDirectory: true)
        guard preferences.path.hasPrefix(appContainer.path + "/") else { return }
        for directory in [appContainer, library, preferences] {
            let values = try directory.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true else { return }
        }
        let preferenceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        for namespace in sweptLibraryNamespaces {
            let suitePlist = preferences.appendingPathComponent("IrisMobileShell.\(namespace).plist")
            do {
                let values = try suitePlist.resourceValues(forKeys: preferenceKeys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                try FileManager.default.removeItem(at: suitePlist)
            } catch {
                continue
            }
        }
    }

    public static func displayName(forIndex index: Int) -> String {
        index < leadingNames.count ? leadingNames[index] : "Fixture App \(index + 1)"
    }

    public static func appId(forIndex index: Int) -> String { "fixture.myapps-\(index + 1)" }
    public static func projectId(forIndex index: Int) -> String { "fixture.myapps-\(index + 1).mobile" }
    public static func identity(forIndex index: Int) -> NativeShellAppIdentity {
        NativeShellAppIdentity(appId: appId(forIndex: index), projectId: projectId(forIndex: index))
    }

    // MARK: - One package

    /// The exact bytes of one installable package for app `index`.
    /// Deterministic: the same index always yields the same bytes, so a repeat
    /// launch stages the same revision and never fights the delivery-nonce replay rule.
    public static func packageBytes(forIndex index: Int) -> Data {
        let appId = appId(forIndex: index)
        let projectId = projectId(forIndex: index)
        let name = displayName(forIndex: index)
        let html = Data("<!doctype html><meta charset=utf-8><title>\(name)</title><main>\(name)</main>".utf8)
        let filePath = "index.html"
        let fileSHA = NativeSecurity.sha256(html)
        let manifest = DeliveryManifestReceipt(
            displayName: name,
            runtimeType: "web",
            entrypoint: filePath,
            minShellVersion: "1.0.0",
            requestedCapabilities: [],
            dataNamespace: appId,
            dataUpdatePolicy: "preserve"
        )
        let identity = NativeSecurity.revisionIdentity(
            appId: appId, projectId: projectId, baseRevisionId: nil, manifest: manifest,
            files: [DeliveryFileReceipt(path: filePath, sha256: fileSHA, bytes: html.count, mediaType: "text/html", data: Data())]
        )
        let instant = "2026-09-28T00:00:00.000Z"
        let approvalId = "approval_fixture_" + hex24("approval-\(appId)")
        let envelopeId = "delivery_fixture_" + hex24("envelope-\(appId)")
        let nonce = NativeSecurity.sha256(Data("nonce-\(appId)".utf8)).dropFirst("sha256:".count)
        let revision: [String: Any] = [
            "kind": "iris.mobile-shell.revision",
            "version": 1,
            "appId": appId,
            "projectId": projectId,
            "revisionId": identity.revisionId,
            "baseRevisionId": NSNull(),
            "manifestHash": identity.manifestHash,
            "contentHash": identity.contentHash,
            "createdAt": instant,
            "manifest": [
                "kind": "iris.mobile-shell.manifest",
                "version": 1,
                "appId": appId,
                "projectId": projectId,
                "displayName": name,
                "runtime": ["type": "web", "entrypoint": filePath, "minShellVersion": "1.0.0"],
                "capabilities": [String](),
                "data": ["namespace": appId, "updatePolicy": "preserve"],
            ] as [String: Any],
            "files": [["path": filePath, "sha256": fileSHA, "bytes": html.count, "mediaType": "text/html"] as [String: Any]],
        ]
        let package: [String: Any] = [
            "format": "iris.mobile-shell.package+json",
            "approval": [
                "kind": "iris.mobile-shell.delivery-approval",
                "version": 1,
                "approvalId": approvalId,
                "requestId": NSNull(),
                "requestNonce": NSNull(),
                "appId": appId,
                "projectId": projectId,
                "baseRevisionId": NSNull(),
                "approvedRevisionId": identity.revisionId,
                "approvedContentHash": identity.contentHash,
                "approvedAt": instant,
            ] as [String: Any],
            "envelope": [
                "kind": "iris.mobile-shell.delivery-envelope",
                "version": 1,
                "envelopeId": envelopeId,
                "deliveryNonce": String(nonce),
                "approvalId": approvalId,
                "appId": appId,
                "projectId": projectId,
                "baseRevisionId": NSNull(),
                "revisionId": identity.revisionId,
                "contentHash": identity.contentHash,
                "issuedAt": instant,
                "revision": revision,
            ] as [String: Any],
            "files": [["path": filePath, "mediaType": "text/html", "contentBase64": html.base64EncodedString()] as [String: Any]],
        ]
        return (try? JSONSerialization.data(withJSONObject: package, options: [.sortedKeys])) ?? Data()
    }

    private static func hex24(_ seed: String) -> String {
        String(NativeSecurity.sha256(Data(seed.utf8)).dropFirst("sha256:".count).prefix(24))
    }

    // MARK: - Seeding

    public struct Report: Equatable, Sendable {
        public let requested: Int
        public let installed: Int
        public let alreadyPresent: Int
        public let failed: Int
    }

    /// Installs apps 0..<count that are not already in the library, through the
    /// real coordinator. Returns what happened. Never throws for one bad app:
    /// the failure is counted so a test can assert it is zero.
    @discardableResult
    public static func seedLibrary(count: Int, into coordinator: NativeShellLibraryCoordinator) async -> Report {
        let wanted = max(0, min(count, maximumCount))
        var installed = 0, already = 0, failed = 0
        for index in 0..<wanted {
            let identity = identity(forIndex: index)
            if let existing = try? await coordinator.libraryEntry(identity: identity), existing.currentRevisionId != nil {
                already += 1
                continue
            }
            do {
                let review = try await coordinator.reviewImport(packageBytes: packageBytes(forIndex: index), expectedIdentity: identity)
                let outcome = try await coordinator.approvePendingReviewLocallyAndStage(
                    reviewToken: review.reviewToken, packageSHA256: review.packageSHA256
                )
                try await coordinator.activate(identity: identity, revisionId: outcome.revisionId)
                installed += 1
            } catch {
                failed += 1
            }
        }
        return Report(requested: wanted, installed: installed, alreadyPresent: already, failed: failed)
    }

    // MARK: - Arrangement

    /// The people-made side of the fixture (SPEC 5.6): three folders, one of
    /// them empty, and two renamed apps. Only identities that exist in the
    /// seeded range are used, so a count of 12 or more gets all of it and a
    /// smaller count gets what fits.
    public static func arrangement(count: Int, createdAt: String = "2026-09-28T09:00:00Z") -> MyAppsArrangement {
        func id(_ i: Int) -> String? { i < count ? identity(forIndex: i).id : nil }
        var folders: [MyAppsFolder] = []
        let favourites = [4, 5, 6].compactMap(id)
        if !favourites.isEmpty {
            folders.append(MyAppsFolder(id: "fixture-favourites", name: "Favourites", order: 0, createdAt: createdAt, apps: favourites))
        }
        let later = [7].compactMap(id)
        if !later.isEmpty {
            folders.append(MyAppsFolder(id: "fixture-later", name: "Later", order: 1, createdAt: createdAt, apps: later))
        }
        folders.append(MyAppsFolder(id: "fixture-empty", name: "Empty shelf", order: 2, createdAt: createdAt, apps: []))
        var apps: [String: MyAppsAppEntry] = [:]
        if let first = id(8) { apps[first] = MyAppsAppEntry(name: "Habits") }
        if let second = id(9) { apps[second] = MyAppsAppEntry(name: "Hikes") }
        return MyAppsArrangement(folders: folders, apps: apps)
    }

    /// Writes `arrangement(count:)` next to the library (the coordinator's own
    /// root), the same file `MyAppsOrganizationStore` reads at launch. Skipped
    /// when a file from an earlier run is already there, so a person's edits
    /// during a repeated fixture launch are not overwritten.
    public static func writeArrangementIfAbsent(count: Int, root: URL) {
        let path = root.appendingPathComponent("my-apps.json")
        guard !FileManager.default.fileExists(atPath: path.path),
              let file = try? MyAppsOrganizationFile(root: root) else { return }
        try? file.save(arrangement(count: count))
    }
}

#endif

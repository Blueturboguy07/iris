//
//  AppInventoryService.swift
//  leanring-buddy
//
//  Knows which publik catalog apps are on this Mac, which version of each, and
//  which one the user is looking at right now.
//
//  The distinction this file exists to protect is the one between "this app is
//  not installed" and "I cannot tell whether this app is installed". The
//  catalog carries a `macBundleId` for only some listings and deliberately
//  leaves the rest null — see the comment on that field in
//  `lib/apps-config.ts`. A null is not permission to guess an identifier from
//  the product name: a wrong identifier never matches anything, so Iris would
//  quietly and confidently report a perfectly well installed app as missing.
//  Every app with no bundle identifier is therefore reported as `unknown`, and
//  the UI says nothing about it at all. Telling someone an app is missing when
//  you simply cannot see it is a lie, and it is the kind of lie that makes
//  someone reinstall something they already have.
//
//  Nothing here downloads or installs anything. The update affordance opens the
//  app's publik page in the browser through `ExternalLinkPolicy`, because the
//  download route is auth-gated in the browser on purpose.
//

import AppKit
import Combine
import Foundation

// MARK: - What publik tells us about one catalog app

/// One row of `GET {publik}/api/iris/apps`. Deliberately tiny: the inventory
/// needs a name to show, an identifier to look for, and a tag to compare
/// against, and nothing else about the listing is any of its business.
nonisolated struct CatalogAppDescriptor: Decodable, Equatable, Sendable {
    let slug: String
    let name: String
    /// Null means publik has not established this app's bundle identifier. It
    /// never means "this app has no bundle".
    let macBundleId: String?
    /// The newest published release tag, e.g. `v0.1.1`. Null when the app has
    /// no releases, or when publik's catalog sync has not run yet.
    let latestReleaseTag: String?
}

private nonisolated struct CatalogAppDirectoryResponse: Decodable {
    let apps: [CatalogAppDescriptor]
}

// MARK: - Fetching the catalog

nonisolated enum AppCatalogDirectoryError: Error, Equatable, Sendable {
    case apiBaseIsNotAllowed
    case unexpectedResponseStatus(statusCode: Int)
    case responseCouldNotBeDecoded(reason: String)
    case transportFailure(reason: String)

    var userFacingMessage: String {
        switch self {
        case .apiBaseIsNotAllowed:
            return "Iris only reads the app catalog from publik."
        case .unexpectedResponseStatus(let statusCode):
            return "Publik's app catalog returned \(statusCode)."
        case .responseCouldNotBeDecoded(let reason):
            return "Iris could not read publik's app catalog: \(reason)"
        case .transportFailure(let reason):
            return "Iris could not reach publik: \(reason)"
        }
    }
}

/// Where the list of catalog apps comes from. A protocol so tests can hand the
/// inventory a fixed catalog instead of whatever publik happens to be serving.
nonisolated protocol CatalogAppDirectorySource: Sendable {
    func catalogApps() async throws -> [CatalogAppDescriptor]
}

/// The real source: publik's read-only catalog route. Shaped after
/// `GuideService` on purpose — same allowlisted API base, same
/// status-code-to-error mapping, same session cache — so there is one way this
/// app talks to publik rather than two.
actor PublikCatalogAppDirectory: CatalogAppDirectorySource {
    private let apiBase: String
    private let urlSession: URLSession

    /// The catalog changes at most daily (publik's sync is on a cron), so the
    /// copy fetched this session is reused rather than refetched every time the
    /// panel opens.
    private var cachedCatalogApps: [CatalogAppDescriptor]?

    init(
        apiBase: String = GuideService.defaultAPIBase,
        urlSession: URLSession = .shared
    ) {
        self.apiBase = GuideService.normalizedAPIBase(apiBase) ?? GuideService.defaultAPIBase
        self.urlSession = urlSession
    }

    func catalogApps() async throws -> [CatalogAppDescriptor] {
        if let cachedCatalogApps = cachedCatalogApps {
            return cachedCatalogApps
        }

        guard let catalogURL = URL(string: "\(apiBase)/api/iris/apps") else {
            throw AppCatalogDirectoryError.apiBaseIsNotAllowed
        }

        var catalogRequest = URLRequest(url: catalogURL)
        catalogRequest.httpMethod = "GET"
        catalogRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let responseData: Data
        let urlResponse: URLResponse
        do {
            (responseData, urlResponse) = try await urlSession.data(for: catalogRequest)
        } catch {
            throw AppCatalogDirectoryError.transportFailure(reason: error.localizedDescription)
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw AppCatalogDirectoryError.unexpectedResponseStatus(statusCode: 0)
        }
        guard httpResponse.statusCode == 200 else {
            throw AppCatalogDirectoryError.unexpectedResponseStatus(statusCode: httpResponse.statusCode)
        }

        let catalogResponse: CatalogAppDirectoryResponse
        do {
            catalogResponse = try JSONDecoder().decode(
                CatalogAppDirectoryResponse.self,
                from: responseData
            )
        } catch {
            throw AppCatalogDirectoryError.responseCouldNotBeDecoded(
                reason: error.localizedDescription
            )
        }

        cachedCatalogApps = catalogResponse.apps
        return catalogResponse.apps
    }

    func clearCachedCatalogApps() {
        cachedCatalogApps = nil
    }
}

// MARK: - Finding an installed app on this Mac

/// Turns a bundle identifier into the place that app lives on this Mac, or nil
/// when nothing on the machine claims it. A protocol so tests never depend on
/// what is actually installed on the machine running them.
nonisolated protocol InstalledApplicationLocating: Sendable {
    func applicationBundleURL(forBundleIdentifier bundleIdentifier: String) -> URL?
}

/// The real lookup. `NSWorkspace` answers instantly from LaunchServices, which
/// is right almost always; `mdfind` is the fallback for the case LaunchServices
/// gets wrong — an app that has been copied into place but never opened, so
/// nothing has registered it yet.
nonisolated struct SystemInstalledApplicationLocator: InstalledApplicationLocating {
    /// Only these characters can appear in a bundle identifier we will hand to
    /// Spotlight. The query below embeds the identifier inside single quotes,
    /// and this is what guarantees the identifier cannot close that quote and
    /// become part of the query. The catalog is ours, but "the input is ours"
    /// is not a security property that survives someone editing a config file.
    private static let charactersAllowedInABundleIdentifier = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
    )

    func applicationBundleURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        if let launchServicesURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) {
            return launchServicesURL
        }
        return Self.spotlightApplicationBundleURL(forBundleIdentifier: bundleIdentifier)
    }

    /// Asks Spotlight for a bundle with this identifier. Returns nil on any
    /// failure at all — a Mac with Spotlight indexing disabled simply produces
    /// "not found", which is the same answer the user would get from Finder.
    static func spotlightApplicationBundleURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier.unicodeScalars.allSatisfy({
                  charactersAllowedInABundleIdentifier.contains($0)
              }) else {
            return nil
        }

        let spotlightQuery = "kMDItemCFBundleIdentifier == '\(bundleIdentifier)'"
        guard let commandResult = try? ToolVersionService.runCommand(
            executablePath: "/usr/bin/mdfind",
            arguments: [spotlightQuery],
            environment: nil,
            workingDirectory: nil
        ), commandResult.terminationStatus == 0 else {
            return nil
        }

        let matchedPaths = String(decoding: commandResult.standardOutput, as: UTF8.self)
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Spotlight can return several copies (a build folder, a backup). The
        // one in an Applications folder is the installed one; failing that, the
        // first match is the best guess available.
        let preferredPath = matchedPaths.first { candidatePath in
            candidatePath.hasPrefix("/Applications/")
                || candidatePath.contains("/Applications/")
        } ?? matchedPaths.first

        guard let preferredPath = preferredPath else {
            return nil
        }
        return URL(fileURLWithPath: preferredPath)
    }
}

/// Reads the version a bundle advertises to the user.
nonisolated enum InstalledApplicationVersionReader {
    /// `CFBundleShortVersionString` is the marketing version — "0.1.1" — which
    /// is what a release tag is comparable to. `CFBundleVersion` is the build
    /// number and is frequently something like "42", which would compare to a
    /// release tag as pure nonsense.
    ///
    /// The plist is read directly rather than through `Bundle(url:)` for two
    /// reasons: `Bundle` caches per URL for the life of the process, so a test
    /// that writes a bundle and then rewrites it would keep getting the first
    /// answer forever, and `PropertyListSerialization` fails cleanly on a
    /// corrupt file instead of returning a half-built bundle.
    static func shortVersionString(forApplicationBundleAt applicationBundleURL: URL) -> String? {
        let infoPlistURL = applicationBundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")

        guard let infoPlistData = try? Data(contentsOf: infoPlistURL) else {
            return nil
        }
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: infoPlistData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            return nil
        }

        // A value that is not a string at all — a number, a dictionary, a
        // missing key — is not a version. Reporting nil says "installed, version
        // unknown", which is true, rather than inventing a string to compare.
        guard let shortVersionString = propertyList["CFBundleShortVersionString"] as? String else {
            return nil
        }
        let trimmedShortVersionString = shortVersionString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedShortVersionString.isEmpty ? nil : trimmedShortVersionString
    }
}

// MARK: - What the inventory concluded about one app

/// Three states, not two. The third is the whole point of this file.
nonisolated enum CatalogAppInstallationState: Equatable, Sendable {
    /// The app is on this Mac. `installedVersion` is nil when the bundle exists
    /// but its `CFBundleShortVersionString` is missing or unreadable.
    case installed(installedVersion: String?)
    /// Nothing on this Mac claims this app's bundle identifier.
    case notInstalled
    /// Publik has no bundle identifier for this app, so there is no honest way
    /// to look for it. Never render this as "not installed".
    case unknown
}

nonisolated enum CatalogAppUpdateAvailability: Equatable, Sendable {
    /// The catalog's latest release is strictly newer than what is installed.
    case updateIsAvailable(latestReleaseTag: String)
    /// The installed version is the latest, or is ahead of it (a local build).
    case upToDate
    /// Either version could not be read, the app is not installed, or the
    /// catalog has no release to compare against. No direction is claimed.
    case unknown
}

nonisolated struct CatalogAppInventoryEntry: Identifiable, Equatable, Sendable {
    let slug: String
    let name: String
    let macBundleId: String?
    let latestReleaseTag: String?
    let installationState: CatalogAppInstallationState
    let updateAvailability: CatalogAppUpdateAvailability

    var id: String { slug }

    var isInstalled: Bool {
        if case .installed = installationState {
            return true
        }
        return false
    }

    var installedVersion: String? {
        if case .installed(let installedVersion) = installationState {
            return installedVersion
        }
        return nil
    }

    var hasAnUpdateAvailable: Bool {
        if case .updateIsAvailable = updateAvailability {
            return true
        }
        return false
    }
}

// MARK: - The service

/// Publishes the inventory of catalog apps on this Mac.
///
/// PRIVACY: like `AppAwarenessService`, nothing here is written to disk. Which
/// apps someone has installed is a fact about their machine, it is held in
/// memory for as long as the panel needs it, and it stops existing when Iris
/// quits.
@MainActor
final class AppInventoryService: ObservableObject {
    /// The floor on how often a frontmost-app change may trigger a rescan.
    /// Switching apps is something a person does dozens of times a minute, and
    /// a rescan can spawn `mdfind`; this is not a hot path and must not become
    /// one.
    /// `nonisolated` because the pure decision function below is nonisolated so
    /// it can be tested without a main actor hop, and it reads this.
    nonisolated static let minimumSecondsBetweenAutomaticRefreshes: Double = 60

    /// Every catalog app, including the ones whose installation state is
    /// unknown. The UI filters; the service reports everything it was told
    /// about, so a caller can tell "not in the catalog" from "unknown".
    @Published private(set) var inventoryEntries: [CatalogAppInventoryEntry] = []

    /// The slug of the catalog app the user is currently looking at, or nil when
    /// the app in front is not one of ours (or cannot be identified).
    @Published private(set) var frontmostCatalogAppSlug: String?

    @Published private(set) var isRefreshing = false

    /// Set when the catalog could not be read. The previously known inventory is
    /// kept in place rather than blanked, because an app that was installed a
    /// minute ago is still installed when the network drops.
    @Published private(set) var lastRefreshFailureMessage: String?

    private(set) var lastSuccessfulRefreshCompletedAt: Date?

    private let catalogDirectory: any CatalogAppDirectorySource
    private let installedApplicationLocator: any InstalledApplicationLocating
    private let appAwarenessService: AppAwarenessService
    private let publikBaseURLString: String

    private var frontmostAppSubscription: AnyCancellable?

    /// The bundle identifier of whatever is in front, catalog app or not. Kept
    /// separately from `frontmostCatalogAppSlug` because the inventory can
    /// arrive after the frontmost reading does, and the slug has to be
    /// recomputed once it does.
    private var frontmostForegroundAppBundleIdentifier: String?

    init(
        catalogDirectory: any CatalogAppDirectorySource = PublikCatalogAppDirectory(),
        installedApplicationLocator: any InstalledApplicationLocating = SystemInstalledApplicationLocator(),
        // Nil rather than a default `AppAwarenessService()`: a default argument
        // is evaluated in the caller's context, and that type is main-actor
        // isolated, so it has to be built inside this initializer instead.
        appAwarenessService: AppAwarenessService? = nil,
        publikBaseURLString: String = GuideService.defaultAPIBase
    ) {
        self.catalogDirectory = catalogDirectory
        self.installedApplicationLocator = installedApplicationLocator
        self.appAwarenessService = appAwarenessService ?? AppAwarenessService()
        self.publikBaseURLString = GuideService.normalizedAPIBase(publikBaseURLString)
            ?? GuideService.defaultAPIBase
    }

    // MARK: - Refreshing

    /// Where an installed app lives on this Mac, or nil if it cannot be found
    /// yet. Reuses the same locator the inventory uses (LaunchServices first,
    /// then a Spotlight fallback), so a just-installed app is found even before
    /// LaunchServices has caught up. Used to open an app the moment its guide
    /// finishes.
    func installedApplicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        installedApplicationLocator.applicationBundleURL(forBundleIdentifier: bundleIdentifier)
    }

    /// Rescans now. Reading the catalog is a network call; deciding what is
    /// installed is filesystem and LaunchServices work, so it happens off the
    /// main actor and only the finished answer comes back.
    func refreshInventory() async {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        let catalogDescriptors: [CatalogAppDescriptor]
        do {
            catalogDescriptors = try await catalogDirectory.catalogApps()
            lastRefreshFailureMessage = nil
        } catch let catalogError as AppCatalogDirectoryError {
            lastRefreshFailureMessage = catalogError.userFacingMessage
            return
        } catch {
            lastRefreshFailureMessage = AppCatalogDirectoryError
                .transportFailure(reason: error.localizedDescription)
                .userFacingMessage
            return
        }

        let installedApplicationLocator = self.installedApplicationLocator
        let freshInventoryEntries = await Task.detached(priority: .utility) {
            Self.buildInventoryEntries(
                fromCatalogDescriptors: catalogDescriptors,
                using: installedApplicationLocator
            )
        }.value

        inventoryEntries = freshInventoryEntries
        lastSuccessfulRefreshCompletedAt = Date()
        recomputeFrontmostCatalogAppSlug()
    }

    /// The call a view makes when it appears. Rescans only if the last scan is
    /// older than the floor above, so opening and closing the panel repeatedly
    /// does not turn into repeated Spotlight queries.
    func refreshInventoryIfStale() async {
        let hasNeverRefreshed = lastSuccessfulRefreshCompletedAt == nil
        let isStale = lastSuccessfulRefreshCompletedAt.map { lastRefreshDate in
            Date().timeIntervalSince(lastRefreshDate) >= Self.minimumSecondsBetweenAutomaticRefreshes
        } ?? true
        guard hasNeverRefreshed || isStale else {
            return
        }
        await refreshInventory()
    }

    // MARK: - Watching what the user is looking at

    /// Starts following the frontmost app. Uses `AppAwarenessService` rather
    /// than a second mechanism, so there is exactly one thing in this app that
    /// knows how to read the app in front.
    func startWatchingTheFrontmostApp() {
        guard frontmostAppSubscription == nil else {
            return
        }
        frontmostAppSubscription = appAwarenessService.$currentForegroundApp
            .receive(on: DispatchQueue.main)
            .sink { [weak self] foregroundApp in
                // The publisher is delivered on the main queue just above, and
                // this type is main-actor isolated, so the hop is already done.
                MainActor.assumeIsolated {
                    self?.updateFrontmostApplication(foregroundApp)
                }
            }
        appAwarenessService.startPollingForegroundApp()
    }

    func stopWatchingTheFrontmostApp() {
        frontmostAppSubscription?.cancel()
        frontmostAppSubscription = nil
        appAwarenessService.stopPollingForegroundApp()
        frontmostCatalogAppSlug = nil
    }

    /// Records which app is in front. Called by the subscription above, and
    /// directly by tests so the frontmost behavior can be exercised without a
    /// real app being frontmost.
    func updateFrontmostApplication(_ foregroundApp: ForegroundAppIdentity?) {
        frontmostForegroundAppBundleIdentifier = foregroundApp?.bundleIdentifier
        recomputeFrontmostCatalogAppSlug()

        // A person switching into one of our apps is the moment the inventory is
        // most worth being right, and also the moment they may have just
        // finished installing it — but only if we have not looked recently.
        if Self.shouldRefreshAutomatically(
            frontmostAppIsInTheCatalog: frontmostCatalogAppSlug != nil,
            lastSuccessfulRefreshCompletedAt: lastSuccessfulRefreshCompletedAt,
            now: Date()
        ) {
            Task { [weak self] in
                await self?.refreshInventory()
            }
        }
    }

    private func recomputeFrontmostCatalogAppSlug() {
        guard let frontmostForegroundAppBundleIdentifier = frontmostForegroundAppBundleIdentifier else {
            frontmostCatalogAppSlug = nil
            return
        }
        // Bundle identifiers are compared case-insensitively because
        // LaunchServices treats them that way, and a catalog entry typed with a
        // different capitalisation should still match rather than silently miss.
        let matchingEntry = inventoryEntries.first { inventoryEntry in
            guard let macBundleId = inventoryEntry.macBundleId else {
                return false
            }
            return macBundleId.caseInsensitiveCompare(frontmostForegroundAppBundleIdentifier)
                == .orderedSame
        }
        frontmostCatalogAppSlug = matchingEntry?.slug
    }

    nonisolated static func shouldRefreshAutomatically(
        frontmostAppIsInTheCatalog: Bool,
        lastSuccessfulRefreshCompletedAt: Date?,
        now: Date
    ) -> Bool {
        guard frontmostAppIsInTheCatalog else {
            return false
        }
        guard let lastSuccessfulRefreshCompletedAt = lastSuccessfulRefreshCompletedAt else {
            return true
        }
        return now.timeIntervalSince(lastSuccessfulRefreshCompletedAt)
            >= minimumSecondsBetweenAutomaticRefreshes
    }

    // MARK: - Building the inventory

    nonisolated static func buildInventoryEntries(
        fromCatalogDescriptors catalogDescriptors: [CatalogAppDescriptor],
        using installedApplicationLocator: any InstalledApplicationLocating
    ) -> [CatalogAppInventoryEntry] {
        catalogDescriptors.map { catalogDescriptor in
            let installationState = installationState(
                forCatalogDescriptor: catalogDescriptor,
                using: installedApplicationLocator
            )
            return CatalogAppInventoryEntry(
                slug: catalogDescriptor.slug,
                name: catalogDescriptor.name,
                macBundleId: catalogDescriptor.macBundleId,
                latestReleaseTag: catalogDescriptor.latestReleaseTag,
                installationState: installationState,
                updateAvailability: updateAvailability(
                    forInstallationState: installationState,
                    latestReleaseTag: catalogDescriptor.latestReleaseTag
                )
            )
        }
    }

    nonisolated static func installationState(
        forCatalogDescriptor catalogDescriptor: CatalogAppDescriptor,
        using installedApplicationLocator: any InstalledApplicationLocating
    ) -> CatalogAppInstallationState {
        // No bundle identifier means no way to look. That is `unknown`, and it
        // must never collapse into `notInstalled` — see the header comment.
        guard let macBundleId = catalogDescriptor.macBundleId,
              !macBundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unknown
        }

        guard let applicationBundleURL = installedApplicationLocator.applicationBundleURL(
            forBundleIdentifier: macBundleId
        ) else {
            return .notInstalled
        }

        return .installed(
            installedVersion: InstalledApplicationVersionReader.shortVersionString(
                forApplicationBundleAt: applicationBundleURL
            )
        )
    }

    /// An update is claimed only when the catalog's release is *strictly* newer
    /// than what is installed. Equal is up to date. Older is up to date too —
    /// somebody running a build newer than the published release is ahead of us,
    /// not behind, and telling them to "update" would walk them backwards.
    nonisolated static func updateAvailability(
        forInstallationState installationState: CatalogAppInstallationState,
        latestReleaseTag: String?
    ) -> CatalogAppUpdateAvailability {
        guard case .installed(let installedVersion) = installationState else {
            return .unknown
        }
        guard let installedVersion = installedVersion,
              let latestReleaseTag = latestReleaseTag else {
            return .unknown
        }

        switch ReleaseVersion.compare(installedVersion, to: latestReleaseTag) {
        case .olderThanTheOtherVersion:
            return .updateIsAvailable(latestReleaseTag: latestReleaseTag)
        case .theSameAsTheOtherVersion, .newerThanTheOtherVersion:
            return .upToDate
        case .cannotBeCompared:
            return .unknown
        }
    }

    // MARK: - What the panel shows

    /// Installed apps only, with anything that has an update first, then
    /// alphabetically. Apps that are not installed — and apps we cannot see —
    /// are left out entirely rather than listed as absent, which is what keeps
    /// this a short section instead of a wall of ten rows.
    var installedEntriesForDisplay: [CatalogAppInventoryEntry] {
        inventoryEntries
            .filter(\.isInstalled)
            .sorted { leftEntry, rightEntry in
                if leftEntry.hasAnUpdateAvailable != rightEntry.hasAnUpdateAvailable {
                    return leftEntry.hasAnUpdateAvailable
                }
                return leftEntry.name.localizedCaseInsensitiveCompare(rightEntry.name)
                    == .orderedAscending
            }
    }

    /// The app's page on publik. Built from the same base the catalog was read
    /// from, so a developer running publik locally lands on their own site
    /// rather than on production.
    func publikPageURLString(forSlug slug: String) -> String {
        "\(publikBaseURLString)/\(slug)"
    }

    /// Opens the app's publik page in the browser. Iris never downloads or
    /// installs anything itself: the download route is auth-gated in the browser
    /// deliberately, and the browser is where that gate lives.
    @discardableResult
    func openPublikPageForUpdating(slug: String) -> Bool {
        ExternalLinkPolicy.openExternalURLIfAllowed(publikPageURLString(forSlug: slug))
    }
}

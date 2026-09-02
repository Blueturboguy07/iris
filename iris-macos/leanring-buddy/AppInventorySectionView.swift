//
//  AppInventorySectionView.swift
//  leanring-buddy
//
//  The compact "Your publik apps" section of the menu bar panel: which catalog
//  apps are on this Mac, which version each one is, and which of them has a
//  newer release waiting.
//
//  Only installed apps appear. An app publik has no bundle identifier for is
//  invisible here on purpose — `AppInventoryService` reports it as `unknown`,
//  and there is no honest row to draw for "I cannot tell". Listing every
//  catalog app with a state next to it would also be ten rows in a 320pt panel,
//  which is a wall rather than a section.
//
//  The update affordance opens the app's page on publik in the browser. It does
//  not download or install anything: the download route is auth-gated in the
//  browser deliberately, and the browser is where that gate lives.
//

import SwiftUI

// MARK: - Discovering apps that are not installed yet

/// The read-only logic behind the "discover more apps" surface: given the whole
/// catalog inventory and what the reader has typed, which apps to offer and in
/// what order. Pure so the filtering and the starter picks are testable without
/// a network, a view, or anything installed on the machine running the tests.
///
/// The rule throughout: only ever offer an app the reader does NOT already have.
/// The installed apps have their own section right above this one, and listing
/// them here again as "discover" would be noise at best and a second, confusing
/// update path at worst.
nonisolated enum CatalogAppDiscovery {

    /// How many "start here" suggestions to show a reader who has not searched.
    /// Small on purpose: the whole complaint this answers is that it is "hard to
    /// know which repos to install after the first one", so the empty state is a
    /// short, considered handful rather than the whole catalog.
    static let numberOfStarterSuggestions = 4

    /// The most search results the surface shows at once, so a one-letter query
    /// cannot turn the panel into a wall. Past this the reader is asked to keep
    /// typing to narrow it down — the filtering itself stays over the whole
    /// catalog.
    static let maximumSearchResultsToShow = 8

    /// Every catalog app the reader could still install — everything not already
    /// on this Mac — narrowed to what matches the search text and sorted
    /// alphabetically for display.
    ///
    /// An app whose install state is `unknown` (publik has no bundle id for it,
    /// so Iris genuinely cannot tell whether it is installed) is still offered:
    /// the worst case is opening the publik page for something the reader
    /// already has, which is harmless, and hiding it would make a searchable app
    /// un-findable for no reason.
    static func discoverableApps(
        fromInventory inventoryEntries: [CatalogAppInventoryEntry],
        matchingSearchText searchText: String
    ) -> [CatalogAppInventoryEntry] {
        let notAlreadyInstalled = inventoryEntries.filter { !$0.isInstalled }
        let matching = appsMatching(searchText, within: notAlreadyInstalled)
        return matching.sorted { leftEntry, rightEntry in
            leftEntry.name.localizedCaseInsensitiveCompare(rightEntry.name) == .orderedAscending
        }
    }

    /// A short, considered set of apps to suggest when the reader has typed
    /// nothing yet. Apps that have a published release come first — an app you
    /// can actually install today is a better "start here" than one whose
    /// release has not landed — then alphabetical, capped at the starter count.
    static func starterSuggestions(
        fromInventory inventoryEntries: [CatalogAppInventoryEntry],
        limit: Int = numberOfStarterSuggestions
    ) -> [CatalogAppInventoryEntry] {
        let notAlreadyInstalled = inventoryEntries.filter { !$0.isInstalled }
        let ordered = notAlreadyInstalled.sorted { leftEntry, rightEntry in
            let leftHasARelease = leftEntry.latestReleaseTag != nil
            let rightHasARelease = rightEntry.latestReleaseTag != nil
            if leftHasARelease != rightHasARelease {
                return leftHasARelease
            }
            return leftEntry.name.localizedCaseInsensitiveCompare(rightEntry.name) == .orderedAscending
        }
        return Array(ordered.prefix(max(0, limit)))
    }

    /// Substring match on the name and the slug, case- and diacritic-insensitive
    /// so "cal" finds "Cal AI" and an accented name still matches its plain
    /// typing. Empty (or whitespace-only) search text matches everything, so the
    /// caller can choose between the starter set and the full filtered list.
    private static func appsMatching(
        _ searchText: String,
        within entries: [CatalogAppInventoryEntry]
    ) -> [CatalogAppInventoryEntry] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchText.isEmpty else { return entries }
        return entries.filter { entry in
            entry.name.range(
                of: trimmedSearchText,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
                || entry.slug.range(
                    of: trimmedSearchText,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
        }
    }
}

struct AppInventorySectionView: View {
    @ObservedObject var appInventoryService: AppInventoryService
    /// Which of those apps are running right now, and what they said when
    /// asked. Separate from the inventory because "installed" and "running and
    /// answering" are genuinely different facts.
    @ObservedObject var appLinkService: AppLinkService

    /// The reader tapped "Edit this app": kick off the on-demand edit flow for
    /// this app. Wired by `CompanionPanelView` to `CompanionManager`, which
    /// opens the edit card at the eye. Defaulted to a no-op so a preview or a
    /// caller that does not offer editing still builds.
    var onEditApp: (CatalogAppInventoryEntry) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your publik apps")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            if installedEntries.isEmpty {
                Text(emptyStateMessage)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(installedEntries) { installedEntry in
                        installedAppRow(for: installedEntry)
                    }
                }
            }
        }
        .task {
            await appInventoryService.refreshInventoryIfStale()
        }
        .onAppear {
            appInventoryService.startWatchingTheFrontmostApp()
        }
        .onDisappear {
            // The panel is closed: nothing about which app the user is looking
            // at needs to keep being read while Iris is not on screen.
            appInventoryService.stopWatchingTheFrontmostApp()
        }
    }

    /// Updates first, then alphabetical — the service owns that ordering so the
    /// same rule applies anywhere else the inventory is shown.
    private var installedEntries: [CatalogAppInventoryEntry] {
        appInventoryService.installedEntriesForDisplay
    }

    /// "None found" and "we could not look" are different sentences, because
    /// only one of them means the user has none of our apps.
    private var emptyStateMessage: String {
        if let lastRefreshFailureMessage = appInventoryService.lastRefreshFailureMessage {
            return lastRefreshFailureMessage
        }
        if appInventoryService.isRefreshing || appInventoryService.inventoryEntries.isEmpty {
            return "Looking for publik apps on this Mac…"
        }
        return "No publik apps found on this Mac yet."
    }

    @ViewBuilder
    private func installedAppRow(for installedEntry: CatalogAppInventoryEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(installedEntry.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)

                    // A quiet marker on the app the user is actually looking at,
                    // so the section reads as being about their machine rather
                    // than about a catalog.
                    if appInventoryService.frontmostCatalogAppSlug == installedEntry.slug {
                        Text("in front")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }

                Text(versionLine(for: installedEntry))
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)

                // What the app said when it was asked, or why it could not
                // answer. Only ever shown for an app that is actually running.
                if let liveStatusLine = liveStatusLine(for: installedEntry) {
                    Text(liveStatusLine)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            // Only offered while the app is running: asking a closed app is
            // meaningless, and Iris deliberately never launches one to ask.
            if let runningInstance = appLinkService.runningInstance(forSlug: installedEntry.slug) {
                Button(action: {
                    Task { await appLinkService.queryDiagnostics(for: runningInstance) }
                }) {
                    Text(appLinkService.reports[runningInstance.appId] == nil ? "Ask it what's wrong" : "Ask again")
                }
                .irisTinyButton()
                .disabled(appLinkService.isQuerying)
                .help("\(installedEntry.name) is running. It will ask you before it answers.")
            }

            // Only shown for an app whose source Iris may edit locally — a
            // guide-source clone with a live `.git`. A signed-download install
            // never renders this. The provenance is advisory here and re-checked
            // LIVE when the reader actually starts an edit.
            if installedEntry.isLocallyEditable {
                Button(action: {
                    onEditApp(installedEntry)
                }) {
                    Text("Edit this app")
                }
                .irisTinyButton()
                .help("Tell Iris what to change in \(installedEntry.name). It edits your local source under your own model key.")
            }

            if case .updateIsAvailable(let latestReleaseTag) = installedEntry.updateAvailability {
                Button(action: {
                    appInventoryService.openPublikPageForUpdating(slug: installedEntry.slug)
                }) {
                    Text("Update to \(latestReleaseTag)")
                }
                .irisPrimaryPill(isFullWidth: false, isCompact: true)
                .help("Opens \(installedEntry.name) on publik. Iris never installs anything itself.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    /// One line about what the running app last said.
    ///
    /// A refusal is reported as plainly as a failure: "it has not been given
    /// permission" is a different problem from "it is broken", and telling
    /// someone to look for a bug when the real answer is a switch they never
    /// flipped wastes their afternoon.
    private func liveStatusLine(for installedEntry: CatalogAppInventoryEntry) -> String? {
        guard let runningInstance = appLinkService.runningInstance(forSlug: installedEntry.slug) else { return nil }

        if let failure = appLinkService.failures[runningInstance.appId] {
            return failure.message
        }
        guard let report = appLinkService.reports[runningInstance.appId] else { return nil }
        guard let diagnostics = report.diagnostics else { return nil }

        if let lastError = diagnostics.lastError {
            return "Last error: \(lastError.message)"
        }
        return "Running, nothing reported wrong."
    }

    /// An installed app whose version could not be read still gets a row — it is
    /// installed, and that is worth saying. What it does not get is a claim
    /// about whether it is current.
    private func versionLine(for installedEntry: CatalogAppInventoryEntry) -> String {
        guard let installedVersion = installedEntry.installedVersion else {
            return "Installed · version unknown"
        }
        switch installedEntry.updateAvailability {
        case .updateIsAvailable:
            return "You have \(installedVersion)"
        case .upToDate:
            return "\(installedVersion) · up to date"
        case .unknown:
            return installedVersion
        }
    }
}

// MARK: - Discover more apps

/// The "discover more apps" section of the settings panel: a search field over
/// the approved publik catalog, plus a short set of "start here" suggestions for
/// a reader who has installed nothing yet. It answers the tester who could not
/// tell what to install after his first app — "it should have a search bar to go
/// through the approved repos so you know what to pick."
///
/// Tapping an app opens its publik page in the browser through the same
/// `ExternalLinkPolicy` the "Update to…" affordance above uses. Iris never
/// downloads or installs anything itself: the download route is auth-gated in
/// the browser on purpose, and the browser is where that gate lives.
struct DiscoverAppsSectionView: View {
    @ObservedObject var appInventoryService: AppInventoryService

    /// What the reader has typed. Filtering is done in memory over the
    /// already-fetched catalog, so it is instant and needs no network.
    @State private var searchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Discover apps")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            searchField

            content
        }
        .task {
            // The installed-apps section above triggers the same refresh; this
            // is here so the discovery surface still fills in when it is the
            // thing on screen. `refreshInventoryIfStale` collapses the two into
            // a single fetch, so having both costs nothing.
            await appInventoryService.refreshInventoryIfStale()
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            TextField("Search publik apps", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.ink)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(DS.Colors.line, lineWidth: 1)
        )
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if appInventoryService.inventoryEntries.isEmpty {
            // The catalog has not arrived yet — still loading, or the network is
            // down. Either way there is nothing honest to filter.
            Text(catalogUnavailableMessage)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if trimmedSearchText.isEmpty {
            starterSuggestionsContent
        } else {
            searchResultsContent(matching: trimmedSearchText)
        }
    }

    /// "Still loading" and "we could not reach publik" are different sentences,
    /// because only one of them means the reader should try again later.
    private var catalogUnavailableMessage: String {
        if let lastRefreshFailureMessage = appInventoryService.lastRefreshFailureMessage {
            return lastRefreshFailureMessage
        }
        if appInventoryService.isRefreshing {
            return "Finding apps to explore…"
        }
        return "No apps to explore yet."
    }

    @ViewBuilder
    private var starterSuggestionsContent: some View {
        let starterSuggestions = CatalogAppDiscovery.starterSuggestions(
            fromInventory: appInventoryService.inventoryEntries
        )
        if starterSuggestions.isEmpty {
            // Every catalog app is already installed. A pleasant dead end.
            Text("You've installed every publik app for Mac. Search to find them again.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("START HERE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(DS.Colors.quiet)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(starterSuggestions) { suggestedEntry in
                        discoverAppRow(for: suggestedEntry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func searchResultsContent(matching trimmedSearchText: String) -> some View {
        let matchingEntries = CatalogAppDiscovery.discoverableApps(
            fromInventory: appInventoryService.inventoryEntries,
            matchingSearchText: trimmedSearchText
        )
        if matchingEntries.isEmpty {
            Text("No apps match \u{201C}\(trimmedSearchText)\u{201D}.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let shownEntries = Array(matchingEntries.prefix(CatalogAppDiscovery.maximumSearchResultsToShow))
            let hiddenCount = matchingEntries.count - shownEntries.count
            VStack(alignment: .leading, spacing: 4) {
                ForEach(shownEntries) { matchingEntry in
                    discoverAppRow(for: matchingEntry)
                }

                if hiddenCount > 0 {
                    Text("\(hiddenCount) more — keep typing to narrow it down.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: One app

    private func discoverAppRow(for discoverableEntry: CatalogAppInventoryEntry) -> some View {
        Button(action: { openPublikPage(for: discoverableEntry) }) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(discoverableEntry.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(subtitle(for: discoverableEntry))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer(minLength: 4)

                // A quiet "opens in your browser" cue, so tapping is understood
                // to leave Iris rather than install something in place.
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Open \(discoverableEntry.name) on publik. Iris never installs anything itself.")
    }

    /// A published release tag reads as "there is something to install today";
    /// its absence still gets a row, because the publik page is worth reaching
    /// even for an app whose release has not landed.
    private func subtitle(for discoverableEntry: CatalogAppInventoryEntry) -> String {
        if let latestReleaseTag = discoverableEntry.latestReleaseTag {
            return "\(latestReleaseTag) · view on publik"
        }
        return "View on publik"
    }

    private func openPublikPage(for discoverableEntry: CatalogAppInventoryEntry) {
        ExternalLinkPolicy.openExternalURLIfAllowed(
            appInventoryService.publikPageURLString(forSlug: discoverableEntry.slug)
        )
    }
}

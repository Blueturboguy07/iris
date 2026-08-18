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

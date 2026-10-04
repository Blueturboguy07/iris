#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// Unit M2-store-layout-implementation. The app page (design section 6,
/// WF-04), one scroll in a fixed order for every app: header, Get, what it
/// can do, screenshots, about, what's new, report or block, details, and for
/// installed apps a way to its versions, permissions and storage. The header
/// and Get come from the index at once; the rest fills in from the app page.
struct StoreAppPageView: View {
    @ObservedObject var store: StoreModel
    let slug: String
    let openInMyApps: (NativeShellAppIdentity) -> Void
    var displayNames: MyAppsDisplayNames = .empty
    @State private var confirmingBlock = false
    @State private var viewerIndex: Int?
    @Environment(\.openURL) private var openURL

    var body: some View {
        let ids = NativeAccessibilityIdentifiers.AppPage.self
        Group {
            if let app = store.app(slug) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            StoreAppHeader(store: store, app: app)
                            StoreGetNote(store: store, slug: slug, identifier: ids.note)
                        }
                        StoreAppDetailsSections(store: store, app: app, viewerIndex: $viewerIndex, confirmingBlock: $confirmingBlock, openInMyApps: openInMyApps, displayNames: displayNames)
                    }
                    .padding(16)
                    .frame(maxWidth: 800, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .navigationTitle(app.name)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if let url = StoreFlowInstallPipeline.appLink(slug: slug) {
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("Share")
                                .accessibilityIdentifier(ids.share)
                        }
                    }
                }
                .nativeConfirmationAlert("Block \(app.name) on this iPhone?",
                    message: "It disappears from Browse and Search. You can undo this from My apps, Blocked apps.",
                    isPresented: $confirmingBlock, actions: blockActions(app))
                .fullScreenCover(item: Binding(get: { viewerIndex.map(StoreViewerIndex.init) }, set: { viewerIndex = $0?.value })) { start in
                    StoreScreenshotViewer(store: store, slug: slug, start: start.value) { viewerIndex = nil }
                }
            } else if !store.hasCheckedOnce {
                // A link opened Iris before the list arrived: say so, never
                // "not on iPhone yet" for an app that may well be listed.
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Finding this app...").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(ids.detailsLoading)
            } else {
                StoreGoneView(message: store.freshness.isOffline && store.home.isEmpty
                              ? "You're offline, so Iris can't look up this app. Connect to the internet and open the link again. Installed apps still work in My apps."
                              : "This app is not on iPhone yet. Installed apps still work in My apps.") { store.perform(.back) }
                    .accessibilityIdentifier(ids.unavailable)
            }
        }
        .background(NativeMarketplaceStyle.paper)
        .foregroundStyle(NativeMarketplaceStyle.ink)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ids.root)
        .task(id: slug) { store.loadPage(slug) }
    }

    private func blockActions(_ app: StoreApp) -> [NativeConfirmationAction] {
        let ids = NativeAccessibilityIdentifiers.AppPage.self
        var actions = [NativeConfirmationAction(title: "Block", style: .destructive, identifier: ids.blockConfirm) {
            if let appId = store.identity(for: slug)?.appId { store.setBlocked(true, appId: appId) }
        }]
        if let target = store.reportTarget(for: slug) {
            actions.append(NativeConfirmationAction(title: "Report it instead", identifier: ids.blockReport) { openURL(target.url) })
        }
        actions.append(NativeConfirmationAction(title: "Cancel", style: .cancel, identifier: ids.blockCancel) {})
        return actions
    }
}

private struct StoreViewerIndex: Identifiable {
    let value: Int
    var id: Int { value }
}

/// SPEC 4.5: 96 pt icon, name, by line and a small Get capsule in the header
/// (bottom aligned with the icon); summary and facts line below. At
/// accessibility text sizes the header stacks.
struct StoreAppHeader: View {
    @ObservedObject var store: StoreModel
    let app: StoreApp
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconMetric: CGFloat = 96

    private var iconSize: CGFloat { min(iconMetric, 120) }

    var body: some View {
        let ids = NativeAccessibilityIdentifiers.AppPage.self
        VStack(alignment: .leading, spacing: 12) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    icon
                    nameBlock
                    get
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    icon
                    VStack(alignment: .leading, spacing: 0) {
                        nameBlock
                        Spacer(minLength: 8)
                        get
                    }
                    .frame(minHeight: iconSize, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !app.summary.isEmpty {
                    Text(app.summary).font(.subheadline).foregroundStyle(NativeMarketplaceStyle.fog).accessibilityIdentifier(ids.summary)
                }
                Text(facts).font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog).accessibilityIdentifier(ids.facts)
            }
        }
    }

    private var icon: some View {
        StoreIconView(app: app, cache: store.iconCache, size: iconSize)
            .accessibilityHidden(false)
            .accessibilityLabel("App icon for \(app.name)")
            .accessibilityIdentifier(NativeAccessibilityIdentifiers.AppPage.icon)
    }

    private var nameBlock: some View {
        let ids = NativeAccessibilityIdentifiers.AppPage.self
        return VStack(alignment: .leading, spacing: 2) {
            Text(app.name).font(.title2.bold()).lineLimit(typeSize.isAccessibilitySize ? nil : 2).accessibilityAddTraits(.isHeader).accessibilityIdentifier(ids.name)
            // RC-05: who made it, right under the name ("By Publik").
            Text(app.byLine).font(.subheadline).foregroundStyle(NativeMarketplaceStyle.fog).accessibilityIdentifier("iris.store.app.publisher")
        }
    }

    private var get: some View {
        StoreGetButton(store: store, slug: app.slug, identifier: NativeAccessibilityIdentifiers.AppPage.get, size: .page)
    }

    private var facts: String {
        var parts: [String] = []
        if let first = store.index.categoryNames(for: app).first { parts.append(first) }
        if let bytes = app.byteCount { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        if let rating = app.ageRating { parts.append("\(rating)+") } else { parts.append("Age rating not published yet") }
        return parts.joined(separator: " · ")
    }
}

/// Everything under the Get button, filled from the app page when it arrives.
struct StoreAppDetailsSections: View {
    @ObservedObject var store: StoreModel
    let app: StoreApp
    @Binding var viewerIndex: Int?
    @Binding var confirmingBlock: Bool
    let openInMyApps: (NativeShellAppIdentity) -> Void
    var displayNames: MyAppsDisplayNames = .empty
    @State private var showsFullDescription = false
    @ScaledMetric(relativeTo: .subheadline) private var detailIconWidth: CGFloat = 20

    private var page: PublikMobileCatalogAppPageV2? {
        if case .loaded(let page) = store.pages[app.slug] { return page }
        return nil
    }

    var body: some View {
        let ids = NativeAccessibilityIdentifiers.AppPage.self
        VStack(alignment: .leading, spacing: 24) {
            loadLine
            section("What it can do", identifier: ids.permissions) { permissions }
            if let page, !page.screenshots.isEmpty {
                section("Screenshots", identifier: ids.screenshots) { screenshots(page) }
            }
            if let page, !page.description.isEmpty {
                section("About this app", identifier: ids.description) { about(page.description) }
            }
            if let whatsNew = page?.whatsNew, !whatsNew.isEmpty {
                section("What's new", identifier: ids.whatsNew) {
                    Text(whatsNew).font(.subheadline)
                    if !app.updatedAt.isEmpty { Text("Updated \(app.updatedAt)").font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog) }
                }
            }
            section("Report or block", identifier: ids.reportBlock) { reportOrBlock }
            section("Details", identifier: ids.details) { details }
            if let entry = store.installedEntry(for: app.slug) {
                // unit M-store-screens (round3-deferred): design 12.5 asks
                // for three separate installed-only rows here
                // (versions-row, permissions-row, storage-row) rather than
                // one combined button, so a test or a VoiceOver user can
                // name which fact they are choosing. All three still land
                // on today's single "Versions & details" list
                // (`NativeShellAppView.appDetails`) -- the phone version
                // history unit owns building a dedicated Versions screen
                // (round3/mobile-versions/, frozen for this unit); these
                // rows are the "clear entry point to today's revision
                // list" this unit's brief asks for, not a new screen.
                // `NativeAccessibilityIdentifiers.AppPage` does not carry
                // these three yet (that enum's file is not in this unit's
                // owned paths); INTEGRATION_HOOKS.md gives its owner the
                // exact addition. The literal values match design 12.5 and
                // `NativeStoreIdentifiers` in M6's UI tests exactly.
                installedDetailRow(title: "Versions", systemImage: "clock.arrow.circlepath", identifier: NativeAccessibilityIdentifiers.AppPage.versionsRow) { openInMyApps(entry.identity) }
                installedDetailRow(title: "Permissions", systemImage: "hand.raised", identifier: NativeAccessibilityIdentifiers.AppPage.permissionsRow) { openInMyApps(entry.identity) }
                installedDetailRow(title: "Storage", systemImage: "internaldrive", identifier: NativeAccessibilityIdentifiers.AppPage.storageRow) { openInMyApps(entry.identity) }
                // MA2 SPEC 1.3: a renamed app says so on its own page.
                if let custom = displayNames.customName(identity: entry.identity.id) {
                    Text("You call this app \"\(custom)\".").font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                        .accessibilityIdentifier(NativeAccessibilityIdentifiers.MyApps.appCustomName)
                }
            }
        }
    }

    @ViewBuilder private var loadLine: some View {
        let ids = NativeAccessibilityIdentifiers.AppPage.self
        switch store.pages[app.slug] {
        case .loading:
            Text("Loading details...").font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog).accessibilityIdentifier(ids.detailsLoading)
        case .failed(let offline):
            VStack(alignment: .leading, spacing: 6) {
                Text(offline ? "Details are available when you're online." : "Couldn't load the details. The app can still be installed.")
                    .font(.footnote).accessibilityIdentifier(ids.detailsError)
                Button("Try again") { store.retryPage(app.slug) }.frame(minHeight: 44).accessibilityIdentifier(ids.detailsRetry)
            }
        case .loaded, nil:
            EmptyView()
        }
    }

    private func section<Content: View>(_ title: String, identifier: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var permissions: some View {
        if let page {
            ForEach(page.permissions, id: \.capability) { permission in
                Label { Text(permission.label) } icon: {
                    Image(systemName: "checkmark.circle").font(.title3).frame(width: detailIconWidth)
                }
                .font(.subheadline)
            }
            NativeCapabilityDisclosure(capabilities: page.permissions.map(\.capability), compact: true)
        } else if let entry = store.installedEntry(for: app.slug),
                  let revision = entry.revisions.first(where: { $0.revisionId == entry.currentRevisionId }) {
            NativeCapabilityDisclosure(capabilities: revision.requestedCapabilities, compact: true)
        } else {
            Text("Iris shows what this app can do before anything is installed. Phone permissions are asked the first time the app needs them.")
                .font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
        }
    }

    private func screenshots(_ page: PublikMobileCatalogAppPageV2) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(page.screenshots.prefix(6).enumerated()), id: \.offset) { position, shot in
                    Button { viewerIndex = position } label: {
                        AsyncImage(url: shot.url) { image in image.resizable().scaledToFit() } placeholder: {
                            RoundedRectangle(cornerRadius: 12).fill(NativeMarketplaceStyle.line.opacity(0.55)).frame(width: 100)
                        }
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Screenshot \(position + 1) of \(min(6, page.screenshots.count))")
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.AppPage.screenshot(position))
                }
            }
        }
    }

    @ViewBuilder private func about(_ text: String) -> some View {
        Text(String(text.prefix(2000))).font(.subheadline).lineLimit(showsFullDescription ? nil : 6)
        if text.count > 280 {
            Button(showsFullDescription ? "Show less" : "Read more") { showsFullDescription.toggle() }
                .frame(minHeight: 44)
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.AppPage.descriptionMore)
        }
    }

    @ViewBuilder private var reportOrBlock: some View {
        let catalog = NativeAccessibilityIdentifiers.Catalog.self
        if let target = store.reportTarget(for: app.slug) {
            VStack(alignment: .leading, spacing: 2) {
                Link("Report this app", destination: target.url).frame(minHeight: 44)
                    .accessibilityLabel("Report this app. Publik reads every report.")
                    .accessibilityHint("Opens your mail app with the details filled in.")
                    .accessibilityIdentifier(catalog.review47Report(app.slug))
                Text("Opens your mail app with the details filled in. Publik reads every report.")
                    .font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                    .accessibilityHidden(true)
            }
        }
        if let appId = store.identity(for: app.slug)?.appId, store.canBlock {
            let blocked = store.blockedAppIDs.contains(appId)
            VStack(alignment: .leading, spacing: 2) {
                Button(blocked ? "Unblock" : "Block this app on this iPhone") {
                    if blocked { store.setBlocked(false, appId: appId) } else { confirmingBlock = true }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier(catalog.review47BlockToggle(app.slug))
                Text(blocked ? "Blocked on this iPhone." : "Hides it from Browse and Search. You can undo this here.")
                    .font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
            }
        } else if store.reportTarget(for: app.slug) == nil {
            Text("Report and block are available once details load.").font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
        }
    }

    @ViewBuilder private var details: some View {
        let catalog = NativeAccessibilityIdentifiers.Catalog.self
        let entry = store.installedEntry(for: app.slug)
        detailRow("Updated", app.updatedAt.isEmpty ? "Not published" : app.updatedAt)
        detailRow("Size on this iPhone", entry?.totalVersionContentBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Not installed")
        if let rating = app.ageRating {
            detailRow("Age rating", "\(rating)+").accessibilityIdentifier(catalog.review47AgeRating(app.slug))
        } else {
            Text("Age rating and privacy information have not been published for this app yet.")
                .font(.footnote).accessibilityIdentifier(catalog.review47NotRated(app.slug))
        }
        if let page {
            Link("Support", destination: page.supportURL).frame(minHeight: 44)
            Text(page.privacySummary).font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                .accessibilityIdentifier(catalog.review47PrivacySummary(app.slug))
        }
    }

    private func installedDetailRow(title: String, systemImage: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label { Text(title) } icon: {
                    Image(systemName: systemImage).font(.title3).frame(width: detailIconWidth)
                }
                Spacer()
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .font(.subheadline)
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(NativeMarketplaceStyle.fog) }
            .font(.subheadline)
            .accessibilityElement(children: .combine)
    }
}

/// Full-screen screenshots: swipe between them, Close or swipe down.
struct StoreScreenshotViewer: View {
    @ObservedObject var store: StoreModel
    let slug: String
    let start: Int
    let close: () -> Void
    @State private var selection = 0

    var body: some View {
        let shots: [PublikMobileCatalogScreenshotV2] = {
            if case .loaded(let page) = store.pages[slug] { return Array(page.screenshots.prefix(6)) }
            return []
        }()
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(Array(shots.enumerated()), id: \.offset) { position, shot in
                    AsyncImage(url: shot.url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                        .tag(position)
                        .accessibilityLabel("Screenshot \(position + 1) of \(shots.count)")
                }
            }
            .tabViewStyle(.page)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: close).accessibilityIdentifier(NativeAccessibilityIdentifiers.AppPage.screenshotViewerClose)
                }
            }
        }
        .onAppear { selection = start }
        .gesture(DragGesture().onEnded { if $0.translation.height > 120 { close() } })
        .accessibilityIdentifier(NativeAccessibilityIdentifiers.AppPage.screenshotViewer)
    }
}
#endif

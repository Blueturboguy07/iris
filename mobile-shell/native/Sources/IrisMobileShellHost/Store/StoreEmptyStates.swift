#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// Unit M2-store-layout-implementation: every loading, empty, offline, stale
/// and error message the store shows (design section 10), each with a way
/// forward. Copy is plain: one idea per sentence.

/// The quiet line under "Browse" (design 3.4) with Try again when it helps.
struct StoreStatusLineView: View {
    @ObservedObject var store: StoreModel

    var body: some View {
        let hasRows = !store.index.visibleApps.isEmpty
        HStack(spacing: 8) {
            if case .checking = store.freshness { ProgressView().controlSize(.small).accessibilityHidden(true) }
            Text(StoreStatusLine.text(store.freshness, hasRows: hasRows, showingBundledSeed: store.isShowingBundledSeed))
                .font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Home.status)
            if store.freshness.canRetry {
                Button("Try again") { store.retryCatalog() }
                    .font(.footnote.weight(.semibold)).frame(minHeight: 44)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Home.retry)
            }
        }
    }
}

/// Home with nothing to show: published nothing, or never loaded.
struct StoreHomeEmptyView: View {
    @ObservedObject var store: StoreModel
    let openMyApps: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).font(.subheadline)
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Home.empty)
            if store.freshness.canRetry {
                Button("Try again") { store.retryCatalog() }
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.load)
            }
            Button("Open My apps") { openMyApps() }
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Home.emptyOpenMyApps)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }

    private var message: String {
        switch store.freshness {
        case .checking: return "Looking for apps. Installed apps already work in My apps."
        case .offline: return "You're offline and Iris hasn't loaded the app list yet. Installed apps still work in My apps."
        case .failed: return "Iris couldn't check the list of apps. Nothing was changed. Installed apps still work in My apps."
        case .fresh, .stale: return "No apps are published for iPhone yet. Installed apps still work in My apps."
        }
    }
}

/// Search's offline banner (design 4.1 item 5).
struct StoreOfflineBanner: View {
    @ObservedObject var store: StoreModel

    var body: some View {
        if !store.isOnline || store.freshness.isOffline {
            Text(text)
                .font(.footnote)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(NativeMarketplaceStyle.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Search.offline)
        }
    }

    private var text: String {
        if let last = store.freshness.lastChecked, !store.index.visibleApps.isEmpty {
            return "You're offline. Showing apps from your last check, \(StoreStatusLine.when(last, now: Date(), calendar: .current, locale: .current, style: .showing)). Get needs a connection."
        }
        return "You're offline. Get needs a connection."
    }
}

/// "Still loading the full list (2 of 4)..." while later pages arrive.
struct StorePartialListFooter: View {
    let index: StoreCatalogIndex

    var body: some View {
        if case .indexV2(_, let loaded, let count) = index.source, loaded < count {
            Text("Still loading the full list (\(loaded) of \(count))...")
                .font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Search.partial)
        }
    }
}

/// The "How we pick these" sheet (design 14).
struct StoreHowWePickSheet: View {
    let close: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                // RC-06 (apple-compliance/REQUIRED_CHANGES.md): the old
                // wording promised sponsored apps are "never mixed into
                // search results", but search never excluded them (only
                // never let sponsorship change the order). Reworded to match
                // what the code actually does: search stays organic and
                // simply never shows the Sponsored badge there, because
                // "Sponsored" only ever describes a paid shelf placement.
                Text("Featured apps are picked by people at Publik. Search results are ordered by how well the name and description match what you typed, then by what was updated most recently. Some apps pay to appear in a shelf; those are marked Sponsored there. Search results are never paid for.")
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("How we pick these").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close", action: close)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Home.howWePickClose)
                }
            }
        }
        .presentationDetents([.medium])
        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Home.howWePick)
    }
}
#endif

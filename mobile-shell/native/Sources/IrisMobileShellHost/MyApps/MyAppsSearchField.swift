#if os(iOS)
import SwiftUI

// Unit MA2 my-apps-screen. SPEC 1.1 item 2: shown at 12+ installed apps,
// "7 of your apps match \"cl\"", clearing restores the groups at the same
// scroll position (handled by the caller keeping the same `ScrollView`/`List`
// on screen and only swapping its rows, not by this view).
struct MyAppsSearchFieldView: View {
    @Binding var query: String
    let isSearching: Bool
    let matchCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(NativeMarketplaceStyle.fog)
                TextField("Search my apps", text: $query)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(.body).padding(.vertical, 8)
                    .accessibilityIdentifier("iris.store.my-apps.search")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(NativeMarketplaceStyle.fog)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Clear search")
                    .accessibilityIdentifier("iris.store.my-apps.search.clear")
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 10)
            .background(NativeMarketplaceStyle.line.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

            if isSearching {
                Text(matchCount == 1 ? "1 of your apps matches \"\(query)\"." : "\(matchCount) of your apps match \"\(query)\".")
                    .font(.caption).foregroundStyle(NativeMarketplaceStyle.fog)
                    .accessibilityIdentifier("iris.store.my-apps.search.count")
            }
        }
    }
}

/// SPEC 1.6: "Search with no match": "None of your apps match \"xy\"." plus
/// "Search the store instead".
struct MyAppsSearchZeroStateView: View {
    let query: String
    let searchStore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("None of your apps match \"\(query)\".")
                .font(.subheadline).foregroundStyle(NativeMarketplaceStyle.fog)
                .accessibilityIdentifier("iris.store.my-apps.search.zero")
            Button("Search the store instead", action: searchStore)
                .frame(minHeight: 44)
                .accessibilityIdentifier("iris.store.my-apps.search.zero.store")
        }
        .padding(.vertical, 8)
    }
}
#endif

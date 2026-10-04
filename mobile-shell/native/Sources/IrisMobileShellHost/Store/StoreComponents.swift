#if os(iOS)
import ImageIO
import IrisMobileShellCore
import SwiftUI
import UIKit

/// Unit M2-store-layout-implementation: the pieces every store screen shares.
/// Colors and type come only from `NativeMarketplaceStyle` and the existing
/// views; nothing here adds a color, glass or motion token.

/// The app's own icon, decoded at display size; the app's initial until the
/// bytes arrive or when there are none. Never another app's artwork.
struct StoreIconView: View {
    let app: StoreApp
    let cache: StoreIconCache?
    let size: CGFloat
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                StoreInitialTile(name: app.name, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
        .accessibilityHidden(true)
        .task(id: app.iconHash) { await load() }
    }

    private func load() async {
        image = nil
        guard let cache, app.iconHash != nil, let data = await cache.iconData(for: app) else { return }
        image = Self.downsample(data, pixels: size * displayScale)
    }

    /// ImageIO thumbnail at the size shown, never the full file (design 13.3).
    static func downsample(_ data: Data, pixels: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbnail = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(pixels)),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The placeholder: the app's initial on the existing electric tile.
struct StoreInitialTile: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(NativeMarketplaceStyle.electric)
    }
}

/// Where a Get capsule is drawn (store proportions SPEC 4.2). Visual size and
/// tap area are separate: the capsule is drawn small, the hit area is 44 pt.
enum StoreCapsuleSize {
    case row, card, page

    /// Drawn height at the default text size; it grows with the text
    /// (text height plus 10) and is at least 44 from the first accessibility
    /// size up.
    var minHeight: CGFloat {
        switch self {
        case .row: return 30
        case .card: return 28
        case .page: return 32
        }
    }

    /// One width for every state in a row, so the text column does not
    /// re-wrap from Get to 42% to Verifying (SPEC 4.2, check 8).
    var minWidth: CGFloat {
        switch self {
        case .row: return 96
        case .card: return 0
        case .page: return 96
        }
    }

    var font: Font {
        switch self {
        case .row: return .subheadline.weight(.semibold)
        case .card: return .footnote.weight(.semibold)
        case .page: return .headline
        }
    }
}

/// The one Get control (design 6.2): label carries the state, progress fills
/// the capsule in place, a tap during progress changes nothing.
struct StoreGetButton: View {
    @ObservedObject var store: StoreModel
    let slug: String
    let identifier: String
    var size: StoreCapsuleSize = .row
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = store.buttonState(for: slug)
        let name = store.app(slug)?.name ?? slug
        if state.isActionable {
            Button { store.tapGet(slug) } label: { Text(Self.visibleLabel(state, size: size)) }
                .buttonStyle(StoreGetStyle(size: size,
                                           solid: size == .page,
                                           ink: state.kind == .open || state.kind == .blocked,
                                           busy: state.isBusy,
                                           percent: fillPercent(state)))
                .accessibilityLabel(state.accessibilityLabel(appName: name))
                .accessibilityValue(state.accessibilityValue)
                .accessibilityHint(state.kind == .get ? "Downloads and installs \(name). Nothing else is needed." : "")
                .accessibilityIdentifier(identifier)
        } else {
            Text(state.label)
                .font(.footnote)
                .foregroundStyle(NativeMarketplaceStyle.fog)
                .frame(minHeight: 44)
                .accessibilityLabel(state.accessibilityLabel(appName: name))
                .accessibilityValue(state.accessibilityValue)
                .accessibilityIdentifier(identifier)
        }
    }

    /// The words drawn in the capsule. Rows and cards use one short word so
    /// the capsule never changes width; the app page keeps the full label.
    /// VoiceOver still reads the full sentence (`accessibilityLabel`).
    static func visibleLabel(_ state: StoreInstallButtonState, size: StoreCapsuleSize) -> String {
        guard size != .page else { return state.label }
        switch state.kind {
        case .downloading: return state.percent.map { "\($0)%" } ?? "Loading"
        case .failed: return "Retry"
        case .restricted: return "Check age"
        default: return state.label
        }
    }

    /// Reduce Motion: the fill jumps in 10 percent steps.
    private func fillPercent(_ state: StoreInstallButtonState) -> Int? {
        guard state.isBusy, let percent = state.percent else { return nil }
        return reduceMotion ? (percent / 10) * 10 : percent
    }
}

/// The capsule itself, drawn from the existing tokens. Tonal (the `line`
/// token at 40 percent, `electric` text: about 4.6 to 1) in rows and cards;
/// solid `electric` with white text only for the one Get on the app page.
/// Busy and disabled capsules use the specified 60 percent opacity.
struct StoreGetStyle: ButtonStyle {
    var size: StoreCapsuleSize = .row
    var solid = false
    var ink = false
    var busy = false
    var percent: Int?

    func makeBody(configuration: Configuration) -> some View {
        StoreCapsuleBody(configuration: configuration, style: self)
    }
}

private struct StoreCapsuleBody: View {
    let configuration: ButtonStyleConfiguration
    let style: StoreGetStyle
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .subheadline) private var rowWidth: CGFloat = 96

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(style.size.font)
            .lineLimit(style.size == .page || typeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(textColor)
            .padding(.horizontal, 10).padding(.vertical, 5)
            // Reserve one scaled width for every row state, including Verifying.
            .frame(width: style.size == .row && !typeSize.isAccessibilitySize ? rowWidth : nil)
            .frame(minWidth: style.size == .row && typeSize.isAccessibilitySize ? 96 : style.size.minWidth,
                   maxWidth: style.size == .card ? CGFloat.infinity : nil,
                   minHeight: typeSize.isAccessibilitySize ? 44 : style.size.minHeight)
            .background(fill)
            .opacity((!isEnabled || style.busy ? 0.6 : 1) * (pressed ? 0.7 : 1))
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            // The tap area: 44 pt tall, the capsule's width, never drawn.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }

    private var textColor: Color {
        if style.solid { return .white }
        if style.ink { return NativeMarketplaceStyle.ink }
        return NativeMarketplaceStyle.electric
    }

    private var fill: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(style.solid ? NativeMarketplaceStyle.electric : NativeMarketplaceStyle.line.opacity(0.4))
                if let percent = style.percent {
                    Capsule().fill(style.solid ? NativeMarketplaceStyle.line.opacity(0.45) : NativeMarketplaceStyle.line)
                        .frame(width: proxy.size.width * CGFloat(percent) / 100)
                }
            }
        }
    }
}

/// The main action of a screen, drawn at 48 pt (Storage "Free up space").
struct StoreMainActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(.white)
            .background(NativeMarketplaceStyle.electric, in: Capsule())
            .opacity(!isEnabled ? 0.6 : (configuration.isPressed ? 0.7 : 1))
            .contentShape(Capsule())
    }
}

/// The store's list gutter and row separator (SPEC 4.3): 16 pt in from the
/// screen edge everywhere; the separator starts at the text, not the icon.
extension View {
    func storeListInsets() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    /// Store rows draw their own separator, so the list's is hidden.
    func storeListRow() -> some View {
        storeListInsets().listRowSeparator(.hidden)
    }
}

/// The small note under a Get button (offline, busy, failure, reason). The
/// Cancel button sits on the same line while a download runs (SPEC 4.5).
struct StoreGetNote: View {
    @ObservedObject var store: StoreModel
    let slug: String
    let identifier: String
    /// Left indent, so a row's note lines up under its text.
    var indent: CGFloat = 0

    var body: some View {
        let state = store.buttonState(for: slug)
        if state.note != nil || state.kind == .downloading {
            HStack(alignment: .center, spacing: 8) {
                if let note = state.note {
                    Text(note).font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(identifier)
                }
                Spacer(minLength: 0)
                if state.kind == .downloading {
                    Button("Cancel") { store.cancelGet(slug) }
                        .font(.footnote).frame(minHeight: 44)
                        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.cancel)
                }
            }
            .padding(.leading, indent)
        }
    }
}

/// The "Sponsored" tag: on the icon row, trailing, above the name (design 14).
struct StoreSponsoredTag: View {
    let identifier: String
    var body: some View {
        Text("Sponsored")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(NativeMarketplaceStyle.fog)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().stroke(NativeMarketplaceStyle.line))
            .accessibilityIdentifier(identifier)
    }
}

/// RC-02 (e): the rating capsule, shown whenever an app is rated above the
/// shell's own rating (13), on cards and rows. Spoken as part of the card
/// label ("Rated 16+ ..."), so it is hidden from VoiceOver on its own.
struct StoreRatingCapsule: View {
    let rating: Int
    let identifier: String
    var body: some View {
        Text("\(rating)+")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(NativeMarketplaceStyle.fog)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().stroke(NativeMarketplaceStyle.line))
            .accessibilityLabel("Rated \(rating)+")
            .accessibilityIdentifier(identifier)
    }
}

enum StoreSpeech {
    /// "<name>, <summary>, <Get or Open or Update>" plus the tags (design 12.7).
    static func cardLabel(_ app: StoreApp, state: StoreInstallButtonState, sponsored: Bool) -> String {
        var parts = [app.name]
        if !app.summary.isEmpty { parts.append(app.summary) }
        parts.append(state.label)
        if sponsored { parts.append("Sponsored") }
        if state.kind == .update { parts.append("Update available") }
        return parts.joined(separator: ", ")
    }
}

/// A shelf card (design 3.5, SPEC 4.4): 124 pt wide, at least 160 tall, icon,
/// optional tag, name, summary, a 28 pt Get capsule with a 44 pt tap area. The
/// text part is one element; Get is its own control so it can be reached by
/// identifier and by VoiceOver's actions.
struct StoreCardView: View {
    @ObservedObject var store: StoreModel
    let card: StoreShelfCard
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconMetric: CGFloat = 48

    var body: some View {
        if let app = store.app(card.slug) {
            let ids = NativeAccessibilityIdentifiers.Card.self
            VStack(alignment: .leading, spacing: 0) {
                Button(action: open) {
                    info(app).accessibilityHidden(true)
                }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(StoreSpeech.cardLabel(app, state: store.buttonState(for: app.slug), sponsored: card.isSponsored))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: Text(store.buttonState(for: app.slug).label)) { store.tapGet(app.slug) }
                    .accessibilityIdentifier(ids.card(app.slug))
                StoreGetButton(store: store, slug: app.slug, identifier: ids.get(app.slug), size: .card)
            }
            // The capsule's 44 pt hit frame includes its bottom 8 pt padding.
            .padding(.horizontal, 8).padding(.top, 8)
            .frame(width: typeSize.isAccessibilitySize ? nil : 124, alignment: .leading)
            .frame(minHeight: 160, alignment: .top)
            .background(NativeMarketplaceStyle.paper)
            .overlay(RoundedRectangle(cornerRadius: NativeMarketplaceStyle.cardRadius).stroke(NativeMarketplaceStyle.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: NativeMarketplaceStyle.cardRadius))
        }
    }

    private func info(_ app: StoreApp) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                StoreIconView(app: app, cache: store.iconCache, size: min(iconMetric, 64))
                Spacer(minLength: 4)
                if let rating = app.ageRating, rating > Review47AppStoreMetadata.shellAgeRating {
                    StoreRatingCapsule(rating: rating, identifier: NativeAccessibilityIdentifiers.Card.rating(app.slug))
                }
                if card.isSponsored { StoreSponsoredTag(identifier: NativeAccessibilityIdentifiers.Card.sponsored(app.slug)) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(NativeMarketplaceStyle.ink)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Card.name(app.slug))
                Text(app.summary.isEmpty ? " " : app.summary).font(.caption)
                    .foregroundStyle(NativeMarketplaceStyle.fog).lineLimit(2, reservesSpace: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A list row (design 3.6, SPEC 4.3): used by All apps, category pages,
/// search results. 56 pt icon, name and summary, a small Get capsule whose tap
/// area is 44 pt and does not overlap the row's own tap. At accessibility
/// text sizes the capsule drops under the text.
struct StoreRowView: View {
    @ObservedObject var store: StoreModel
    let slug: String
    let sponsored: Bool
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconMetric: CGFloat = 56

    private var iconSize: CGFloat { min(iconMetric, 72) }

    /// Checked here so a row with no note adds no gap to its height (76 pt pitch).
    private var hasNote: Bool {
        let state = store.buttonState(for: slug)
        return state.note != nil || state.kind == .downloading
    }

    var body: some View {
        if let app = store.app(slug) {
            let ids = NativeAccessibilityIdentifiers.Row.self
            let stacked = typeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: 4) {
                if stacked {
                    VStack(alignment: .leading, spacing: 12) {
                        infoButton(app, trailingGap: 0)
                        getButton(ids).padding(.leading, iconSize + 12)
                    }
                } else {
                    HStack(spacing: 0) {
                        infoButton(app, trailingGap: 12)
                        getButton(ids)
                    }
                }
                if hasNote {
                    StoreGetNote(store: store, slug: slug, identifier: ids.note(slug), indent: iconSize + 12)
                }
            }
            // The 56 pt icon plus 10 pt on each side gives the 76 pt minimum.
            .padding(.vertical, 10)
            .frame(minHeight: 76, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(NativeMarketplaceStyle.line).frame(height: 0.5)
                    .padding(.leading, iconSize + 12)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(StoreSpeech.cardLabel(app, state: store.buttonState(for: slug), sponsored: sponsored))
            .accessibilityIdentifier(ids.row(slug))
            .storeListRow()
        }
    }

    private func infoButton(_ app: StoreApp, trailingGap: CGFloat) -> some View {
        let ids = NativeAccessibilityIdentifiers.Row.self
        return Button(action: open) {
            info(app).padding(.trailing, trailingGap).contentShape(Rectangle())
                .accessibilityHidden(true)
        }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StoreSpeech.cardLabel(app, state: store.buttonState(for: slug), sponsored: sponsored))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text(store.buttonState(for: slug).label)) { store.tapGet(slug) }

    }

    private func getButton(_ ids: NativeAccessibilityIdentifiers.Row.Type) -> some View {
        StoreGetButton(store: store, slug: slug, identifier: ids.get(slug))
            .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
    }

    private func info(_ app: StoreApp) -> some View {
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            StoreIconView(app: app, cache: store.iconCache, size: iconSize)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(app.name).font(.headline).lineLimit(typeSize.isAccessibilitySize ? nil : (typeSize > .large ? 3 : 1))
                    if let rating = app.ageRating, rating > Review47AppStoreMetadata.shellAgeRating {
                        StoreRatingCapsule(rating: rating, identifier: NativeAccessibilityIdentifiers.Row.rating(app.slug))
                    }
                    if sponsored { StoreSponsoredTag(identifier: NativeAccessibilityIdentifiers.Row.sponsored(app.slug)) }
                }
                if !app.summary.isEmpty {
                    Text(app.summary).font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                        .lineLimit(typeSize > .large ? 4 : 2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
    }
}
#endif

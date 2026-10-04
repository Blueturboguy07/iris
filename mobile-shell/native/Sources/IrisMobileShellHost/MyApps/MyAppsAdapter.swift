#if os(iOS)
import Foundation
import IrisMobileShellCore

// Unit MA2 my-apps-screen. Turns `NativeShellLibraryEntry` (Core) plus
// `StoreCatalogIndex`/`StoreModel` (Host, M2-store-layout-implementation)
// into MA1's small, catalog-free input structs (SPEC integration point 5:
// "MA1's input struct isolates the screen from it"). Nothing here writes
// anything back into the library or the catalog -- this file only reads
// them, which is what keeps SPEC 5.5 mutant #2 ("Rename written into the
// package manifest") structurally impossible from this unit's own code.
//
// `@MainActor`: every member reads `StoreModel`, which is itself
// `@MainActor`-isolated (`Store/StoreModel.swift`). Unlike `StoreMyAppsView`
// (a `View`, whose whole type is inferred `@MainActor` through `View.body`'s
// own `@MainActor` requirement), this is a plain `enum`, so without this
// annotation the real compiler (not just this unit's own `-parse`-only
// syntax check) rejects every call into `store` here as a cross-actor call
// from a nonisolated context -- confirmed by a real `mobile-ios-typecheck.sh`
// run this session; see HANDOFF.md's "Gates" section for the exact errors
// this fixed.
@MainActor
enum MyAppsAdapter {
    static func appInputs(library: [NativeShellLibraryEntry], store: StoreModel, starterNames: [String: String] = [:]) -> [MyAppsAppInput] {
        library.map { entry in
            let slug = store.knownSlug(for: entry.identity)
            let app = slug.flatMap { store.index.app(slug: $0) }
            return MyAppsAppInput(
                identity: entry.identity.id,
                originalName: entry.displayName,
                descriptionLine: descriptionLine(entry: entry, app: app),
                categoryIds: app?.categoryIds ?? [],
                sizeBytes: entry.totalVersionContentBytes.map(Int64.init),
                hasUpdate: store.hasListedUpdate(for: entry),
                isBlocked: store.canBlock && store.blockedAppIDs.contains(entry.identity.appId),
                hasCatalogSlug: slug != nil,
                // Offloading (SPEC 1.6's "Offloaded app" row, mobile-versions
                // 1.4) is not built yet anywhere in the shell; every installed
                // app's files are always present today, so this is always
                // false rather than guessed. Wiring a real signal in is a
                // mobile-versions (MV) concern, not this screen's.
                needsDownload: false,
                catalogName: catalogName(app: app, identity: entry.identity, starterNames: starterNames)
            )
        }
    }

    /// Starter names must be keyed by the exact installed identity, never
    /// inferred from a manifest name or a bundled folder label.
    static func displayNames(
        library: [NativeShellLibraryEntry],
        store: StoreModel,
        arrangement: MyAppsArrangement,
        starterNames: [String: String] = [:]
    ) -> MyAppsDisplayNames {
        var names: [String: String] = [:]
        for entry in library {
            let app = store.knownSlug(for: entry.identity).flatMap { store.index.app(slug: $0) }
            names[entry.identity.id] = catalogName(app: app, identity: entry.identity, starterNames: starterNames)
        }
        return MyAppsDisplayNames(arrangement: arrangement, catalogNames: names)
    }

    private static func catalogName(app: StoreApp?, identity: NativeShellAppIdentity, starterNames: [String: String]) -> String? {
        if let name = app?.name,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return starterNames[identity.id].flatMap { name in
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        }
    }

    static func categoryInputs(store: StoreModel) -> [MyAppsCategoryInput] {
        store.index.categories.map { MyAppsCategoryInput(id: $0.id, name: $0.name, order: $0.order) }
    }

    /// SPEC 1.1: "the catalog `summary` for the app's slug (index v2, at
    /// most 80 characters) when the catalog knows the app; otherwise the
    /// line M-store-screens already draws." Mirrors `StoreMyAppsView`'s
    /// pre-existing `rowSubtitle(_:)` for the fallback so this design only
    /// adds a preferred source, it never changes what a person already saw
    /// for an app the catalog cannot describe (an imported package, or the
    /// catalog offline for the whole run, persona P3).
    private static func descriptionLine(entry: NativeShellLibraryEntry, app: StoreApp?) -> String {
        if let summary = app?.summary, !summary.isEmpty {
            return String(summary.prefix(80))
        }
        var parts: [String] = []
        if let bytes = entry.totalVersionContentBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        if let current = entry.revisions.first(where: { $0.revisionId == entry.currentRevisionId }) {
            parts.append("updated \(String(current.createdAt.prefix(10)))")
        }
        return parts.isEmpty
            ? "\(entry.revisions.count) stored version\(entry.revisions.count == 1 ? "" : "s")"
            : parts.joined(separator: " · ")
    }
}

/// Read-only display-name lookup shared by every screen that shows an
/// installed app's name (SPEC 1.3: "What the name changes: the row, the
/// tile, ... the Storage 'By app' rows, the Blocked apps rows, ... the
/// full-screen app's title bar ..."). Kept as a small, dependency-free value
/// type (not the store itself) so it is trivial for `INTEGRATION_HOOKS.md`
/// to hand to `StoreStorageView`/`StoreBlockedAppsView`/`StoreAppPageView`
/// (owned by other units) without those files needing to import anything
/// about folders, sort or search.
public struct MyAppsDisplayNames: Sendable {
    private let customNames: [String: String]
    private let catalogNames: [String: String]

    public init(arrangement: MyAppsArrangement, catalogNames: [String: String] = [:]) {
        var names: [String: String] = [:]
        for (identity, entry) in arrangement.apps {
            if let name = entry.name { names[identity] = name }
        }
        self.customNames = names
        self.catalogNames = catalogNames.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public static let empty = MyAppsDisplayNames(arrangement: .empty)

    /// `identity` is `NativeShellAppIdentity.id` ("appId::projectId"), the
    /// same key `MyAppsArrangement` uses everywhere.
    public func name(identity: String, fallback: String) -> String {
        customNames[identity] ?? catalogNames[identity] ?? fallback
    }

    public func customName(identity: String) -> String? { customNames[identity] }
}
#endif

import Foundation
import IrisMobileShellCore

/// The one list of accessibility identifiers for the Iris Apps shell (SPEC
/// section 1: the contract between UI tests and views). Values follow
/// `iris.<area>.<element>`, are never built from display text, and never
/// change once shipped. Suffixes are data: a slug, an app id, a revision id,
/// a category id or a position. Existing values moved here byte for byte.
/// Design reference: MOBILE_STORE_DESIGN.md section 12.
public enum NativeAccessibilityIdentifiers {
    // MARK: tab bar and shell (12.1)
    public enum Tabs {
        public static let bar = "iris.store.tabs"
        public static let browse = "iris.store.tab.browse"
        public static let search = "iris.store.tab.search"
        public static let myApps = "iris.store.tab.my-apps"
        public static let myAppsBadge = "iris.store.tab.my-apps.badge"
        public static let runtimeUnavailable = "iris.runtime.unavailable"
        public static let websitePending = "iris.website.pending"
        public static let websitePendingDismiss = "iris.website.pending.dismiss"
        public static let websitePendingContinue = "iris.website.pending.continue"
        /// R6 hook H5: the consent sheet's "By Publik" line.
        public static let websiteInstallPublisher = "iris.website.install.publisher"
    }

    // MARK: existing catalogue values (kept exactly)
    public enum Catalog {
        public static let load = "iris.catalog.load"
        public static let counts = "iris.catalog.counts"
        public static let unavailable = "iris.catalog.unavailable"
        public static let error = "iris.catalog.error"
        public static let stale = "iris.catalog.stale"
        public static let cancel = "iris.catalog.cancel"
        public static let retry = "iris.catalog.retry"
        public static func download(_ slug: String) -> String { "iris.catalog.download.\(slug)" }
        public static func open(_ slug: String) -> String { "iris.catalog.open.\(slug)" }
        public static func review47Restricted(_ slug: String) -> String { "iris.catalog.review47.restricted.\(slug)" }
        public static func review47AgeRating(_ slug: String) -> String { "iris.catalog.review47.age-rating.\(slug)" }
        public static func review47PrivacySummary(_ slug: String) -> String { "iris.catalog.review47.privacy-summary.\(slug)" }
        public static func review47Report(_ slug: String) -> String { "iris.catalog.review47.report.\(slug)" }
        public static func review47BlockToggle(_ slug: String) -> String { "iris.catalog.review47.block-toggle.\(slug)" }
        public static func review47NotRated(_ slug: String) -> String { "iris.catalog.review47.not-rated.\(slug)" }
    }

    // MARK: Home (12.2)
    public enum Home {
        public static let root = "iris.store.home"
        public static let status = "iris.store.home.status"
        public static let retry = "iris.store.home.retry"
        public static let searchEntry = "iris.store.home.search-entry"
        public static let categoryRow = "iris.store.home.category-row"
        public static func categoryChip(_ id: Int) -> String { "iris.store.home.category-chip.\(id)" }
        public static let categoryAll = "iris.store.home.category-all"
        public static let allApps = "iris.store.home.all-apps"
        public static let featured = "iris.store.home.shelf.featured"
        public static let featuredHow = "iris.store.home.shelf.featured.how"
        public static let new = "iris.store.home.shelf.new"
        public static let newSeeAll = "iris.store.home.shelf.new.see-all"
        public static func categoryShelf(_ id: Int) -> String { "iris.store.home.shelf.category.\(id)" }
        public static func categoryShelfSeeAll(_ id: Int) -> String { "iris.store.home.shelf.category.\(id).see-all" }
        public static let browseAllCategories = "iris.store.home.browse-all-categories"
        public static let empty = "iris.store.home.empty"
        public static let emptyOpenMyApps = "iris.store.home.empty.open-my-apps"
        public static let footer = "iris.store.home.footer"
        public static let howWePick = "iris.store.how-we-pick"
        public static let howWePickClose = "iris.store.how-we-pick.close"
    }

    // MARK: cards and rows (3.5, 3.6, 14)
    public enum Card {
        public static func card(_ slug: String) -> String { "iris.store.card.\(slug)" }
        public static func get(_ slug: String) -> String { "iris.store.card.\(slug).get" }
        public static func sponsored(_ slug: String) -> String { "iris.store.card.\(slug).sponsored" }
        public static func name(_ slug: String) -> String { "iris.store.card.\(slug).name" }
        public static func rating(_ slug: String) -> String { "iris.store.card.\(slug).rating" }
    }

    public enum Row {
        public static func row(_ slug: String) -> String { "iris.store.row.\(slug)" }
        public static func get(_ slug: String) -> String { "iris.store.row.\(slug).get" }
        public static func note(_ slug: String) -> String { "iris.store.row.\(slug).note" }
        public static func sponsored(_ slug: String) -> String { "iris.store.row.\(slug).sponsored" }
        public static func rating(_ slug: String) -> String { "iris.store.row.\(slug).rating" }
    }

    // MARK: Search (12.3)
    public enum Search {
        /// Kept from the old shared header field.
        public static let field = "iris.marketplace.search"
        public static let clear = "iris.store.search.clear"
        public static let recent = "iris.store.search.recent"
        public static func recentItem(_ position: Int) -> String { "iris.store.search.recent.\(position)" }
        public static let recentClear = "iris.store.search.recent-clear"
        public static let categories = "iris.store.search.categories"
        public static let count = "iris.store.search.count"
        public static let results = "iris.store.search.results"
        public static let zero = "iris.store.search.zero"
        public static let zeroCategories = "iris.store.search.zero-categories"
        public static let browseAll = "iris.store.search.browse-all"
        public static let offline = "iris.store.search.offline"
        public static let partial = "iris.store.search.partial"
    }

    // MARK: Category and All categories (12.4)
    public enum Category {
        public static let root = "iris.store.category"
        public static let title = "iris.store.category.title"
        public static let count = "iris.store.category.count"
        public static let list = "iris.store.category.list"
        public static let loadingMore = "iris.store.category.loading-more"
        public static let empty = "iris.store.category.empty"
        public static let gone = "iris.store.category.gone"
        public static let allRoot = "iris.store.categories"
        public static func allRow(_ id: Int) -> String { "iris.store.categories.row.\(id)" }
    }

    // MARK: App page (12.5)
    public enum AppPage {
        public static let root = "iris.store.app"
        public static let share = "iris.store.app.share"
        public static let icon = "iris.store.app.icon"
        public static let name = "iris.store.app.name"
        public static let summary = "iris.store.app.summary"
        public static let facts = "iris.store.app.facts"
        public static let get = "iris.store.app.get"
        public static let note = "iris.store.app.note"
        public static let permissions = "iris.store.app.permissions"
        public static let screenshots = "iris.store.app.screenshots"
        public static func screenshot(_ position: Int) -> String { "iris.store.app.screenshot.\(position)" }
        public static let publisher = "iris.store.app.publisher"
        public static let description = "iris.store.app.description"
        public static let descriptionMore = "iris.store.app.description.more"
        public static let whatsNew = "iris.store.app.whats-new"
        public static let details = "iris.store.app.details"
        public static let detailsLoading = "iris.store.app.details-loading"
        public static let detailsError = "iris.store.app.details-error"
        public static let detailsRetry = "iris.store.app.details-retry"
        public static let ageCheck = "iris.store.app.age-check"
        public static let blockConfirm = "iris.store.app.block-confirm"
        public static let blockCancel = "iris.store.app.block-cancel"
        public static let blockReport = "iris.store.app.block-report"
        public static let unavailable = "iris.store.app.unavailable"
        public static let openInMyApps = "iris.store.app.my-apps-row"
        public static let reportBlock = "iris.store.app.report-block"
        public static let screenshotViewer = "iris.store.app.screenshot-viewer"
        public static let screenshotViewerClose = "iris.store.app.screenshot-viewer.close"
        public static let versionsRow = "iris.store.app.versions-row"
        public static let permissionsRow = "iris.store.app.permissions-row"
        public static let storageRow = "iris.store.app.storage-row"
    }

    // MARK: My apps, Storage, Blocked (12.6; round3-deferred/M-store-screens
    // INTEGRATION_HOOKS.md Hook 1). `MyApps` here only covers the identifiers
    // this hook named; `StoreMyAppsView.swift` (owned by a different, still
    // running unit) keeps its own literals for now, byte-identical to these
    // values, until that unit adopts this enum too.
    public enum MyApps {
        public static let root = "iris.store.my-apps"
        public static let menu = "iris.store.my-apps.menu"
        public static let list = "iris.store.my-apps.list"
        public static let updateAll = "iris.store.my-apps.update-all"
        public static let updateAllNote = "iris.store.my-apps.update-all.note"
        public static func row(_ appId: String) -> String { "iris.store.my-apps.row.\(appId)" }
        public static func rowUpdateBadge(_ appId: String) -> String { "iris.store.my-apps.row.\(appId).update-badge" }
        public static func rowBlockedBadge(_ appId: String) -> String { "iris.store.my-apps.row.\(appId).blocked-badge" }
        public static let storageLine = "iris.store.my-apps.storage-line"
        public static let blockedLine = "iris.store.my-apps.blocked-line"
        public static let empty = "iris.store.my-apps.empty"
        public static let emptyBrowse = "iris.store.my-apps.empty.browse"
        // MA2 organization identifiers (INTEGRATION_HOOKS.md section 2), folded
        // in byte for byte from the literals `Host/MyApps/**` already uses.
        public static let search = "iris.store.my-apps.search"
        public static let searchClear = "iris.store.my-apps.search.clear"
        public static let searchCount = "iris.store.my-apps.search.count"
        public static let searchZero = "iris.store.my-apps.search.zero"
        public static let searchZeroStore = "iris.store.my-apps.search.zero.store"
        public static let select = "iris.store.my-apps.select"
        public static let selectDone = "iris.store.my-apps.select.done"
        public static let selectCount = "iris.store.my-apps.select.count"
        public static let selectMove = "iris.store.my-apps.select.move"
        public static let selectRemove = "iris.store.my-apps.select.remove"
        public static func selectRow(_ appId: String) -> String { "iris.store.my-apps.select.row.\(appId)" }
        public static let sortMenu = "iris.store.my-apps.sort-menu"
        public static let viewMenu = "iris.store.my-apps.view-menu"
        public static let newFolder = "iris.store.my-apps.new-folder"
        public static let groupsHint = "iris.store.my-apps.groups-hint"
        public static let notice = "iris.store.my-apps.notice"
        public static let recent = "iris.store.my-apps.recent"
        public static func recentTile(_ appId: String) -> String { "iris.store.my-apps.recent.\(appId)" }
        public static func groupHeader(_ categoryId: String) -> String { "iris.store.my-apps.group.\(categoryId).header" }
        public static func groupCount(_ categoryId: String) -> String { "iris.store.my-apps.group.\(categoryId).count" }
        public static func folderHeader(_ folderId: String) -> String { "iris.store.my-apps.folder.\(folderId).header" }
        public static func folderCount(_ folderId: String) -> String { "iris.store.my-apps.folder.\(folderId).count" }
        public static func folderMenu(_ folderId: String) -> String { "iris.store.my-apps.folder.\(folderId).menu" }
        public static func folderEmpty(_ folderId: String) -> String { "iris.store.my-apps.folder.\(folderId).empty" }
        public static let folderName = "iris.store.my-apps.folder-name"
        public static let folderNameField = "iris.store.my-apps.folder-name.field"
        public static let folderNameSave = "iris.store.my-apps.folder-name.save"
        public static let folderNameCancel = "iris.store.my-apps.folder-name.cancel"
        public static let folderDeleteConfirm = "iris.store.my-apps.folder-delete.confirm"
        public static let folderDeleteCancel = "iris.store.my-apps.folder-delete.cancel"
        public static func menuItem(_ appId: String, _ action: String) -> String { "iris.store.my-apps.menu.\(appId).\(action)" }
        public static let rename = "iris.store.my-apps.rename"
        public static let renameField = "iris.store.my-apps.rename.field"
        public static let renameSave = "iris.store.my-apps.rename.save"
        public static let renameCancel = "iris.store.my-apps.rename.cancel"
        public static let renameOriginal = "iris.store.my-apps.rename.original"
        public static let move = "iris.store.my-apps.move"
        public static let moveNone = "iris.store.my-apps.move.none"
        public static func moveFolder(_ folderId: String) -> String { "iris.store.my-apps.move.folder.\(folderId)" }
        public static let moveNew = "iris.store.my-apps.move.new"
        public static let reorder = "iris.store.my-apps.reorder"
        public static func reorderRow(_ appId: String) -> String { "iris.store.my-apps.reorder.row.\(appId)" }
        public static let reorderDone = "iris.store.my-apps.reorder.done"
        public static func tile(_ appId: String) -> String { "iris.store.my-apps.tile.\(appId)" }
        public static let appCustomName = "iris.store.app.custom-name"
    }

    public enum Storage {
        public static let root = "iris.store.storage"
        public static let totalBar = "iris.store.storage.total-bar"
        public static let total = "iris.store.storage.total"
        public static let deviceLine = "iris.store.storage.device-line"
        public static let freeUp = "iris.store.storage.free-up"
        public static let freeUpSub = "iris.store.storage.free-up.sub"
        public static let result = "iris.store.storage.result"
        public static let cap = "iris.store.storage.cap"
        public static let capSheet = "iris.store.storage.cap-sheet"
        public static let keepCount = "iris.store.storage.keep-count"
        public static func keepCountOption(_ choice: VersionsKeptPerApp) -> String {
            "iris.store.storage.keep-count.option.\(choice.rawValue)"
        }
        public static let keepCountReset = "iris.store.storage.keep-count.reset"
        public static let keepCountSheet = "iris.store.storage.keep-count.sheet"
        public static let keepCountHelp = "iris.store.storage.keep-count.help"
        public static let keepCountConfirm = "iris.store.storage.keep-count.confirm"
        public static let keepCountCancel = "iris.store.storage.keep-count.cancel"
        public static let keepCountDone = "iris.store.storage.keep-count.done"
        public static let keepCountConfirmation = "iris.store.storage.keep-count.confirmation"
        public static let keepCountResult = "iris.store.storage.keep-count.result"
        public static let keepCountRaising = "iris.store.storage.keep-count.raising"
        public static let keepCountError = "iris.store.storage.keep-count.error"
        public static let empty = "iris.store.storage.empty"
        public static let error = "iris.store.storage.error"
        public static let low = "iris.store.storage.low"
        public static func appRow(_ appId: String) -> String { "iris.store.storage.app-row.\(appId)" }
    }

    public enum Blocked {
        public static let root = "iris.store.blocked"
        public static func row(_ slug: String) -> String { "iris.store.blocked.row.\(slug)" }
        public static func rowUnblock(_ slug: String) -> String { "iris.store.blocked.row.\(slug).unblock" }
    }

    // MARK: Features page (mobile-versions SPEC.md section 1, MV4). "Kept"
    // identifiers reproduce an existing literal exactly (never rename one a
    // UI test already depends on): `revert`/`activate` are
    // `NativeShellAppView`'s own `iris.revert.<rev>` / `iris.activate.<rev>`;
    // `pin`/`unpin` are `NativeStorageRevisionPinButton`'s own
    // `iris.storage.pin.<rev>` / `iris.storage.unpin.<rev>`.
    public enum Versions {
        public static func myAppsRow(_ appId: String) -> String { "iris.store.my-apps.row.\(appId)" }
        public static let explanation = "iris.store.versions.explanation"
        public static let showAll = "iris.store.versions.show-all"
        public static func revert(_ revisionId: String) -> String { "iris.revert.\(revisionId)" }
        public static func activate(_ revisionId: String) -> String { "iris.activate.\(revisionId)" }
        public static func download(_ revisionId: String) -> String { "iris.store.versions.download.\(revisionId)" }
        public static func pin(_ revisionId: String) -> String { "iris.storage.pin.\(revisionId)" }
        public static func unpin(_ revisionId: String) -> String { "iris.storage.unpin.\(revisionId)" }
        public static func remove(_ revisionId: String) -> String { "iris.store.versions.remove.\(revisionId)" }
        public static let undo = "iris.store.versions.undo"
        public static let spaceUsed = "iris.store.versions.space-used"
        public static let freeUp = "iris.store.versions.free-up"
        public static let removeApp = "iris.store.versions.remove-app"
        public static let macRemovalSheetOK = "iris.store.versions.mac-removal.ok"
        // The shared `NativeRemoveAppDialog`'s own three controls (MA2
        // SPEC.md line 150, MV4 owns them): namespaced under `my-apps`, not
        // `versions`, because MA2's own SPEC already fixed this exact
        // spelling for its other, older call site (the My Apps row menu).
        public static let removeAppConfirm = "iris.store.my-apps.remove.confirm"
        public static let removeAppKeep = "iris.store.my-apps.remove.keep"
        public static let removeAppDataToggle = "iris.store.my-apps.remove.delete-data"
        public static let removeConfirm = "iris.store.versions.remove.confirm"
        public static let removeCancel = "iris.store.versions.remove.cancel"
        public static let goBackConfirm = "iris.store.versions.go-back.confirm"
        public static let goBackCancel = "iris.store.versions.go-back.cancel"
        public static let status = "iris.store.versions.status"
        public static let error = "iris.store.versions.error"
        public static let retry = "iris.store.versions.retry"
        public static func row(_ revisionId: String) -> String { "iris.store.versions.row.\(revisionId)" }
    }
}

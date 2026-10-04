import Foundation

// Unit MA1-organization-core (route G8). Pure model, limits, name validation
// and the reducer for every person action in SPEC.md sections 1.2 to 1.5
// (`../../docs/plans/20260928-all-routes/round3/my-apps-organization/SPEC.md`).
// No I/O here: `MyAppsOrganizationFile.swift` owns the disk, `MyAppsScreen.swift`
// owns turning an arrangement plus the library and catalog into what the
// screen draws. Everything in this file is deterministic given its inputs,
// so it can be driven by seeded fuzzing and a persona ledger oracle without
// touching the file system, a clock, or a UI.

// MARK: - Limits (SPEC 3.2)

/// Every number the design fixed, in one place, so a mutation check on a
/// limit has exactly one line to change and exactly one line to restore.
public enum MyAppsLimits {
    public static let maxFolders = 40
    public static let maxAppsPerFolder = 300
    public static let nameMinLength = 1
    public static let nameMaxLength = 30
    public static let recentsMaxTiles = 8
    public static let recentsMinInstalledApps = 6
    public static let searchMinInstalledApps = 12
    /// SPEC 1.1 item 7: automatic group headers show only with 2+ non-empty
    /// groups and 6+ installed apps; below that everything is "All apps".
    public static let groupHeaderMinNonEmptyGroups = 2
    public static let groupHeaderMinInstalledApps = 6
    /// SPEC 1.4: apps and folders are 365 days is the housekeeping horizon
    /// for dropping a removed app's entry (`MyAppsOrganizationFile` uses it).
    public static let removedEntryRetentionDays = 365
    /// SPEC 1.1: the `[categoryId]` sentinel used for "Other" wherever a
    /// group is addressed by category id (the catalog never assigns this id;
    /// see `StoreCatalogIndex`, whose ids are catalog-assigned positive ints).
    public static let otherGroupId = -1
}

// MARK: - Name validation (SPEC 1.3, 1.4, R-store-01 s1)

public enum MyAppsNameValidationError: Error, Equatable, Sendable {
    case empty
    case tooLong(limit: Int, actual: Int)
    case containsControlCharacters
}

public enum MyAppsNameValidator {
    /// Leading/trailing whitespace and newlines trimmed. This is what a
    /// dialog shows back to the person before it is judged against the
    /// length and character rules.
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SPEC 1.3: "1 to 30 characters (the App Store's own limit)... no line
    /// breaks or control characters". Counts extended grapheme clusters
    /// (`String.count`), which is the number a person typing sees, so a
    /// combining-mark name or an emoji counts as the one character it looks
    /// like (persona P3: "30-character names in Arabic and with combining
    /// marks").
    public static func validate(_ raw: String) -> Result<String, MyAppsNameValidationError> {
        let trimmed = normalize(raw)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.count <= MyAppsLimits.nameMaxLength else {
            return .failure(.tooLong(limit: MyAppsLimits.nameMaxLength, actual: trimmed.count))
        }
        for scalar in trimmed.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar.properties.generalCategory == .control {
                return .failure(.containsControlCharacters)
            }
        }
        return .success(trimmed)
    }

    public static func isValid(_ raw: String) -> Bool {
        if case .success = validate(raw) { return true }
        return false
    }
}

// MARK: - Model (SPEC 3.1, the `my-apps.json` shape, version 1)

/// One of the person's folders. `apps` is the folder's own order (SPEC 1.4);
/// an app's membership is "is this identity's id present in some folder's
/// `apps` array", never a separate flag, so the one-place rule (SPEC 1.4.5)
/// is a structural property the reducer enforces on every write rather than
/// something a reader has to re-check.
public struct MyAppsFolder: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var order: Int
    /// ISO 8601, UTC, e.g. `2026-09-28T09:12:00Z`.
    public var createdAt: String
    public var collapsed: Bool
    public var apps: [String]

    public init(id: String, name: String, order: Int, createdAt: String, collapsed: Bool = false, apps: [String] = []) {
        self.id = id
        self.name = name
        self.order = order
        self.createdAt = createdAt
        self.collapsed = collapsed
        self.apps = apps
    }
}

/// Per-app facts that outlive a relaunch and an update: a chosen name and
/// the two timestamps the Recently used row needs (SPEC 3.1: kept out of
/// `NativeUsageService` because that is consent-gated and this row must work
/// with usage recording off). `apps` in `MyAppsArrangement` holds only
/// entries with at least one non-default value (SPEC 3.1: "a never-renamed,
/// never-opened app has no entry"); `MyAppsOrganizationReducer` keeps that
/// invariant by dropping an entry the moment it goes back to all-nil.
public struct MyAppsAppEntry: Codable, Equatable, Sendable {
    public var name: String?
    public var lastOpenedAt: String?
    public var installedAt: String?

    public init(name: String? = nil, lastOpenedAt: String? = nil, installedAt: String? = nil) {
        self.name = name
        self.lastOpenedAt = lastOpenedAt
        self.installedAt = installedAt
    }

    public var isDefault: Bool { name == nil && lastOpenedAt == nil && installedAt == nil }
}

/// The whole file, version 1. See `MyAppsOrganizationFile` for how this is
/// read and written atomically, and SPEC 3.1 for the JSON shape this mirrors
/// field for field (`collapsedGroups` holds category ids, plus
/// `MyAppsLimits.otherGroupId` when "Other" is collapsed).
public struct MyAppsArrangement: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var folders: [MyAppsFolder]
    public var apps: [String: MyAppsAppEntry]
    public var collapsedGroups: [Int]
    public var hintDismissed: Bool

    public init(
        version: Int = MyAppsArrangement.currentVersion,
        folders: [MyAppsFolder] = [],
        apps: [String: MyAppsAppEntry] = [:],
        collapsedGroups: [Int] = [],
        hintDismissed: Bool = false
    ) {
        self.version = version
        self.folders = folders
        self.apps = apps
        self.collapsedGroups = collapsedGroups
        self.hintDismissed = hintDismissed
    }

    public static let empty = MyAppsArrangement()

    /// The folder holding this identity, if any (SPEC 1.4's one-place rule:
    /// at most one match, checked by `MyAppsOrganizationReducer` whenever it
    /// writes, and by the tests' independent oracle on every read).
    public func folder(containing identity: String) -> MyAppsFolder? {
        folders.first { $0.apps.contains(identity) }
    }

    public func customName(for identity: String) -> String? {
        apps[identity]?.name
    }
}

// MARK: - Actions (SPEC 1.2 to 1.5)

public enum MyAppsAction: Equatable, Sendable {
    case rename(identity: String, to: String)
    case useOriginalName(identity: String)
    /// `folderId == nil` is the Move sheet's "No folder" row: take the app
    /// out of whatever folder it is in and let it fall back to its group.
    case moveToFolder(identity: String, folderId: String?)
    case takeOutOfFolder(identity: String)
    case createFolder(id: String, name: String, initialApps: [String], createdAt: String)
    case renameFolder(folderId: String, to: String)
    case deleteFolder(folderId: String)
    case reorderFolderApps(folderId: String, order: [String])
    case reorderFolders(order: [String])
    case setGroupCollapsed(categoryId: Int, collapsed: Bool)
    case setFolderCollapsed(folderId: String, collapsed: Bool)
    case dismissGroupsHint
    case recordOpened(identity: String, at: String)
    case recordInstalled(identity: String, at: String)
    /// "Also delete my data" on Remove (SPEC 1.2, MV4 owns the dialog): drop
    /// the arrangement's memory of this app entirely (name, folder, order).
    case forgetApp(identity: String)
}

public enum MyAppsActionError: Error, Equatable, Sendable {
    case invalidName(MyAppsNameValidationError)
    case folderNotFound
    case folderLimitReached(limit: Int)
    case folderAppLimitReached(limit: Int)
    case duplicateFolderId
    case reorderMismatch
}

/// What actually happened, for the caller to turn into the exact sentences
/// in SPEC section 4 ("Renamed to Clips.", "Moved Clips to Editing.", ...).
/// Deliberately carries data, not text: MA1 does not know a display name for
/// an app that has never been renamed (that lives in the library/catalog,
/// which this module never imports), so composing the sentence is the
/// screen's job (MA2), documented in HANDOFF.md.
public enum MyAppsEvent: Equatable, Sendable {
    case renamed(identity: String, name: String)
    case nameReset(identity: String)
    case moved(identity: String, folderId: String, folderName: String)
    case tookOut(identity: String, fromFolderId: String, fromFolderName: String)
    case folderCreated(folderId: String, name: String)
    case folderRenamed(folderId: String, name: String)
    case folderDeleted(folderId: String, name: String, returnedAppCount: Int)
    case folderReordered(folderId: String)
    case foldersReordered
    case groupCollapsed(categoryId: Int, collapsed: Bool)
    case folderCollapsed(folderId: String, collapsed: Bool)
    case hintDismissed
    case openedRecorded(identity: String)
    case installedRecorded(identity: String)
    case forgotten(identity: String)
}

public struct MyAppsActionOutcome: Equatable, Sendable {
    public let arrangement: MyAppsArrangement
    public let event: MyAppsEvent
}

/// The pure reducer: `apply` never touches disk or the clock (timestamps
/// come in as strings from the caller, SPEC 3.1's `lastOpenedAt` /
/// `installedAt` seam), never throws for an expected outcome (invalid name,
/// full folder) -- those come back as `.failure` so a dialog can show the
/// exact line in SPEC 1.3 / 1.4 -- and enforces the one-place rule and every
/// limit on every write, not just at the edges the UI happens to check.
public enum MyAppsOrganizationReducer {
    public static func apply(_ action: MyAppsAction, to arrangement: MyAppsArrangement) -> Result<MyAppsActionOutcome, MyAppsActionError> {
        switch action {
        case let .rename(identity, to):
            return rename(identity: identity, to: to, in: arrangement)
        case let .useOriginalName(identity):
            return resetName(identity: identity, in: arrangement)
        case let .moveToFolder(identity, folderId):
            return move(identity: identity, toFolderId: folderId, in: arrangement)
        case let .takeOutOfFolder(identity):
            return move(identity: identity, toFolderId: nil, in: arrangement)
        case let .createFolder(id, name, initialApps, createdAt):
            return createFolder(id: id, name: name, initialApps: initialApps, createdAt: createdAt, in: arrangement)
        case let .renameFolder(folderId, to):
            return renameFolder(folderId: folderId, to: to, in: arrangement)
        case let .deleteFolder(folderId):
            return deleteFolder(folderId: folderId, in: arrangement)
        case let .reorderFolderApps(folderId, order):
            return reorderFolderApps(folderId: folderId, order: order, in: arrangement)
        case let .reorderFolders(order):
            return reorderFolders(order: order, in: arrangement)
        case let .setGroupCollapsed(categoryId, collapsed):
            var next = arrangement
            var set = Set(next.collapsedGroups)
            if collapsed { set.insert(categoryId) } else { set.remove(categoryId) }
            next.collapsedGroups = set.sorted()
            return .success(MyAppsActionOutcome(arrangement: next, event: .groupCollapsed(categoryId: categoryId, collapsed: collapsed)))
        case let .setFolderCollapsed(folderId, collapsed):
            return setFolderCollapsed(folderId: folderId, collapsed: collapsed, in: arrangement)
        case .dismissGroupsHint:
            var next = arrangement
            next.hintDismissed = true
            return .success(MyAppsActionOutcome(arrangement: next, event: .hintDismissed))
        case let .recordOpened(identity, at):
            var next = arrangement
            var entry = next.apps[identity] ?? MyAppsAppEntry()
            entry.lastOpenedAt = at
            next.apps[identity] = entry
            return .success(MyAppsActionOutcome(arrangement: next, event: .openedRecorded(identity: identity)))
        case let .recordInstalled(identity, at):
            var next = arrangement
            var entry = next.apps[identity] ?? MyAppsAppEntry()
            entry.installedAt = at
            // SPEC 1.1 item 4: "Newly installed apps count as used at
            // install time, so a fresh install appears at the front".
            if entry.lastOpenedAt == nil { entry.lastOpenedAt = at }
            next.apps[identity] = entry
            return .success(MyAppsActionOutcome(arrangement: next, event: .installedRecorded(identity: identity)))
        case let .forgetApp(identity):
            var next = arrangement
            next.apps.removeValue(forKey: identity)
            for index in next.folders.indices {
                next.folders[index].apps.removeAll { $0 == identity }
            }
            return .success(MyAppsActionOutcome(arrangement: next, event: .forgotten(identity: identity)))
        }
    }

    // MARK: Rename (1.3)

    private static func rename(identity: String, to raw: String, in arrangement: MyAppsArrangement) -> Result<MyAppsActionOutcome, MyAppsActionError> {
        switch MyAppsNameValidator.validate(raw) {
        case let .failure(error):
            return .failure(.invalidName(error))
        case let .success(name):
            var next = arrangement
            var entry = next.apps[identity] ?? MyAppsAppEntry()
            entry.name = name
            next.apps[identity] = entry
            return .success(MyAppsActionOutcome(arrangement: next, event: .renamed(identity: identity, name: name)))
        }
    }

    private static func resetName(identity: String, in arrangement: MyAppsArrangement) -> Result<MyAppsActionOutcome, MyAppsActionError> {
        var next = arrangement
        if var entry = next.apps[identity] {
            entry.name = nil
            if entry.isDefault {
                next.apps.removeValue(forKey: identity)
            } else {
                next.apps[identity] = entry
            }
        }
        return .success(MyAppsActionOutcome(arrangement: next, event: .nameReset(identity: identity)))
    }

    // MARK: Move / take out (1.4)

    private static func move(identity: String, toFolderId folderId: String?, in arrangement: MyAppsArrangement) -> Result<MyAppsActionOutcome, MyAppsActionError> {
        var next = arrangement
        let previousFolder = next.folder(containing: identity)
        // One-place rule: remove from every folder first, unconditionally.
        for index in next.folders.indices {
            next.folders[index].apps.removeAll { $0 == identity }
        }
        guard let folderId else {
            if let previousFolder {
                return .success(MyAppsActionOutcome(arrangement: next, event: .tookOut(identity: identity, fromFolderId: previousFolder.id, fromFolderName: previousFolder.name)))
            }
            // Already had no folder: a no-op that still returns success so
            // Select-mode "Move to folder -> No folder" is idempotent.
            return .success(MyAppsActionOutcome(arrangement: next, event: .tookOut(identity: identity, fromFolderId: "", fromFolderName: "")))
        }
        guard let folderIndex = next.folders.firstIndex(where: { $0.id == folderId }) else {
            return .failure(.folderNotFound)
        }
        guard next.folders[folderIndex].apps.count < MyAppsLimits.maxAppsPerFolder else {
            return .failure(.folderAppLimitReached(limit: MyAppsLimits.maxAppsPerFolder))
        }
        next.folders[folderIndex].apps.append(identity)
        let folderName = next.folders[folderIndex].name
        return .success(MyAppsActionOutcome(arrangement: next, event: .moved(identity: identity, folderId: folderId, folderName: folderName)))
    }

    // MARK: Folders (1.4)

    private static func createFolder(id: String, name raw: String, initialApps: [String], createdAt: String, in arrangement: MyAppsArrangement) -> Result<MyAppsActionOutcome, MyAppsActionError> {
        guard !arrangement.folders.contains(where: { $0.id == id }) else {
            return .failure(.duplicateFolderId)
        }
        guard arrangement.folders.count < MyAppsLimits.maxFolders else {
            return .failure(.folderLimitReached(limit: MyAppsLimits.maxFolders))
        }
        switch MyAppsNameValidator.validate(raw) {
        case let .failure(error):
            return .failure(.invalidName(error))
        case let .success(name):
            var next = arrangement
            let order = (next.folders.map(\.order).max() ?? -1) + 1
            var folder = MyAppsFolder(id: id, name: name, order: order, createdAt: createdAt, collapsed: false, apps: [])
            next.folders.append(folder)
            // Route every initial app through the one-place move logic so a
            // "New folder..." started from the Move sheet cannot duplicate
            // an app that was already somewhere else.
            for identity in initialApps {
                switch move(identity: identity, toFolderId: id, in: next) {
                case let .success(outcome):
                    next = outcome.arrangement
                case .failure:
                    continue
                }
            }
            folder = next.folders.first { $0.id == id } ?? folder
            return .success(MyAppsActionOutcome(arrangement: next, event: .folderCreated(folderId: id, name: folder.name)))
        }
    }

    private static func renameFolder(folderId: String, to raw: String, in arrangement: MyAppsArrangement) -> Result<MyAppsActionOutcome, MyAppsActionError> {
        guard arrangement.folders.contains(where: { $0.id == folderId }) else {
            return .failure(.folderNotFound)
        }
        switch MyAppsNameValidator.validate(raw) {
        case let .failure(error):
            return .failure(.invalidName(error))
        case let .success(name):
            var next = arrangement
            guard let index = next.folders.firstIndex(where: { $0.id == folderId }) else {
                return .failure(.folderNotFound)
            }
            next.folders[index].name = name
            return .success(MyAppsActionOutcome(arrangement: next, event: .folderRenamed(folderId: folderId, name: name)))
        }
    }

    private static func deleteFolder(folderId: String, in arrangement: MyAppsArrangement) -> Result<MyAppsActionOutcome, MyAppsActionError> {
        guard let folder = arrangement.folders.first(where: { $0.id == folderId }) else {
            return .failure(.folderNotFound)
        }
        var next = arrangement
        next.folders.removeAll { $0.id == folderId }
        // SPEC 1.4: "Its 3 apps go back to their groups. Nothing is removed
        // from your iPhone." Deleting a folder never touches `apps` entries
        // (names, timestamps) or any other folder's membership.
        return .success(MyAppsActionOutcome(arrangement: next, event: .folderDeleted(folderId: folderId, name: folder.name, returnedAppCount: folder.apps.count)))
    }

    private static func reorderFolderApps(folderId: String, order: [String], in arrangement: MyAppsArrangement) -> Result<MyAppsActionOutcome, MyAppsActionError> {
        guard let index = arrangement.folders.firstIndex(where: { $0.id == folderId }) else {
            return .failure(.folderNotFound)
        }
        let current = Set(arrangement.folders[index].apps)
        guard Set(order) == current, order.count == current.count else {
            return .failure(.reorderMismatch)
        }
        var next = arrangement
        next.folders[index].apps = order
        return .success(MyAppsActionOutcome(arrangement: next, event: .folderReordered(folderId: folderId)))
    }

    private static func reorderFolders(order: [String], in arrangement: MyAppsArrangement) -> Result<MyAppsActionOutcome, MyAppsActionError> {
        let current = Set(arrangement.folders.map(\.id))
        guard Set(order) == current, order.count == current.count else {
            return .failure(.reorderMismatch)
        }
        var next = arrangement
        for (position, id) in order.enumerated() {
            if let index = next.folders.firstIndex(where: { $0.id == id }) {
                next.folders[index].order = position
            }
        }
        next.folders.sort { $0.order < $1.order }
        return .success(MyAppsActionOutcome(arrangement: next, event: .foldersReordered))
    }

    private static func setFolderCollapsed(folderId: String, collapsed: Bool, in arrangement: MyAppsArrangement) -> Result<MyAppsActionOutcome, MyAppsActionError> {
        guard let index = arrangement.folders.firstIndex(where: { $0.id == folderId }) else {
            return .failure(.folderNotFound)
        }
        var next = arrangement
        next.folders[index].collapsed = collapsed
        return .success(MyAppsActionOutcome(arrangement: next, event: .folderCollapsed(folderId: folderId, collapsed: collapsed)))
    }
}

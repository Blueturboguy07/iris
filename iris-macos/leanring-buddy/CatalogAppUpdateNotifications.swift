//
//  CatalogAppUpdateNotifications.swift
//  leanring-buddy
//
//  Deciding which catalog-app updates are worth telling the reader about
//  without being asked, and remembering which ones already were — so a
//  background check does not re-announce the same available update every
//  time it runs. Pure decision + a tiny persisted store; the permission ask
//  lives in `NotificationPermissionManager` and the actual background check
//  and notification-sending live in `CompanionManager`.
//

import Foundation

/// One release tag remembered per catalog app slug — the last version this
/// Mac was already told about. `AppInventoryService.installedEntriesForDisplay`
/// answers "is there an update right now"; this answers "have we already said
/// so", which is the difference between one notification and one every time
/// the background check runs.
///
/// `@unchecked Sendable` for the same reason `AutopilotAutonomyGrant` is: the
/// one stored property is a `UserDefaults`, which Apple documents as
/// thread-safe but does not mark `Sendable`.
nonisolated struct CatalogAppUpdateSeenTagsStore: @unchecked Sendable {
    /// The app-wide store, over `UserDefaults.standard`.
    static let shared = CatalogAppUpdateSeenTagsStore()

    private static let defaultsKey = "iris:catalogAppUpdates:lastAnnouncedReleaseTagBySlug"

    private let userDefaults: UserDefaults

    /// A real store uses `.standard`; a test constructs one over an isolated
    /// suite so it never touches the reader's real preferences.
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    private var tagsBySlug: [String: String] {
        get { (userDefaults.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:] }
        nonmutating set { userDefaults.set(newValue, forKey: Self.defaultsKey) }
    }

    /// The release tag this Mac was last told about for this app, or nil if
    /// it has never been announced (including an app that has never had an
    /// update at all).
    func lastAnnouncedReleaseTag(forSlug slug: String) -> String? {
        tagsBySlug[slug]
    }

    /// Records that `releaseTag` has now been announced for `slug`, so the
    /// same version is never announced twice.
    func markAsAnnounced(releaseTag: String, forSlug slug: String) {
        var tags = tagsBySlug
        tags[slug] = releaseTag
        tagsBySlug = tags
    }
}

/// Which of the reader's installed apps have an update the reader has not
/// already been told about — the pure decision behind the proactive nudge
/// (the system notification and, in future, an eye-side nudge).
///
/// Deliberately separate from "has an update at all"
/// (`CatalogAppInventoryEntry.hasAnUpdateAvailable`, which the menu bar badge
/// and the panel's "Update to…" pill both read directly): the badge and the
/// pill are supposed to stay lit for as long as the update is outstanding,
/// but a notification that repeated on every background check would be the
/// "it keeps telling me things I already know" complaint waiting to happen.
enum CatalogAppUpdateNotificationDecision {
    static func newlyAvailableUpdates(
        in inventoryEntries: [CatalogAppInventoryEntry],
        notAlreadyAnnouncedAccordingTo seenTagsStore: CatalogAppUpdateSeenTagsStore
    ) -> [CatalogAppInventoryEntry] {
        inventoryEntries.filter { entry in
            guard case .updateIsAvailable(let latestReleaseTag) = entry.updateAvailability else {
                return false
            }
            return seenTagsStore.lastAnnouncedReleaseTag(forSlug: entry.slug) != latestReleaseTag
        }
    }

    /// The title + body for a single consolidated notification covering every
    /// newly available update at once — never one notification per app, which
    /// is exactly the kind of thing that trains a reader to swipe Iris's
    /// notifications away unread.
    ///
    /// `newlyAvailableEntries` must be non-empty; callers only reach this after
    /// checking `newlyAvailableUpdates` returned something.
    static func consolidatedNotificationText(
        forNewlyAvailableEntries newlyAvailableEntries: [CatalogAppInventoryEntry]
    ) -> (title: String, body: String) {
        let releaseDescriptions: [String] = newlyAvailableEntries.map { entry in
            if case .updateIsAvailable(let latestReleaseTag) = entry.updateAvailability {
                return "\(entry.name) \(latestReleaseTag)"
            }
            return entry.name
        }

        if releaseDescriptions.count == 1 {
            return ("Update available", releaseDescriptions[0])
        }
        return (
            "\(releaseDescriptions.count) updates available",
            releaseDescriptions.joined(separator: ", ")
        )
    }
}

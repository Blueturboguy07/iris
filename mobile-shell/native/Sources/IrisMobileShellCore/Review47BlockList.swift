import Foundation

// Unit m3-guideline47, Guideline 4.7.1: "... include a method for
// filtering objectionable material, a mechanism to report content and
// timely responses to concerns, and the ability to block abusive users ..."
// (verbatim, checked 2026-09-27 against
// https://developer.apple.com/app-store/review/guidelines/)
//
// "abusive users" in Iris's shell context is a mini app being blocked, not
// a social/multiplayer participant (the shell has no user-to-user
// interaction surface). This is the local, on-device block list: once an
// appId is blocked, Review47UniversalLinkPolicy and
// NativeMobileMarketplacePolicy both refuse to open it, including from a
// universal link, and Browse/My apps can hide it. It needs no Publik
// server: a person can block an app with the device offline.

public protocol Review47BlockListStore: Sendable {
    func blockedAppIDs() async -> Set<String>
    func setBlocked(_ appId: String, blocked: Bool) async
}

public actor Review47BlockList {
    private let store: Review47BlockListStore

    public init(store: Review47BlockListStore) {
        self.store = store
    }

    public func isBlocked(appId: String) async -> Bool {
        await store.blockedAppIDs().contains(appId)
    }

    public func block(appId: String) async {
        await store.setBlocked(appId, blocked: true)
    }

    public func unblock(appId: String) async {
        await store.setBlocked(appId, blocked: false)
    }

    public func blockedAppIDs() async -> Set<String> {
        await store.blockedAppIDs()
    }
}

/// Default persisted store. Foundation-only, so it works identically in
/// SwiftPM macOS tests and on-device. An actor rather than a lock-guarded
/// class for the same reason as `UserDefaultsReview47AgeStore`.
public actor UserDefaultsReview47BlockListStore: Review47BlockListStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, namespace: String = "iris.review47.block-list") {
        self.defaults = defaults
        self.key = namespace + ".blocked-app-ids"
    }

    public func blockedAppIDs() async -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    public func setBlocked(_ appId: String, blocked: Bool) async {
        var current = Set(defaults.stringArray(forKey: key) ?? [])
        if blocked {
            current.insert(appId)
        } else {
            current.remove(appId)
        }
        defaults.set(current.sorted(), forKey: key)
    }
}

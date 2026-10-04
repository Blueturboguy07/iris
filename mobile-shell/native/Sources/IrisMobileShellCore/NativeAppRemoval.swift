import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// Removing an installed app, with an honest "Also delete my data" (round 6,
/// prep A, RC-04; apple-compliance REQUIRED_CHANGES.md).
///
/// Before this, the Remove dialog and `MyAppsAction.forgetApp` existed, but
/// nothing anywhere deleted an app's stored versions, its web storage or its
/// saved data, so a person who ticked "Also delete my data" (App Review 5.1.1(v)
/// account and data deletion, and plain honesty) got a dialog and nothing else.
///
/// What each choice does, decided here and shown to the person in plain words:
/// - Remove, "Also delete my data" OFF: the app's code goes (every stored
///   version, the active-version pointer, pins, delivery replay markers).
///   Everything the app saved stays: its web storage, its reader data, the
///   permissions the person allowed, the name and folder in My apps. A later
///   install of the same app finds its data where it left it.
/// - Remove, "Also delete my data" ON: all of the above plus the app's named
///   WebKit data store (`WKWebsiteDataStore.remove(forIdentifier:)`, the place
///   localStorage, IndexedDB and OPFS files such as Kneecap's videos live),
///   its reader data, its remembered permission decisions and, when a
///   Versions store is given, its checkouts, manifests and object references
///   (objects nothing else points at are deleted).
///
/// Order matters for crash safety. Data goes FIRST, code LAST. A crash in the
/// middle leaves the app still installed and still listed, so the person can
/// try again; the other order could leave saved data behind an app that no
/// longer appears anywhere, with no way to reach it.
public enum NativeAppRemovalError: Error, Equatable, CustomStringConvertible {
    case webStorageUnavailable
    case webStorageRemovalFailed(String)
    case versionsRemovalFailed(String)

    public var description: String {
        switch self {
        case .webStorageUnavailable:
            return "This iPhone's system cannot remove an app's saved web data. Nothing was removed."
        case .webStorageRemovalFailed(let message):
            return "Iris could not delete the app's saved data (\(message)). Nothing else was removed, so you can try again."
        case .versionsRemovalFailed(let message):
            return "Iris could not delete the app's stored versions (\(message)). The app is still installed, so you can try again."
        }
    }
}

/// Removes the named WebKit data stores. The system implementation is below;
/// tests and the Host can pass their own.
public protocol NativeWebStorageRemoving: Sendable {
    func removeStores(identifiers: [UUID]) async throws
}

#if canImport(WebKit)
/// Deletes real `WKWebsiteDataStore`s (iOS 17, macOS 14). A store that was
/// never created (the app was never opened) is skipped, not an error. WebKit
/// refuses to delete a store a web view is still using, so the app must be
/// closed first; that refusal comes back as `webStorageRemovalFailed`.
public struct NativeWebsiteDataStoreRemover: NativeWebStorageRemoving {
    public init() {}

    public func removeStores(identifiers: [UUID]) async throws {
        guard #available(iOS 17.0, macOS 14.0, *) else { throw NativeAppRemovalError.webStorageUnavailable }
        for identifier in identifiers {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
            } catch {
                throw NativeAppRemovalError.webStorageRemovalFailed(error.localizedDescription)
            }
        }
    }
}
#endif

public struct NativeAppRemovalReport: Equatable, Sendable {
    public let identity: NativeShellAppIdentity
    public let alsoDeletedData: Bool
    /// Bytes on disk (allocated size) the app's code was using: every stored
    /// version and the state files beside them.
    public let codeBytesFreed: Int64
    /// Bytes on disk freed from the app's data that this call could measure
    /// itself: reader data plus, when a Versions store was given, the
    /// objects nothing else needed. The named WebKit data store's own bytes
    /// are removed by WebKit and are not counted here.
    public let dataBytesFreed: Int64
    public let webStorageStoresRemoved: Int
    public let permissionDecisionsForgotten: Int

    /// Plain words for the result line. Never says data was deleted when it
    /// was kept, and never says it stays when it was deleted.
    public func plainSummary(appName: String) -> String {
        alsoDeletedData
            ? "Removed \(appName) and deleted its saved data from this iPhone."
            : "Removed \(appName). Its saved data stays on this iPhone in case you install it again."
    }
}

public enum NativeAppRemoval {
    #if canImport(WebKit)
    public static var systemWebStorageRemover: NativeWebStorageRemoving? { NativeWebsiteDataStoreRemover() }
    #else
    public static var systemWebStorageRemover: NativeWebStorageRemoving? { nil }
    #endif

    /// Every WebKit data store this app's stored versions ever used. Read
    /// straight from each stored revision's `metadata.json` WITHOUT verifying
    /// the revision, on purpose: a damaged version must not stop the person's
    /// data from being found and deleted. Only versions that asked for
    /// `web.storage` have a named store.
    static func webStorageIdentifiers(
        rootURL: URL, identity: NativeShellAppIdentity, fileManager: FileManager
    ) -> [UUID] {
        let revisions = rootURL
            .appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent(identity.appId, isDirectory: true)
            .appendingPathComponent(identity.projectId, isDirectory: true)
            .appendingPathComponent("revisions", isDirectory: true)
        guard let children = try? fileManager.contentsOfDirectory(at: revisions, includingPropertiesForKeys: nil) else { return [] }
        var found = Set<UUID>()
        for child in children {
            guard let data = try? Data(contentsOf: child.appendingPathComponent("metadata.json")),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let manifest = root["manifest"] as? [String: Any],
                  let capabilities = manifest["requestedCapabilities"] as? [String],
                  capabilities.contains("web.storage"),
                  let namespace = manifest["dataNamespace"] as? String,
                  let storage = try? NativeWebStorageIdentity(
                      appId: identity.appId, projectId: identity.projectId, dataNamespace: namespace
                  ) else { continue }
            found.insert(storage.identifier)
        }
        return found.sorted { $0.uuidString < $1.uuidString }
    }

    /// Allocated bytes of a file or a whole tree. Missing means zero.
    static func allocatedBytes(at url: URL, fileManager: FileManager) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let walker = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return 0 }
        for case let item as URL in walker {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Removes a directory or file. A symbolic link is removed as the link
    /// alone and never followed.
    static func removeIfPresent(_ url: URL, fileManager: FileManager) throws {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            try fileManager.removeItem(at: url)
            return
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Removes `directory` when it holds nothing (the per-app folder above a
    /// removed project folder).
    static func removeIfEmpty(_ directory: URL, fileManager: FileManager) {
        guard let items = try? fileManager.contentsOfDirectory(atPath: directory.path), items.isEmpty else { return }
        try? fileManager.removeItem(at: directory)
    }

    /// The Versions side of "delete my data": every version's objects (an
    /// object goes only when its reference count reaches zero, so a byte
    /// another app still uses is never deleted), then the checkouts, the
    /// manifests and the state files (active pointer, journal, undo offer and
    /// the Features ledger). Returns the bytes of objects actually deleted.
    static func removeVersionsData(
        store: NativeVersionStore, identity: NativeShellAppIdentity, fileManager: FileManager
    ) async throws -> Int64 {
        var reclaimed: Int64 = 0
        do {
            let manifests = try store.manifests.list(appId: identity.appId, projectId: identity.projectId)
            for manifest in manifests.sorted(by: { $0.createdAt < $1.createdAt }) {
                let result = try await store.gc.free(
                    appId: identity.appId, projectId: identity.projectId, revisionId: manifest.revisionId
                )
                reclaimed += Int64(result.bytesReclaimed)
            }
        } catch {
            throw NativeAppRemovalError.versionsRemovalFailed(String(describing: error))
        }
        let folders: [URL] = [
            store.checkouts.root.appendingPathComponent(identity.appId, isDirectory: true)
                .appendingPathComponent(identity.projectId, isDirectory: true),
            store.manifests.root.appendingPathComponent(identity.appId, isDirectory: true)
                .appendingPathComponent(identity.projectId, isDirectory: true),
            store.state.directory(appId: identity.appId, projectId: identity.projectId),
        ]
        for folder in folders {
            do { try removeIfPresent(folder, fileManager: fileManager) }
            catch { throw NativeAppRemovalError.versionsRemovalFailed(String(describing: error)) }
            removeIfEmpty(folder.deletingLastPathComponent(), fileManager: fileManager)
        }
        return reclaimed
    }
}

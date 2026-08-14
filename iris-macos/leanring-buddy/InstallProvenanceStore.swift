//
//  InstallProvenanceStore.swift
//  leanring-buddy
//
//  How did this app get onto this machine? Maintain mode's whole permission
//  to touch code hangs on the answer: a guide-built source clone may be
//  patched locally (the user already runs an unsigned local build — patching
//  changes nothing about the trust boundary), a signed download is NEVER
//  patched (Iris invalidating a notarized signature would be vandalism), and
//  unknown provenance is treated as signed, because failing closed is the
//  only honest default for a question this consequential.
//
//  Provenance is RECORDED at guide completion, not inferred later — the same
//  "never guess" invariant AppInventoryService holds for bundle identity.
//

import Foundation

enum InstallProvenance: String, Codable, Sendable {
    /// A guide cloned the repo and built it here; the pinned commit and the
    /// clone path were written down at completion time.
    case guideSourceClone
    /// A signed .app arrived by download. Local patching is off the table.
    case signedAppDownload
}

struct RecordedInstallProvenance: Codable, Equatable, Sendable {
    let appSlug: String
    let provenance: InstallProvenance
    /// Absolute path of the clone, for `guideSourceClone` only.
    let clonePath: String?
    /// The guide's pinned source commit at install time — the base fixes
    /// diff against until the patch queue advances it.
    let pinnedCommit: String?
    /// "owner/name" of the canonical repo — what the fork backup forks.
    /// Optional so records written before it existed keep decoding.
    let canonicalRepo: String?
    let recordedAt: Date
}

@MainActor
final class InstallProvenanceStore {

    private static let defaultsKey = "iris:maintain:install-provenance"

    private let userDefaults: UserDefaults
    private var byAppSlug: [String: RecordedInstallProvenance]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: RecordedInstallProvenance].self, from: data) {
            byAppSlug = decoded
        } else {
            byAppSlug = [:]
        }
    }

    /// Called from guide completion, the one moment the facts are all in
    /// hand. Overwrites an older record: a re-install is a new provenance.
    func recordGuideSourceClone(
        appSlug: String, clonePath: String, pinnedCommit: String?, canonicalRepo: String?
    ) {
        byAppSlug[appSlug] = RecordedInstallProvenance(
            appSlug: appSlug,
            provenance: .guideSourceClone,
            clonePath: clonePath,
            pinnedCommit: pinnedCommit,
            canonicalRepo: canonicalRepo,
            recordedAt: Date()
        )
        persist()
    }

    func recordSignedDownload(appSlug: String) {
        byAppSlug[appSlug] = RecordedInstallProvenance(
            appSlug: appSlug,
            provenance: .signedAppDownload,
            clonePath: nil,
            pinnedCommit: nil,
            canonicalRepo: nil,
            recordedAt: Date()
        )
        persist()
    }

    func provenance(forAppSlug appSlug: String) -> RecordedInstallProvenance? {
        byAppSlug[appSlug]
    }

    /// The D4 gate, in one place. Unknown = signed = no local patching.
    func localPatchingIsPermitted(forAppSlug appSlug: String) -> Bool {
        guard let record = byAppSlug[appSlug],
              record.provenance == .guideSourceClone,
              let clonePath = record.clonePath else { return false }
        // The record can outlive the clone (the user deleted the folder, or
        // a wipe took it). A recorded path that no longer holds a git repo
        // is unknown provenance again.
        var isDirectory: ObjCBool = false
        let gitPath = (clonePath as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(byAppSlug) {
            userDefaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

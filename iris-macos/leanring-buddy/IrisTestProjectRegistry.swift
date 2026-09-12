import AppKit
import Foundation

// Test builds discover only explicitly staged copies, never normal installations.
nonisolated enum IrisTestProjectRegistry {
    struct Project: Codable, Equatable, Sendable {
        let slug: String
        let name: String
        let clonePath: String
        let applicationPath: String
        let buildArtifactPath: String
        let bundleIdentifier: String
        let pinnedCommit: String
        var nativeVerification: IrisTestVerificationDeclaration? = nil
    }

    static var projectsDirectory: URL {
        IrisTestEnvironment.applicationSupportDirectory.appendingPathComponent("Projects")
    }

    static func contains(_ path: String, within directory: URL) -> Bool {
        guard path.hasPrefix("/"), directory.path.hasPrefix("/") else { return false }
        let rawCandidate = URL(fileURLWithPath: path)
        let rawParent = URL(fileURLWithPath: directory.path)
        guard !containsSymlinkComponent(in: rawCandidate),
              !containsSymlinkComponent(in: rawParent) else { return false }
        let candidate = rawCandidate.standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        let parent = rawParent.standardizedFileURL.resolvingSymlinksInPath()
        return candidate.path == resolved.path && resolved.pathComponents.count > parent.pathComponents.count
            && Array(resolved.pathComponents.prefix(parent.pathComponents.count)) == parent.pathComponents
    }

    private static func containsSymlinkComponent(in url: URL) -> Bool {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            switch component {
            case ".":
                continue
            case "..":
                current.deleteLastPathComponent()
            default:
                current.appendPathComponent(component)
                if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    return true
                }
            }
        }
        return false
    }

    /// Deterministic entry validation with filesystem containment and the stable
    /// snapshot bundle identifier supplied by the caller. Keeping the bundle
    /// lookup outside this seam makes every registry rule testable without
    /// launching or constructing an app bundle. Build identity is checked when
    /// a fresh artifact is admitted.
    static func isValidProject(
        _ entry: Project,
        within projectsDirectory: URL,
        applicationBundleIdentifier: String?,
        previouslySeenSlugs: Set<String> = [],
        previouslySeenBundleIdentifiers: Set<String> = [],
        previouslySeenPaths: Set<String> = []
    ) -> Bool {
        guard isValidSlug(entry.slug),
              !previouslySeenSlugs.contains(entry.slug),
              isValidBundleIdentifier(entry.bundleIdentifier),
              !previouslySeenBundleIdentifiers.contains(entry.bundleIdentifier),
              entry.clonePath.hasPrefix("/"),
              entry.applicationPath.hasPrefix("/"),
              entry.applicationPath.hasSuffix(".app"),
              entry.buildArtifactPath.hasPrefix("/"),
              entry.buildArtifactPath.hasSuffix(".app"),
              isValidPinnedCommit(entry.pinnedCommit),
              applicationBundleIdentifier == entry.bundleIdentifier,
              contains(entry.clonePath, within: projectsDirectory),
              contains(
                  entry.applicationPath,
                  within: projectsDirectory.appendingPathComponent("Apps", isDirectory: true)
              ),
              contains(entry.buildArtifactPath, within: URL(fileURLWithPath: entry.clonePath)) else {
            return false
        }

        let normalizedClonePath = normalizedPath(entry.clonePath)
        let normalizedApplicationPath = normalizedPath(entry.applicationPath)
        let normalizedBuildArtifactPath = normalizedPath(entry.buildArtifactPath)
        guard normalizedClonePath != normalizedApplicationPath,
              normalizedClonePath != normalizedBuildArtifactPath,
              normalizedApplicationPath != normalizedBuildArtifactPath,
              !previouslySeenPaths.contains(normalizedClonePath),
              !previouslySeenPaths.contains(normalizedApplicationPath),
              !previouslySeenPaths.contains(normalizedBuildArtifactPath) else {
            return false
        }
        return true
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func projects() -> [Project] {
        guard IrisTestEnvironment.isEnabled else { return [] }
        let file = IrisTestEnvironment.applicationSupportDirectory.appendingPathComponent("test-projects.json")
        guard file.resolvingSymlinksInPath() == file,
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 65_536, let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([Project].self, from: data), entries.count <= 12 else { return [] }
        var slugs = Set<String>()
        var bundles = Set<String>()
        var paths = Set<String>()
        for entry in entries {
            guard isValidProject(
                entry,
                within: projectsDirectory,
                applicationBundleIdentifier: Bundle(path: entry.applicationPath)?.bundleIdentifier,
                previouslySeenSlugs: slugs,
                previouslySeenBundleIdentifiers: bundles,
                previouslySeenPaths: paths
            ) else { return [] }
            slugs.insert(entry.slug)
            bundles.insert(entry.bundleIdentifier)
            paths.insert(normalizedPath(entry.clonePath))
            paths.insert(normalizedPath(entry.applicationPath))
            paths.insert(normalizedPath(entry.buildArtifactPath))
        }
        return entries
    }

    private static func isValidSlug(_ slug: String) -> Bool {
        !slug.isEmpty && slug.count <= 80
            && slug.contains(where: { $0.isASCII && ($0.isLetter || $0.isNumber) })
            && slug.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    }

    private static func isValidBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        let requiredPrefix = "com.publikhq.iris.test."
        guard bundleIdentifier.hasPrefix(requiredPrefix),
              bundleIdentifier.count > requiredPrefix.count else { return false }
        return bundleIdentifier
            .split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { segment in
                !segment.isEmpty
                    && segment.allSatisfy {
                        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
                    }
            }
    }

    private static func isValidPinnedCommit(_ pinnedCommit: String) -> Bool {
        pinnedCommit.utf8.count == 40 && pinnedCommit.utf8.allSatisfy { character in
            (character >= 48 && character <= 57)
                || (character >= 65 && character <= 70)
                || (character >= 97 && character <= 102)
        }
    }

    static func project(slug: String) -> Project? { projects().first { $0.slug == slug } }

    static func permitsEdit(slug: String, clonePath: String) -> Bool {
        guard let project = project(slug: slug) else { return false }
        return project.clonePath == clonePath && contains(clonePath, within: projectsDirectory)
    }

    static func permitsArtifact(_ artifact: String, for project: Project) -> Bool {
        guard artifact.hasPrefix("/") else { return false }
        return permitsRegisteredBuild(URL(fileURLWithPath: artifact), for: project)
    }

    /// Running-app counterpart to `permitsArtifact`. A running process may be
    /// the stable snapshot under Projects/Apps or the exact fresh build output
    /// under the registered clone. A nil URL is always ineligible.
    static func permitsRunningApplication(_ applicationURL: URL?, for project: Project) -> Bool {
        permitsRunningApplication(applicationURL, for: project, within: projectsDirectory)
    }

    /// Pure-root variant used by the native checker. Production callers use
    /// the default registry root above; the explicit root keeps the path rules
    /// testable without creating the real registry.
    static func permitsRunningApplication(
        _ applicationURL: URL?,
        for project: Project,
        within projectsDirectory: URL
    ) -> Bool {
        guard let applicationURL else { return false }
        let stableApplication = permitsExactApplication(
            applicationURL,
            matching: project.applicationPath,
            within: projectsDirectory.appendingPathComponent("Apps", isDirectory: true)
        )
        let freshBuild = permitsExactApplication(
            applicationURL,
            matching: project.buildArtifactPath,
            within: URL(fileURLWithPath: project.clonePath)
        )
        guard stableApplication || freshBuild else { return false }
        return Bundle(path: applicationURL.path)?.bundleIdentifier == project.bundleIdentifier
    }

    private static func permitsRegisteredBuild(_ applicationURL: URL, for project: Project) -> Bool {
        guard permitsExactApplication(
            applicationURL,
            matching: project.buildArtifactPath,
            within: URL(fileURLWithPath: project.clonePath)
        ) else {
            return false
        }
        return Bundle(path: applicationURL.path)?.bundleIdentifier == project.bundleIdentifier
    }

    private static func permitsExactApplication(
        _ applicationURL: URL,
        matching registeredPath: String,
        within root: URL
    ) -> Bool {
        let applicationPath = applicationURL.path
        guard applicationPath.hasPrefix("/"), applicationPath.hasSuffix(".app"),
              normalizedPath(applicationPath) == normalizedPath(registeredPath),
              contains(applicationPath, within: root) else {
            return false
        }
        return true
    }

    @MainActor static func installProvenance(into store: InstallProvenanceStore) {
        for project in projects() where store.provenance(forAppSlug: project.slug) == nil {
            store.recordGuideSourceClone(appSlug: project.slug, clonePath: project.clonePath,
                pinnedCommit: project.pinnedCommit, canonicalRepo: nil)
        }
    }

    @MainActor static func inventory() -> AppInventoryService {
        AppInventoryService(catalogDirectory: Directory(), installedApplicationLocator: Locator())
    }

    private struct Directory: CatalogAppDirectorySource {
        func catalogApps() async throws -> [CatalogAppDescriptor] {
            projects().map { CatalogAppDescriptor(slug: $0.slug, name: $0.name,
                macBundleId: $0.bundleIdentifier, latestReleaseTag: nil) }
        }
    }

    private struct Locator: InstalledApplicationLocating {
        func applicationBundleURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
            projects().first { $0.bundleIdentifier == bundleIdentifier }
                .map { URL(fileURLWithPath: $0.applicationPath) }
        }
    }
}

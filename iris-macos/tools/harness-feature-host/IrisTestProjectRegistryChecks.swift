import Foundation
@testable import IrisHarnessNative

private enum IrisTestProjectRegistryCheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

@main
struct IrisTestProjectRegistryChecks {
    static func main() throws {
        let fileManager = FileManager.default
        // Use a fresh temporary parent and pass it explicitly to the pure
        // registry validator. No real registry or user checkout is read.
        let fixtureParent = fileManager.temporaryDirectory
            .appendingPathComponent("iris-registry-parent-" + UUID().uuidString, isDirectory: true)
        let fixtureRoot = fixtureParent
            .appendingPathComponent("iris-registry-checks-" + UUID().uuidString)
        let projectsDirectory = fixtureRoot.appendingPathComponent("Projects")
        let clonesDirectory = projectsDirectory.appendingPathComponent("clones")
        let applicationsDirectory = projectsDirectory.appendingPathComponent("Apps")
        let outsideDirectory = fixtureParent
            .appendingPathComponent("iris-registry-outside-" + UUID().uuidString)
        try fileManager.createDirectory(at: fixtureParent, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: clonesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: applicationsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: fixtureRoot)
            try? fileManager.removeItem(at: outsideDirectory)
            try? fileManager.removeItem(at: fixtureParent)
        }

        let validClone = clonesDirectory.appendingPathComponent("notes")
        let validApplication = applicationsDirectory.appendingPathComponent("Iris Notes.app")
        let validBuildArtifact = validClone
            .appendingPathComponent("release/mac-arm64/Iris Notes.app")
        let validBundleIdentifier = "com.publikhq.iris.test.notes"
        let validPinnedCommit = String(repeating: "a", count: 40)
        try fileManager.createDirectory(at: validClone, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: validApplication, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: validBuildArtifact, withIntermediateDirectories: true)

        func writeBundleInfo(_ applicationURL: URL, bundleIdentifier: String) throws {
            let infoPlist = applicationURL.appendingPathComponent("Contents/Info.plist")
            try fileManager.createDirectory(
                at: infoPlist.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let infoPlistData = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": bundleIdentifier],
                format: .xml,
                options: 0
            )
            try infoPlistData.write(to: infoPlist)
        }

        try writeBundleInfo(validApplication, bundleIdentifier: validBundleIdentifier)
        try writeBundleInfo(validBuildArtifact, bundleIdentifier: validBundleIdentifier)

        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw IrisTestProjectRegistryCheckError.failed(message)
            }
        }

        func project(
            slug: String = "notes",
            clonePath: String = validClone.path,
            applicationPath: String = validApplication.path,
            buildArtifactPath: String = validBuildArtifact.path,
            bundleIdentifier: String = validBundleIdentifier,
            pinnedCommit: String = validPinnedCommit
        ) -> IrisTestProjectRegistry.Project {
            IrisTestProjectRegistry.Project(
                slug: slug,
                name: "Iris Notes",
                clonePath: clonePath,
                applicationPath: applicationPath,
                buildArtifactPath: buildArtifactPath,
                bundleIdentifier: bundleIdentifier,
                pinnedCommit: pinnedCommit
            )
        }

        let valid = project()
        try check(
            IrisTestProjectRegistry.isValidProject(
                valid,
                within: projectsDirectory,
                applicationBundleIdentifier: validBundleIdentifier
            ),
            "normal staged entry was rejected"
        )
        try check(
            IrisTestProjectRegistry.contains(validClone.path, within: projectsDirectory),
            "clone inside the staged Projects root was rejected"
        )
        try check(
            IrisTestProjectRegistry.contains(validApplication.path, within: projectsDirectory),
            "application inside the staged Projects root was rejected"
        )
        try check(
            IrisTestProjectRegistry.contains(validApplication.path, within: applicationsDirectory),
            "stable application inside the staged Apps root was rejected"
        )
        try check(
            IrisTestProjectRegistry.contains(validBuildArtifact.path, within: validClone),
            "fresh build artifact inside the clone was rejected"
        )
        try check(
            IrisTestEnvironment.identity(forBundleIdentifier: IrisTestEnvironment.testBundleIdentifier).isTestApplication,
            "exact Iris Test bundle identifier did not enable the Test identity"
        )
        try check(
            !IrisTestEnvironment.identity(forBundleIdentifier: IrisTestEnvironment.standardBundleIdentifier).isTestApplication,
            "normal Iris bundle identifier enabled the Test identity"
        )
        try check(!IrisTestEnvironment.isEnabled, "standalone checker did not use the exact Test bundle gate")
        try check(
            IrisTestProjectRegistry.projects().isEmpty,
            "non-Test runtime discovered registry projects"
        )
        print("PASS runtime gate and allowed normal staged entry")

        let siblingDirectory = projectsDirectory.deletingLastPathComponent()
            .appendingPathComponent(projectsDirectory.lastPathComponent + "-sibling")
        let traversalPath = projectsDirectory.path + "/../" + outsideDirectory.lastPathComponent + "/escaped"
        let symlinkRoot = projectsDirectory.appendingPathComponent("escape")
        try fileManager.createDirectory(at: outsideDirectory.appendingPathComponent("escaped"),
                                        withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: symlinkRoot, withDestinationURL: outsideDirectory)
        try check(
            !IrisTestProjectRegistry.contains(outsideDirectory.appendingPathComponent("outside").path,
                                              within: projectsDirectory),
            "outside-root path was accepted"
        )
        try check(
            !IrisTestProjectRegistry.contains(siblingDirectory.appendingPathComponent("sibling").path,
                                              within: projectsDirectory),
            "sibling-prefix path was accepted"
        )
        try check(
            !IrisTestProjectRegistry.contains(traversalPath, within: projectsDirectory),
            "parent traversal path was accepted"
        )
        try check(
            !IrisTestProjectRegistry.contains(symlinkRoot.appendingPathComponent("escaped").path,
                                              within: projectsDirectory),
            "symlink escape path was accepted"
        )
        try check(
            !IrisTestProjectRegistry.contains(projectsDirectory.path, within: projectsDirectory),
            "staged Projects root itself was accepted as a project path"
        )
        print("PASS containment: outside roots, sibling prefixes, traversal and symlink escapes")

        let invalidSlugs = ["", "bad id", "-", "notes_2"]
        for invalidSlug in invalidSlugs {
            try check(
                !IrisTestProjectRegistry.isValidProject(
                    project(slug: invalidSlug),
                    within: projectsDirectory,
                    applicationBundleIdentifier: validBundleIdentifier
                ),
                "invalid slug was accepted: \(invalidSlug.debugDescription)"
            )
        }
        let invalidBundleIdentifiers = [
            "com.publikhq.iris",
            "com.publikhq.iris.test",
            "com.publikhq.iris.test.",
            "com.publikhq.iris.test..notes",
            "com.publikhq.iris.test.notes/escape",
            "com.other.iris.test.notes"
        ]
        for invalidBundleIdentifier in invalidBundleIdentifiers {
            try check(
                !IrisTestProjectRegistry.isValidProject(
                    project(bundleIdentifier: invalidBundleIdentifier),
                    within: projectsDirectory,
                    applicationBundleIdentifier: invalidBundleIdentifier
                ),
                "invalid bundle identifier was accepted: \(invalidBundleIdentifier)"
            )
        }
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(),
                within: projectsDirectory,
                applicationBundleIdentifier: "com.publikhq.iris.test.other"
            ),
            "application bundle identifier mismatch was accepted"
        )
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(clonePath: "relative/clone"),
                within: projectsDirectory,
                applicationBundleIdentifier: validBundleIdentifier
            ),
            "relative clone path was accepted"
        )
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(applicationPath: applicationsDirectory.appendingPathComponent("Iris Notes").path),
                within: projectsDirectory,
                applicationBundleIdentifier: validBundleIdentifier
            ),
            "application path without .app was accepted"
        )
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(buildArtifactPath: "relative/build/Iris Notes.app"),
                within: projectsDirectory,
                applicationBundleIdentifier: validBundleIdentifier
            ),
            "relative build artifact path was accepted"
        )
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(buildArtifactPath: applicationsDirectory.appendingPathComponent("foreign.app").path),
                within: projectsDirectory,
                applicationBundleIdentifier: validBundleIdentifier
            ),
            "build artifact outside the clone was accepted"
        )
        let buildEscapeLink = validClone.appendingPathComponent("release/escape.app")
        try fileManager.createSymbolicLink(at: buildEscapeLink, withDestinationURL: outsideDirectory)
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(buildArtifactPath: buildEscapeLink.path),
                within: projectsDirectory,
                applicationBundleIdentifier: validBundleIdentifier
            ),
            "symlinked build artifact path was accepted"
        )
        for invalidPinnedCommit in [String(repeating: "a", count: 39), String(repeating: "g", count: 40)] {
            try check(
                !IrisTestProjectRegistry.isValidProject(
                    project(pinnedCommit: invalidPinnedCommit),
                    within: projectsDirectory,
                    applicationBundleIdentifier: validBundleIdentifier
                ),
                "invalid pinned commit was accepted: \(invalidPinnedCommit)"
            )
        }
        print("PASS field validation: slug, bundle ID, absolute paths, app suffix and pinned commit")

        let seenSlug = Set([valid.slug])
        let seenBundle = Set([valid.bundleIdentifier])
        let seenClonePath = Set([IrisTestProjectRegistry.normalizedPath(valid.clonePath)])
        let seenApplicationPath = Set([IrisTestProjectRegistry.normalizedPath(valid.applicationPath)])
        let seenBuildArtifactPath = Set([IrisTestProjectRegistry.normalizedPath(valid.buildArtifactPath)])
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(
                    slug: valid.slug,
                    applicationPath: applicationsDirectory.appendingPathComponent("Other.app").path,
                    buildArtifactPath: validClone.appendingPathComponent("release/mac-arm64/Other.app").path,
                    bundleIdentifier: "com.publikhq.iris.test.other"
                ),
                within: projectsDirectory,
                applicationBundleIdentifier: "com.publikhq.iris.test.other",
                previouslySeenSlugs: seenSlug
            ),
            "duplicate slug was accepted"
        )
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(
                    slug: "other",
                    applicationPath: applicationsDirectory.appendingPathComponent("Other.app").path,
                    buildArtifactPath: validClone.appendingPathComponent("release/mac-arm64/Other.app").path
                ),
                within: projectsDirectory,
                applicationBundleIdentifier: validBundleIdentifier,
                previouslySeenBundleIdentifiers: seenBundle
            ),
            "duplicate bundle ID was accepted"
        )
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(slug: "other", clonePath: validClone.path + "/../notes", bundleIdentifier: "com.publikhq.iris.test.other"),
                within: projectsDirectory,
                applicationBundleIdentifier: "com.publikhq.iris.test.other",
                previouslySeenPaths: seenClonePath
            ),
            "duplicate normalized clone path was accepted"
        )
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(slug: "other", applicationPath: validApplication.path, bundleIdentifier: "com.publikhq.iris.test.other"),
                within: projectsDirectory,
                applicationBundleIdentifier: "com.publikhq.iris.test.other",
                previouslySeenPaths: seenApplicationPath
            ),
            "duplicate application path was accepted"
        )
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(slug: "other", buildArtifactPath: validBuildArtifact.path,
                        bundleIdentifier: "com.publikhq.iris.test.other"),
                within: projectsDirectory,
                applicationBundleIdentifier: "com.publikhq.iris.test.other",
                previouslySeenPaths: seenBuildArtifactPath
            ),
            "duplicate build artifact path was accepted"
        )
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(clonePath: validApplication.path, applicationPath: validApplication.path),
                within: projectsDirectory,
                applicationBundleIdentifier: validBundleIdentifier
            ),
            "overlapping clone and application roots were accepted"
        )
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(
                    clonePath: applicationsDirectory.path,
                    applicationPath: validApplication.path,
                    buildArtifactPath: validApplication.path
                ),
                within: projectsDirectory,
                applicationBundleIdentifier: validBundleIdentifier
            ),
            "stable application and build artifact path collision was accepted"
        )
        let priorClonePathWithAppSuffix = clonesDirectory.appendingPathComponent("prior.app").path
        try check(
            !IrisTestProjectRegistry.isValidProject(
                project(slug: "other", applicationPath: priorClonePathWithAppSuffix),
                within: projectsDirectory,
                applicationBundleIdentifier: validBundleIdentifier,
                previouslySeenPaths: Set([IrisTestProjectRegistry.normalizedPath(priorClonePathWithAppSuffix)])
            ),
            "clone/application path collision was accepted"
        )

        let nestedRogueApplication = validClone.appendingPathComponent("release/rogue.app")
        try fileManager.createDirectory(at: nestedRogueApplication.appendingPathComponent("Contents"),
                                        withIntermediateDirectories: true)
        let rogueInfoPlist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": validBundleIdentifier],
            format: .xml,
            options: 0
        )
        try rogueInfoPlist.write(to: nestedRogueApplication.appendingPathComponent("Contents/Info.plist"))
        let buildSymlink = validClone.appendingPathComponent("release/alias.app")
        try fileManager.createSymbolicLink(at: buildSymlink, withDestinationURL: validBuildArtifact)
        let stableApplicationSymlink = applicationsDirectory.appendingPathComponent("Alias.app")
        try fileManager.createSymbolicLink(at: stableApplicationSymlink, withDestinationURL: validApplication)
        try check(
            Bundle(path: validApplication.path)?.bundleIdentifier == validBundleIdentifier,
            "stable fixture bundle did not expose its expected bundle ID"
        )
        try check(
            Bundle(path: validBuildArtifact.path)?.bundleIdentifier == validBundleIdentifier,
            "fresh-build fixture bundle did not expose its expected bundle ID"
        )
        try check(
            IrisTestProjectRegistry.permitsArtifact(validBuildArtifact.path, for: valid),
            "registered fresh build artifact with matching bundle ID was rejected"
        )
        try check(
            !IrisTestProjectRegistry.permitsArtifact(validApplication.path, for: valid),
            "stable snapshot was accepted as a disposable build artifact"
        )
        try check(
            IrisTestProjectRegistry.permitsRunningApplication(
                validApplication,
                for: valid,
                within: projectsDirectory
            ),
            "registered stable running application with matching bundle ID was rejected"
        )
        try check(
            IrisTestProjectRegistry.permitsRunningApplication(
                validBuildArtifact,
                for: valid,
                within: projectsDirectory
            ),
            "registered fresh build running application with matching bundle ID was rejected"
        )
        try check(
            !IrisTestProjectRegistry.permitsArtifact(
                validBuildArtifact.path,
                for: project(
                    buildArtifactPath: validBuildArtifact.path,
                    bundleIdentifier: "com.publikhq.iris.test.other"
                )
            ),
            "registered artifact with a different bundle ID was accepted"
        )
        try check(
            !IrisTestProjectRegistry.permitsArtifact(nestedRogueApplication.path, for: valid),
            "arbitrary nested matching-bundle artifact was accepted"
        )
        try check(
            !IrisTestProjectRegistry.permitsRunningApplication(nestedRogueApplication, for: valid),
            "arbitrary nested matching-bundle running app was accepted"
        )
        try check(
            !IrisTestProjectRegistry.permitsArtifact(buildSymlink.path, for: valid),
            "symlinked artifact alias was accepted"
        )
        try check(
            !IrisTestProjectRegistry.permitsRunningApplication(
                URL(fileURLWithPath: buildSymlink.path),
                for: valid,
                within: projectsDirectory
            ),
            "symlinked fresh-build running app alias was accepted"
        )
        try check(
            !IrisTestProjectRegistry.permitsRunningApplication(
                URL(fileURLWithPath: stableApplicationSymlink.path),
                for: valid,
                within: projectsDirectory
            ),
            "symlinked stable running app alias was accepted"
        )
        try check(
            !IrisTestProjectRegistry.permitsRunningApplication(nil, for: valid, within: projectsDirectory),
            "missing running application URL was accepted"
        )
        try check(
            !IrisTestProjectRegistry.permitsArtifact(validBuildArtifact.appendingPathComponent("Contents/MacOS/IrisNotes").path,
                                                     for: valid),
            "nested executable path was accepted as the registered build artifact"
        )
        print("PASS duplicate rejection: slug, bundle ID, clone path, stable app path and build path")
        print("PASS artifact gate: exact fresh build, stable/fresh running apps, canonical bundle, nested and symlink rejection")
        let applicationPolicy: (URL) -> Bool = { applicationURL in
            IrisTestProjectRegistry.permitsRunningApplication(applicationURL, for: valid, within: projectsDirectory)
        }
        try check(
            AppRelaunchService.applicationURLsAreAllowed([validApplication], by: applicationPolicy),
            "registered running application did not pass the relaunch callback gate"
        )
        try check(
            AppRelaunchService.applicationURLsAreAllowed([validBuildArtifact], by: applicationPolicy),
            "registered fresh-build running application did not pass the relaunch callback gate"
        )
        try check(
            !AppRelaunchService.applicationURLsAreAllowed([nil], by: applicationPolicy),
            "missing running-app URL passed the relaunch callback gate"
        )
        try check(
            !AppRelaunchService.applicationURLsAreAllowed([nestedRogueApplication], by: applicationPolicy),
            "foreign same-ID running app passed the relaunch callback gate"
        )
        try check(
            !AppRelaunchService.applicationURLsAreAllowed([validApplication, nestedRogueApplication], by: applicationPolicy),
            "mixed registered and foreign same-ID processes passed the relaunch callback gate"
        )
        print("PASS relaunch callback gate: nil and foreign same-ID URLs rejected")
        print("REGISTRY CHECKS PASS: 6 groups")
    }
}

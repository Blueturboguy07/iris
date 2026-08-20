//
//  RepoRecipeSwiftAppleDetector.swift
//  leanring-buddy
//
//  One row of the data-driven ecosystem registry (plan §4): the Swift/Apple
//  detector. It statically inspects a clone and reports how to install / build
//  / test / run it when the repo is a Swift Package Manager package or an
//  Xcode project/workspace.
//
//  Two shapes are recognized:
//
//    - Swift Package Manager (`Package.swift`) — fully self-describing: the
//      commands are `swift package resolve` / `swift build` / `swift test` /
//      `swift run <executable>`. No scheme guessing is needed because SPM's own
//      convention resolves everything from the manifest, so these carry higher
//      confidence than the Xcode path.
//
//    - Xcode (`*.xcodeproj` / `*.xcworkspace`) — needs a *scheme* to build, and
//      the scheme name is NOT knowable from static inspection alone. This
//      detector therefore emits the command with a literal `<scheme>`
//      placeholder at ~0.5 confidence (`genericEcosystemDefault`) and leaves the
//      real scheme to be resolved at Tier 1 by a read-only `xcodebuild -list`
//      toolchain query (plan §4). That Tier-1 introspection is a SEPARATE phase;
//      this detector never invokes `xcodebuild` — it is pure static inspection.
//
//  Every Swift/Apple app is a native, single-user desktop/CLI artifact, so this
//  detector's runtime-shape vote is ALWAYS `.pureLocalApp` (plan §8): there is
//  no server component or scale machinery hiding in an Xcode/SPM build.
//
//  Pure Foundation only. No network, no SwiftUI. Nothing here executes a
//  target repo's code: `Package.swift` is Swift source and is READ as text
//  (regex-scanned for declared executable/test targets), never evaluated — the
//  Tier-0 "safe, side-effect-free parse" rule. Directory discovery is read-only
//  `FileManager` enumeration confined to the repo root.
//

import Foundation

/// The Swift/Apple ecosystem detector (plan §4 registry row). Distinguishes an
/// SPM package from an Xcode project/workspace and derives the appropriate
/// build/test/run commands, with per-field confidence + provenance so the
/// merged recipe stays auditable (plan §5). Static inspection only.
nonisolated struct RepoRecipeSwiftAppleDetector: EcosystemDetector {

    // MARK: - Ecosystem tags

    /// The detector's family tag. The specific finding narrows this to
    /// `swift/spm` or `swift/xcode` depending on what the clone actually is.
    let ecosystemIdentifier = "swift/apple"

    /// Tag stamped on a finding when the clone is an SPM package.
    static let swiftPackageManagerEcosystemIdentifier = "swift/spm"

    /// Tag stamped on a finding when the clone is an Xcode project/workspace.
    static let xcodeEcosystemIdentifier = "swift/xcode"

    // MARK: - Confidence constants (exposed so tests assert exact values, no drift)

    /// `swift package resolve` — an ecosystem convention (Package.swift → SPM),
    /// not a manifest-declared script string, so it is a generic default.
    static let swiftPackageManagerInstallConfidence = 0.6

    /// `swift build` — unambiguous for any Package.swift; higher confidence than
    /// the Xcode path because no scheme guessing is involved.
    static let swiftPackageManagerBuildConfidence = 0.9

    /// `swift test` — only offered when a real test target/`Tests` dir exists.
    static let swiftPackageManagerTestConfidence = 0.8

    /// `swift run <executable>` — a regex-scan heuristic over Swift source, so
    /// moderate confidence even though the name is lifted from the manifest.
    static let swiftPackageManagerRunConfidence = 0.7

    /// `xcodebuild -scheme <scheme> build` with a single, unambiguous container.
    /// The plan pins the Xcode path at ~0.5 precisely because the scheme is a
    /// placeholder resolved later, not a statically-known value.
    static let xcodeBuildDefaultConfidence = 0.5

    /// Lowered confidence when more than one build container makes the choice of
    /// project/scheme genuinely ambiguous — the plan's rule is to lower
    /// confidence and surface the conflict (§4), not silently pick.
    static let xcodeBuildAmbiguousContainerConfidence = 0.3

    // MARK: - Command literals

    /// The literal placeholder written into the Xcode build command. It is NOT
    /// a real scheme — a Tier-1 `xcodebuild -list` query fills it in. Kept as a
    /// named constant so the consumer and the tests reference exactly one token.
    static let xcodeSchemePlaceholder = "<scheme>"

    // MARK: - Directory-scan hygiene

    /// Directories that are never a project's own source and would only add
    /// noise (or a stray generated `.xcodeproj`) if scanned. Skipped when
    /// descending one level to discover Xcode containers.
    private static let directoryNamesToSkipWhenScanning: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "Pods", "Carthage",
        "DerivedData", "build"
    ]

    // MARK: - Detect

    /// Inspect the clone at `repoRootPath`. Xcode containers take precedence over
    /// a bare `Package.swift` because an `.xcworkspace`/`.xcodeproj` is how a
    /// shippable, relaunchable macOS app is built — a repo that has both is
    /// almost always an app with a local Swift package, and the app build is the
    /// one the Feature Engine needs. Returns nil when the clone shows no
    /// Swift/Apple signal at all (the honest "nothing to say").
    func detect(repoRootPath: String) -> EcosystemDetectorFinding? {
        let xcodeContainers = Self.locateXcodeBuildContainers(underRepoRootPath: repoRootPath)
        if !xcodeContainers.isEmpty {
            return makeXcodeBuildFinding(fromContainers: xcodeContainers)
        }

        if let swiftPackageManifest = Self.locateSwiftPackageManifest(underRepoRootPath: repoRootPath) {
            return makeSwiftPackageManagerFinding(
                fromManifest: swiftPackageManifest,
                underRepoRootPath: repoRootPath
            )
        }

        return nil
    }

    // MARK: - Xcode finding

    private func makeXcodeBuildFinding(
        fromContainers xcodeContainers: [XcodeBuildContainerLocation]
    ) -> EcosystemDetectorFinding {
        let workspaceContainers = xcodeContainers.filter { $0.kind == .workspace }
        let projectContainers = xcodeContainers.filter { $0.kind == .project }

        // A workspace is the canonical container: when one exists it wins over
        // any sibling projects (an `.xcworkspace` usually wraps them), so that
        // pairing is NOT a conflict. Ambiguity is only real when there are two
        // workspaces, or no workspace and two-or-more standalone projects —
        // there `xcodebuild` (with no `-project`/`-workspace` flag) can't tell
        // which one to build, so we lower confidence and let the ambiguity
        // surface as a clarification (plan §4) instead of guessing.
        let containerChoiceIsAmbiguous =
            workspaceContainers.count > 1 ||
            (workspaceContainers.isEmpty && projectContainers.count > 1)

        let buildAndTestConfidence = containerChoiceIsAmbiguous
            ? Self.xcodeBuildAmbiguousContainerConfidence
            : Self.xcodeBuildDefaultConfidence

        guard let chosenContainer = workspaceContainers.first ?? projectContainers.first else {
            // Unreachable: detect() only calls this with a non-empty container
            // list. Returned as a benign, non-matching finding so a future
            // refactor can never turn "impossible" into a crash.
            return EcosystemDetectorFinding(
                ecosystemIdentifier: Self.xcodeEcosystemIdentifier,
                commandsByField: [:],
                confidenceByField: [:],
                provenanceByField: [:],
                runtimeShapeContribution: .pureLocalApp,
                matched: false
            )
        }

        // Run `xcodebuild` from the directory that actually holds the container
        // so it finds the single project/workspace there without a flag.
        let containerWorkingSubdirectory = chosenContainer.relativeParentDirectory

        let buildCommand = RepoRecipeCommand(
            commandLine: "xcodebuild -scheme \(Self.xcodeSchemePlaceholder) build",
            workingSubdirectory: containerWorkingSubdirectory
        )
        let testCommand = RepoRecipeCommand(
            commandLine: "xcodebuild test",
            workingSubdirectory: containerWorkingSubdirectory
        )

        // No `run` command: an Xcode app is launched as a built `.app` bundle
        // (AppRelaunchService's job), which is not statically derivable here —
        // the plan's "GUI run low/nil confidence". Leaving it absent is the
        // honest "unknown", never a fabricated guess. `install` and `package`
        // are likewise left to later tiers; the recipe is already buildable via
        // the build command.
        return EcosystemDetectorFinding(
            ecosystemIdentifier: Self.xcodeEcosystemIdentifier,
            commandsByField: [.build: buildCommand, .test: testCommand],
            confidenceByField: [.build: buildAndTestConfidence, .test: buildAndTestConfidence],
            provenanceByField: [.build: .genericEcosystemDefault, .test: .genericEcosystemDefault],
            runtimeShapeContribution: .pureLocalApp,
            matched: true
        )
    }

    // MARK: - Swift Package Manager finding

    private func makeSwiftPackageManagerFinding(
        fromManifest swiftPackageManifest: SwiftPackageManifestLocation,
        underRepoRootPath repoRootPath: String
    ) -> EcosystemDetectorFinding {
        let packageWorkingSubdirectory = swiftPackageManifest.relativeParentDirectory
        let manifestText = RepoRecipeFiles.readText(
            swiftPackageManifest.relativeManifestPath,
            underRepoRoot: repoRootPath
        ) ?? ""

        var commandsByField: [RecipeField: RepoRecipeCommand] = [:]
        var confidenceByField: [RecipeField: Double] = [:]
        var provenanceByField: [RecipeField: RecipeSignalProvenance] = [:]

        // install — `swift package resolve` fetches declared dependencies. This
        // needs the network, so it lands in the un-jailed stage; it is a no-op
        // for a package with no external deps, so it is safe to always include.
        commandsByField[.install] = RepoRecipeCommand(
            commandLine: "swift package resolve",
            workingSubdirectory: packageWorkingSubdirectory
        )
        confidenceByField[.install] = Self.swiftPackageManagerInstallConfidence
        provenanceByField[.install] = .genericEcosystemDefault

        // build — `swift build` is unambiguous for any Package.swift.
        commandsByField[.build] = RepoRecipeCommand(
            commandLine: "swift build",
            workingSubdirectory: packageWorkingSubdirectory
        )
        confidenceByField[.build] = Self.swiftPackageManagerBuildConfidence
        provenanceByField[.build] = .genericEcosystemDefault

        // test — only when the package actually declares a test target or ships
        // a `Tests` directory. `swift test` on a suite-less package exits 0 with
        // "no tests" — a silent green the plan forbids — so a missing suite is
        // reported as an honest nil (absent field) rather than a fake pass.
        let packageDeclaresRealTests =
            Self.manifestTextDeclaresATestTarget(manifestText) ||
            Self.swiftPackageHasATestsDirectory(
                forManifest: swiftPackageManifest,
                underRepoRootPath: repoRootPath
            )
        if packageDeclaresRealTests {
            commandsByField[.test] = RepoRecipeCommand(
                commandLine: "swift test",
                workingSubdirectory: packageWorkingSubdirectory
            )
            confidenceByField[.test] = Self.swiftPackageManagerTestConfidence
            provenanceByField[.test] = .genericEcosystemDefault
        }

        // run — `swift run <executable>` only when EXACTLY ONE executable is
        // declared. Zero executables (a library) has nothing to run; more than
        // one makes a bare `swift run` ambiguous (SPM errors without a name), so
        // both cases leave `run` absent rather than picking arbitrarily.
        let distinctExecutableNames = Self.orderedUniqueStrings(
            Self.executableTargetOrProductNames(inManifestText: manifestText)
        )
        if distinctExecutableNames.count == 1 {
            commandsByField[.run] = RepoRecipeCommand(
                commandLine: "swift run \(distinctExecutableNames[0])",
                workingSubdirectory: packageWorkingSubdirectory
            )
            confidenceByField[.run] = Self.swiftPackageManagerRunConfidence
            provenanceByField[.run] = .genericEcosystemDefault
        }

        return EcosystemDetectorFinding(
            ecosystemIdentifier: Self.swiftPackageManagerEcosystemIdentifier,
            commandsByField: commandsByField,
            confidenceByField: confidenceByField,
            provenanceByField: provenanceByField,
            runtimeShapeContribution: .pureLocalApp,
            matched: true
        )
    }

    // MARK: - Xcode container discovery

    /// One discovered Xcode build container and where it lives relative to the
    /// repo root, so its commands can be pinned to the right subdirectory.
    private struct XcodeBuildContainerLocation: Equatable {
        enum Kind: Equatable {
            case workspace
            case project
        }

        let kind: Kind

        /// Repo-relative directory that CONTAINS the container; nil = repo root.
        let relativeParentDirectory: String?
    }

    /// Find every `.xcworkspace`/`.xcodeproj` at the repo root and one level
    /// deep. Depth is capped at one because real macOS projects sit at the root
    /// or in a single obvious subdirectory (e.g. `macos/App.xcodeproj`); going
    /// deeper only risks picking up generated or vendored projects.
    ///
    /// `RepoRecipeFiles` deliberately exposes no glob/list surface, and a
    /// container's NAME is unknown ahead of time, so this reads the directory
    /// directly through read-only `FileManager` enumeration. It stays contained:
    /// every path is built from `repoRootPath` plus a single component returned
    /// by enumerating a directory under that root — never a repo-supplied
    /// traversal — so it cannot walk out of the clone.
    private static func locateXcodeBuildContainers(
        underRepoRootPath repoRootPath: String
    ) -> [XcodeBuildContainerLocation] {
        var discoveredContainers: [XcodeBuildContainerLocation] = []

        for entryName in entryNames(inRelativeDirectory: nil, underRepoRootPath: repoRootPath) {
            if let containerKind = xcodeContainerKind(forEntryName: entryName) {
                discoveredContainers.append(
                    XcodeBuildContainerLocation(kind: containerKind, relativeParentDirectory: nil)
                )
            }
        }

        for childDirectoryName in immediateChildDirectoryNames(
            ofRelativeDirectory: nil,
            underRepoRootPath: repoRootPath
        ) {
            for entryName in entryNames(
                inRelativeDirectory: childDirectoryName,
                underRepoRootPath: repoRootPath
            ) {
                if let containerKind = xcodeContainerKind(forEntryName: entryName) {
                    discoveredContainers.append(
                        XcodeBuildContainerLocation(
                            kind: containerKind,
                            relativeParentDirectory: childDirectoryName
                        )
                    )
                }
            }
        }

        return discoveredContainers
    }

    /// Classify a directory-entry name as an Xcode container by suffix, or nil.
    private static func xcodeContainerKind(
        forEntryName entryName: String
    ) -> XcodeBuildContainerLocation.Kind? {
        if entryName.hasSuffix(".xcworkspace") { return .workspace }
        if entryName.hasSuffix(".xcodeproj") { return .project }
        return nil
    }

    // MARK: - Swift Package manifest discovery

    /// Where a `Package.swift` lives, so SPM commands run from the right dir.
    private struct SwiftPackageManifestLocation {
        /// Repo-relative path to the manifest file itself.
        let relativeManifestPath: String

        /// Repo-relative directory containing it; nil = repo root.
        let relativeParentDirectory: String?
    }

    /// Locate a `Package.swift` at the repo root, or failing that one level
    /// deep (a monorepo may keep the package in a subdirectory). Root wins.
    private static func locateSwiftPackageManifest(
        underRepoRootPath repoRootPath: String
    ) -> SwiftPackageManifestLocation? {
        if RepoRecipeFiles.fileExists("Package.swift", underRepoRoot: repoRootPath) {
            return SwiftPackageManifestLocation(
                relativeManifestPath: "Package.swift",
                relativeParentDirectory: nil
            )
        }

        for childDirectoryName in immediateChildDirectoryNames(
            ofRelativeDirectory: nil,
            underRepoRootPath: repoRootPath
        ) {
            let candidateManifestPath = childDirectoryName + "/Package.swift"
            if RepoRecipeFiles.fileExists(candidateManifestPath, underRepoRoot: repoRootPath) {
                return SwiftPackageManifestLocation(
                    relativeManifestPath: candidateManifestPath,
                    relativeParentDirectory: childDirectoryName
                )
            }
        }

        return nil
    }

    /// True when the package ships a conventional `Tests` directory next to its
    /// manifest — a strong signal that `swift test` will actually run something.
    private static func swiftPackageHasATestsDirectory(
        forManifest swiftPackageManifest: SwiftPackageManifestLocation,
        underRepoRootPath repoRootPath: String
    ) -> Bool {
        let testsDirectoryRelativePath: String
        if let parentDirectory = swiftPackageManifest.relativeParentDirectory {
            testsDirectoryRelativePath = parentDirectory + "/Tests"
        } else {
            testsDirectoryRelativePath = "Tests"
        }
        return RepoRecipeFiles.fileExists(testsDirectoryRelativePath, underRepoRoot: repoRootPath)
    }

    // MARK: - Manifest text scans (read-only; Package.swift is NEVER evaluated)

    /// Whether the manifest text declares a `.testTarget(...)`. A pure regex
    /// scan of the source — the manifest is Swift code and must not be executed
    /// (Tier-0 rule), so this reads it as text only.
    private static func manifestTextDeclaresATestTarget(_ manifestText: String) -> Bool {
        return manifestText.range(
            of: "\\.testTarget\\s*\\(",
            options: .regularExpression
        ) != nil
    }

    /// Extract the declared names of every `.executableTarget(name: "…")` and
    /// `.executable(name: "…")` (the product form) in the manifest text. Anchored
    /// on the `.executable`/`.executableTarget` call so it never captures the
    /// package's own `name:` or a `.library`/`.target` name. Order preserved;
    /// duplicates left in for the caller to de-duplicate.
    private static func executableTargetOrProductNames(
        inManifestText manifestText: String
    ) -> [String] {
        let executableDeclarationPattern =
            "\\.executable(?:Target)?\\s*\\(\\s*name:\\s*\"([^\"]+)\""
        guard let regularExpression = try? NSRegularExpression(
            pattern: executableDeclarationPattern
        ) else {
            return []
        }

        let fullTextRange = NSRange(
            manifestText.startIndex..<manifestText.endIndex,
            in: manifestText
        )

        var declaredExecutableNames: [String] = []
        for match in regularExpression.matches(in: manifestText, range: fullTextRange) {
            guard match.numberOfRanges >= 2,
                  let capturedNameRange = Range(match.range(at: 1), in: manifestText)
            else { continue }
            declaredExecutableNames.append(String(manifestText[capturedNameRange]))
        }
        return declaredExecutableNames
    }

    /// De-duplicate while preserving first-seen order (so a single executable
    /// declared twice still reads as one, and the "exactly one" run rule holds).
    private static func orderedUniqueStrings(_ values: [String]) -> [String] {
        var seenValues: Set<String> = []
        var uniqueValues: [String] = []
        for value in values where !seenValues.contains(value) {
            seenValues.insert(value)
            uniqueValues.append(value)
        }
        return uniqueValues
    }

    // MARK: - Read-only directory enumeration (contained to the repo root)

    /// The names of every entry in a repo-relative directory (nil = repo root).
    /// Read-only; returns [] for anything unreadable so a missing directory and
    /// an unreadable one look identical to the caller.
    private static func entryNames(
        inRelativeDirectory relativeDirectory: String?,
        underRepoRootPath repoRootPath: String
    ) -> [String] {
        let directoryURL = absoluteURL(
            forRelativeDirectory: relativeDirectory,
            underRepoRootPath: repoRootPath
        )
        return (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
    }

    /// The names of immediate SUBDIRECTORIES worth descending into: real
    /// directories only, minus the well-known noise dirs, and never an Xcode
    /// container bundle (those are handled as containers, not descended into).
    private static func immediateChildDirectoryNames(
        ofRelativeDirectory relativeDirectory: String?,
        underRepoRootPath repoRootPath: String
    ) -> [String] {
        let baseDirectoryURL = absoluteURL(
            forRelativeDirectory: relativeDirectory,
            underRepoRootPath: repoRootPath
        )

        var childDirectoryNames: [String] = []
        for entryName in entryNames(
            inRelativeDirectory: relativeDirectory,
            underRepoRootPath: repoRootPath
        ) {
            if directoryNamesToSkipWhenScanning.contains(entryName) { continue }
            // An `.xcodeproj`/`.xcworkspace` is itself a directory bundle; it is
            // a container to detect, not a subtree to walk into.
            if xcodeContainerKind(forEntryName: entryName) != nil { continue }

            var entryIsDirectory: ObjCBool = false
            let entryURL = baseDirectoryURL.appendingPathComponent(entryName)
            let entryExists = FileManager.default.fileExists(
                atPath: entryURL.path,
                isDirectory: &entryIsDirectory
            )
            if entryExists && entryIsDirectory.boolValue {
                childDirectoryNames.append(entryName)
            }
        }
        return childDirectoryNames
    }

    /// Resolve a repo-relative directory (nil = root) to an absolute URL under
    /// the repo root. Inputs are always single components discovered by
    /// enumerating a directory beneath the root, so no traversal escape is
    /// possible.
    private static func absoluteURL(
        forRelativeDirectory relativeDirectory: String?,
        underRepoRootPath repoRootPath: String
    ) -> URL {
        let repoRootURL = URL(fileURLWithPath: repoRootPath)
        guard let relativeDirectory, !relativeDirectory.isEmpty else {
            return repoRootURL
        }
        return repoRootURL.appendingPathComponent(relativeDirectory)
    }
}

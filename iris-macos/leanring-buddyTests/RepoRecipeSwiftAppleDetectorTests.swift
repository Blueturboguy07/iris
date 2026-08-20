//
//  RepoRecipeSwiftAppleDetectorTests.swift
//  leanring-buddyTests
//
//  Fixture-driven unit coverage for the Swift/Apple ecosystem detector
//  (plan §4/§10.1). Each test builds a throwaway repo in a temp directory so
//  the REAL static-inspection paths run against REAL files, then asserts the
//  derived commands, their runtime-shape vote, their provenance, and their
//  confidence — plus the honest-nil (negative) and lower-confidence (conflict)
//  behaviors the plan requires instead of a silent guess.
//
//  Pure/deterministic: no process spawning, no network. `xcodebuild` and
//  `swift` are NEVER invoked — the detector only reads files.
//

import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

@Suite struct RepoRecipeSwiftAppleDetectorTests {

    // MARK: - Swift Package Manager

    @Test func detectsASwiftPackageWithAnExecutableAndTestsAndResolvesEveryField() throws {
        let repository = try TemporarySwiftAppleRepositoryDirectory()
        defer { repository.removeEverything() }

        // A conventional executable package: one executable target + a test
        // target. The `name: "MyTool"` on the Package(...) line must NOT be
        // mistaken for the executable's name — only the `.executableTarget`
        // name should be lifted.
        try repository.writeFile(
            atRelativePath: "Package.swift",
            contents: """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(
                name: "MyTool",
                targets: [
                    .executableTarget(name: "MyTool", dependencies: []),
                    .testTarget(name: "MyToolTests", dependencies: ["MyTool"]),
                ]
            )
            """
        )

        let finding = try #require(
            RepoRecipeSwiftAppleDetector().detect(repoRootPath: repository.rootPath)
        )

        #expect(finding.matched)
        #expect(finding.ecosystemIdentifier
            == RepoRecipeSwiftAppleDetector.swiftPackageManagerEcosystemIdentifier)
        // Every Swift/Apple build is a native single-user artifact.
        #expect(finding.runtimeShapeContribution == .pureLocalApp)

        #expect(finding.commandsByField[.install]?.commandLine == "swift package resolve")
        #expect(finding.commandsByField[.build]?.commandLine == "swift build")
        #expect(finding.commandsByField[.test]?.commandLine == "swift test")
        #expect(finding.commandsByField[.run]?.commandLine == "swift run MyTool")

        // Root package → no working subdirectory on any command.
        #expect(finding.commandsByField[.build]?.workingSubdirectory == nil)
        #expect(finding.commandsByField[.run]?.workingSubdirectory == nil)

        // Provenance: SPM commands are ecosystem conventions, not parsed script
        // strings, so every field is a generic default (auditable in §5's trail).
        for field in [RecipeField.install, .build, .test, .run] {
            #expect(finding.provenanceByField[field] == .genericEcosystemDefault)
        }

        #expect(finding.confidenceByField[.install]
            == RepoRecipeSwiftAppleDetector.swiftPackageManagerInstallConfidence)
        #expect(finding.confidenceByField[.build]
            == RepoRecipeSwiftAppleDetector.swiftPackageManagerBuildConfidence)
        #expect(finding.confidenceByField[.test]
            == RepoRecipeSwiftAppleDetector.swiftPackageManagerTestConfidence)
        #expect(finding.confidenceByField[.run]
            == RepoRecipeSwiftAppleDetector.swiftPackageManagerRunConfidence)
    }

    @Test func aSwiftLibraryPackageHasNoRunAndNoTestWithoutARealSuite() throws {
        let repository = try TemporarySwiftAppleRepositoryDirectory()
        defer { repository.removeEverything() }

        // A pure library: no executable target, no test target, no Tests dir.
        try repository.writeFile(
            atRelativePath: "Package.swift",
            contents: """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(
                name: "MyLib",
                products: [ .library(name: "MyLib", targets: ["MyLib"]) ],
                targets: [ .target(name: "MyLib") ]
            )
            """
        )

        let finding = try #require(
            RepoRecipeSwiftAppleDetector().detect(repoRootPath: repository.rootPath)
        )

        // Build + install still resolve — the package is rebuildable.
        #expect(finding.commandsByField[.build]?.commandLine == "swift build")
        #expect(finding.commandsByField[.install]?.commandLine == "swift package resolve")

        // No suite → honest nil (never a silent "swift test found nothing" green).
        #expect(finding.commandsByField[.test] == nil)
        #expect(finding.confidenceByField[.test] == nil)
        #expect(finding.provenanceByField[.test] == nil)

        // No executable → nothing to run; the field is absent, not guessed.
        #expect(finding.commandsByField[.run] == nil)
        #expect(finding.confidenceByField[.run] == nil)
    }

    @Test func aTestsDirectoryAloneIsEnoughToOfferSwiftTest() throws {
        let repository = try TemporarySwiftAppleRepositoryDirectory()
        defer { repository.removeEverything() }

        // Manifest declares no `.testTarget`, but a conventional `Tests`
        // directory exists — that is enough for `swift test` to run something.
        try repository.writeFile(
            atRelativePath: "Package.swift",
            contents: """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "MyLib", targets: [ .target(name: "MyLib") ])
            """
        )
        try repository.makeDirectory(atRelativePath: "Tests")

        let finding = try #require(
            RepoRecipeSwiftAppleDetector().detect(repoRootPath: repository.rootPath)
        )

        #expect(finding.commandsByField[.test]?.commandLine == "swift test")
        #expect(finding.confidenceByField[.test]
            == RepoRecipeSwiftAppleDetector.swiftPackageManagerTestConfidence)
    }

    @Test func multipleExecutablesLeaveTheRunFieldUnsetBecauseItIsAmbiguous() throws {
        let repository = try TemporarySwiftAppleRepositoryDirectory()
        defer { repository.removeEverything() }

        // Two executables → a bare `swift run` would be ambiguous, so run is
        // left absent rather than arbitrarily picking one.
        try repository.writeFile(
            atRelativePath: "Package.swift",
            contents: """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(
                name: "MultiTool",
                targets: [
                    .executableTarget(name: "ToolA"),
                    .executableTarget(name: "ToolB"),
                ]
            )
            """
        )

        let finding = try #require(
            RepoRecipeSwiftAppleDetector().detect(repoRootPath: repository.rootPath)
        )

        #expect(finding.commandsByField[.run] == nil)
        // Build is still resolved regardless of the run ambiguity.
        #expect(finding.commandsByField[.build]?.commandLine == "swift build")
    }

    @Test func aSwiftPackageInASubdirectoryPinsEveryCommandToThatSubdirectory() throws {
        let repository = try TemporarySwiftAppleRepositoryDirectory()
        defer { repository.removeEverything() }

        // Monorepo: the package lives one level down. Every command must run
        // from that subdirectory, or `swift build` would find nothing at root.
        try repository.writeFile(
            atRelativePath: "backend/Package.swift",
            contents: """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(
                name: "Server",
                targets: [ .executableTarget(name: "Server") ]
            )
            """
        )

        let finding = try #require(
            RepoRecipeSwiftAppleDetector().detect(repoRootPath: repository.rootPath)
        )

        #expect(finding.commandsByField[.build]?.workingSubdirectory == "backend")
        #expect(finding.commandsByField[.install]?.workingSubdirectory == "backend")
        #expect(finding.commandsByField[.run]?.commandLine == "swift run Server")
        #expect(finding.commandsByField[.run]?.workingSubdirectory == "backend")
    }

    // MARK: - Xcode

    @Test func detectsASingleXcodeProjectWithASchemePlaceholderAtGenericConfidence() throws {
        let repository = try TemporarySwiftAppleRepositoryDirectory()
        defer { repository.removeEverything() }

        // An `.xcodeproj` is a directory bundle; detection is by name.
        try repository.makeDirectory(atRelativePath: "MyApp.xcodeproj")

        let finding = try #require(
            RepoRecipeSwiftAppleDetector().detect(repoRootPath: repository.rootPath)
        )

        #expect(finding.matched)
        #expect(finding.ecosystemIdentifier
            == RepoRecipeSwiftAppleDetector.xcodeEcosystemIdentifier)
        #expect(finding.runtimeShapeContribution == .pureLocalApp)

        // The scheme is not statically knowable, so it is emitted as the literal
        // placeholder to be resolved at Tier 1 via `xcodebuild -list`.
        #expect(finding.commandsByField[.build]?.commandLine
            == "xcodebuild -scheme \(RepoRecipeSwiftAppleDetector.xcodeSchemePlaceholder) build")
        #expect(finding.commandsByField[.build]?.commandLine.contains("<scheme>") == true)
        #expect(finding.commandsByField[.test]?.commandLine == "xcodebuild test")

        // GUI run is not statically derivable → absent, not a low-value guess.
        #expect(finding.commandsByField[.run] == nil)

        #expect(finding.provenanceByField[.build] == .genericEcosystemDefault)
        #expect(finding.provenanceByField[.test] == .genericEcosystemDefault)
        #expect(finding.confidenceByField[.build]
            == RepoRecipeSwiftAppleDetector.xcodeBuildDefaultConfidence)
        #expect(finding.confidenceByField[.test]
            == RepoRecipeSwiftAppleDetector.xcodeBuildDefaultConfidence)
    }

    @Test func aWorkspaceAlongsideItsProjectIsNotAConflict() throws {
        let repository = try TemporarySwiftAppleRepositoryDirectory()
        defer { repository.removeEverything() }

        // The canonical pairing: a workspace wrapping its project. The workspace
        // wins and confidence stays at the default — this is NOT ambiguous.
        try repository.makeDirectory(atRelativePath: "MyApp.xcodeproj")
        try repository.makeDirectory(atRelativePath: "MyApp.xcworkspace")

        let finding = try #require(
            RepoRecipeSwiftAppleDetector().detect(repoRootPath: repository.rootPath)
        )

        #expect(finding.ecosystemIdentifier
            == RepoRecipeSwiftAppleDetector.xcodeEcosystemIdentifier)
        #expect(finding.confidenceByField[.build]
            == RepoRecipeSwiftAppleDetector.xcodeBuildDefaultConfidence)
    }

    @Test func twoStandaloneProjectsLowerConfidenceInsteadOfSilentlyPicking() throws {
        let repository = try TemporarySwiftAppleRepositoryDirectory()
        defer { repository.removeEverything() }

        // Two standalone projects, no workspace: `xcodebuild` (no -project flag)
        // cannot tell which to build. The plan's rule is to LOWER confidence and
        // surface the ambiguity, not to guess.
        try repository.makeDirectory(atRelativePath: "AppOne.xcodeproj")
        try repository.makeDirectory(atRelativePath: "AppTwo.xcodeproj")

        let finding = try #require(
            RepoRecipeSwiftAppleDetector().detect(repoRootPath: repository.rootPath)
        )

        #expect(finding.confidenceByField[.build]
            == RepoRecipeSwiftAppleDetector.xcodeBuildAmbiguousContainerConfidence)
        #expect(finding.confidenceByField[.test]
            == RepoRecipeSwiftAppleDetector.xcodeBuildAmbiguousContainerConfidence)
        // Still a genuine Xcode finding — the ambiguity lowers confidence, it
        // does not blank out the recipe.
        #expect(finding.commandsByField[.build]?.commandLine.hasPrefix("xcodebuild") == true)
    }

    @Test func anXcodeProjectInASubdirectoryPinsCommandsToThatSubdirectory() throws {
        let repository = try TemporarySwiftAppleRepositoryDirectory()
        defer { repository.removeEverything() }

        try repository.makeDirectory(atRelativePath: "macos/App.xcodeproj")

        let finding = try #require(
            RepoRecipeSwiftAppleDetector().detect(repoRootPath: repository.rootPath)
        )

        #expect(finding.ecosystemIdentifier
            == RepoRecipeSwiftAppleDetector.xcodeEcosystemIdentifier)
        #expect(finding.commandsByField[.build]?.workingSubdirectory == "macos")
        #expect(finding.commandsByField[.test]?.workingSubdirectory == "macos")
    }

    @Test func anXcodeContainerWinsOverASiblingSwiftPackage() throws {
        let repository = try TemporarySwiftAppleRepositoryDirectory()
        defer { repository.removeEverything() }

        // An app with a local Swift package: the `.xcodeproj` is how the
        // relaunchable app is built, so the Xcode path takes precedence.
        try repository.makeDirectory(atRelativePath: "MyApp.xcodeproj")
        try repository.writeFile(
            atRelativePath: "Package.swift",
            contents: """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(name: "LocalPackage", targets: [ .target(name: "LocalPackage") ])
            """
        )

        let finding = try #require(
            RepoRecipeSwiftAppleDetector().detect(repoRootPath: repository.rootPath)
        )

        #expect(finding.ecosystemIdentifier
            == RepoRecipeSwiftAppleDetector.xcodeEcosystemIdentifier)
        #expect(finding.commandsByField[.build]?.commandLine.hasPrefix("xcodebuild") == true)
        #expect(finding.confidenceByField[.build]
            == RepoRecipeSwiftAppleDetector.xcodeBuildDefaultConfidence)
    }

    // MARK: - Negative

    @Test func aNonSwiftRepositoryYieldsNoFinding() throws {
        let repository = try TemporarySwiftAppleRepositoryDirectory()
        defer { repository.removeEverything() }

        // A Node repo — no Package.swift, no Xcode container anywhere. The Swift
        // detector has nothing to say and must not fabricate one.
        try repository.writeFile(
            atRelativePath: "package.json",
            contents: "{ \"name\": \"web\", \"scripts\": { \"build\": \"next build\" } }"
        )

        #expect(RepoRecipeSwiftAppleDetector().detect(repoRootPath: repository.rootPath) == nil)
    }
}

// MARK: - Fixture repository

/// Builds a throwaway repository tree in a unique temp directory so the real
/// file-inspection paths run against real files. Supports plain text files
/// (creating intermediate directories) and bare directories — enough to model
/// `Package.swift`, a `Tests/` folder, and `.xcodeproj`/`.xcworkspace` bundles.
private struct TemporarySwiftAppleRepositoryDirectory {
    let rootURL: URL

    var rootPath: String { rootURL.path }

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-swift-apple-detector-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func writeFile(atRelativePath relativePath: String, contents: String) throws {
        let fileURL = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.data(using: .utf8)!.write(to: fileURL)
    }

    func makeDirectory(atRelativePath relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent(relativePath),
            withIntermediateDirectories: true
        )
    }

    func removeEverything() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

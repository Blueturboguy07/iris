//
//  RepoRecipeServiceTests.swift
//  leanring-buddyTests
//
//  Unit tests for `RepoRecipeService` — the Feature Engine's recipe-derivation
//  front door (plan §4/§5). Each test builds a tiny real repo in a temp
//  directory, runs the service's pure static derivation over it, and asserts the
//  merged recipe: which command wins each field, its provenance, its confidence,
//  the ecosystem tag, the runtime shape, and — the headline capability — whether
//  the repo now has a buildable recipe (the check that replaces today's hard
//  "unknown stack" refusal).
//
//  The corpus covers the load-bearing behaviors the task calls out:
//    - A real Tauri app (a Rust crate + a frontend package.json) whose signals
//      from TWO detectors merge into one recipe, and which is buildable.
//    - A Next.js app and an Xcode project, both buildable.
//    - A bare, unrecognized repo that is NOT buildable (routes to clarification).
//    - Makefile-vs-package.json precedence: a hand-written `make build` target
//      (explicit author intent) beats a framework-default `next build`.
//    - CI-workflow mining: a `.github/workflows` `run:` step outranks a guessed
//      generic default, an authored manifest script outranks a CI step, and a
//      genuine command disagreement lowers the merged confidence.
//
//  Pure logic + filesystem — no processes, no network, nothing is ever executed.
//

import Foundation
import Testing
@testable import Iris

@Suite struct RepoRecipeServiceTests {

    // MARK: - Fixture helper

    /// Materialize a throwaway repo: write every (repo-relative path → contents)
    /// pair, creating intermediate directories so a fixture can place nested
    /// files (e.g. "src-tauri/tauri.conf.json", ".github/workflows/ci.yml"), and
    /// return the repo root path. The caller removes it via `removeFixtureRepo`.
    static func makeFixtureRepo(files: [String: String]) throws -> String {
        let repoRootPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-recipe-service-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(
            atPath: repoRootPath,
            withIntermediateDirectories: true
        )
        for (repoRelativePath, contents) in files {
            let absoluteFilePath = (repoRootPath as NSString)
                .appendingPathComponent(repoRelativePath)
            let containingDirectory = (absoluteFilePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: containingDirectory,
                withIntermediateDirectories: true
            )
            try contents.write(toFile: absoluteFilePath, atomically: true, encoding: .utf8)
        }
        return repoRootPath
    }

    static func removeFixtureRepo(_ repoRootPath: String) {
        try? FileManager.default.removeItem(atPath: repoRootPath)
    }

    // MARK: - Tauri: two detectors' signals merge into one buildable recipe

    @Test func tauriAppMergesNodeAndRustSignalsIntoOneBuildableRecipe() throws {
        // A real Tauri app has BOTH a frontend package.json (the Node detector
        // matches) AND a src-tauri crate + tauri.conf.json (the Rust/Tauri
        // detector matches). The two findings must merge into a single coherent
        // recipe, with the higher-confidence Tauri build/run winning their fields.
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "package.json": #"""
            {
              "scripts": { "dev": "vite", "build": "vite build" },
              "devDependencies": { "vite": "5.0.0", "@tauri-apps/cli": "2.0.0" }
            }
            """#,
            "package-lock.json": "",
            "src-tauri/tauri.conf.json": #"""
            {
              "build": {
                "beforeBuildCommand": "npm run build",
                "beforeDevCommand": "npm run dev"
              }
            }
            """#,
            "src-tauri/Cargo.toml": "[package]\nname = \"app\"\nversion = \"0.1.0\"\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        // The headline capability: the wall is gone — this repo is buildable.
        #expect(RepoRecipeService.hasBuildableRecipe(repoRootPath: repoRootPath))

        let recipe = RepoRecipeService.deriveRecipe(repoRootPath: repoRootPath)

        // build: the Tauri build (which runs the frontend build first, then the
        // release cargo compile) wins over the Node `npm run build` because both
        // are explicit project config and the Tauri one is more confident.
        #expect(recipe.build?.commandLine
            == "npm run build && cargo build --release --manifest-path src-tauri/Cargo.toml")
        #expect(recipe.provenanceByField[.build] == .explicitProjectConfig)
        // Two detectors DISAGREED on the build command, so the merged confidence
        // is penalized below the winner's own 0.95 to surface the conflict.
        let buildConfidence = try #require(recipe.confidenceByField[.build])
        #expect(buildConfidence < 0.95)

        // run: `cargo tauri dev` (the real dev flow) wins the run slot.
        #expect(recipe.run?.commandLine == "cargo tauri dev")
        #expect(recipe.provenanceByField[.run] == .explicitProjectConfig)

        // package: only the Tauri detector produces a relaunchable macOS artifact
        // command, so it is uncontested.
        #expect(recipe.package?.commandLine == "cargo tauri build")
        #expect(recipe.provenanceByField[.package] == .explicitProjectConfig)

        // install: only the Node detector has an opinion (from the lockfile), so
        // it is uncontested and keeps its full lockfile-declared confidence.
        #expect(recipe.install?.commandLine == "npm install")
        #expect(recipe.provenanceByField[.install] == .explicitProjectConfig)
        #expect(recipe.confidenceByField[.install] == 0.9)

        // The ecosystem tag is chosen from the strongest headline signal — the
        // Tauri build — so the recipe is labeled by the app's real container.
        #expect(recipe.ecosystemIdentifier == "rust/tauri")

        // A Tauri desktop app has no server component or scale machinery.
        #expect(recipe.runtimeShape == .pureLocalApp)
    }

    // MARK: - Next.js: buildable, and classified as a single-instance service

    @Test func nextAppIsBuildableAndClassifiedAsLocalSingleInstanceService() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "package.json": #"""
            {
              "scripts": { "build": "next build", "start": "next start" },
              "dependencies": { "next": "14.0.0" }
            }
            """#,
            "package-lock.json": "",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        #expect(RepoRecipeService.hasBuildableRecipe(repoRootPath: repoRootPath))

        let recipe = RepoRecipeService.deriveRecipe(repoRootPath: repoRootPath)

        // Authored scripts, npm from the lockfile, all uncontested.
        #expect(recipe.install?.commandLine == "npm install")
        #expect(recipe.build?.commandLine == "npm run build")
        #expect(recipe.provenanceByField[.build] == .explicitProjectConfig)
        #expect(recipe.confidenceByField[.build] == 0.9)
        #expect(recipe.run?.commandLine == "npm run start")

        #expect(recipe.ecosystemIdentifier == "node/next")
        // Next binds a port (a server) but there is no scale machinery here.
        #expect(recipe.runtimeShape == .localSingleInstanceService)
    }

    // MARK: - Xcode: buildable from the scheme placeholder

    @Test func xcodeProjectIsBuildableFromTheSchemePlaceholder() throws {
        // The .xcodeproj is a directory bundle; writing a file inside it creates
        // that directory, which is all the detector inspects (it never reads in).
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "App.xcodeproj/project.pbxproj": "// minimal pbxproj\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        // A Swift/Xcode app used to be REFUSED (no hardcoded build command for
        // `swiftMacOS`); it is now buildable via the derived scheme-placeholder
        // command, resolved for real at Tier 1 by `xcodebuild -list`.
        #expect(RepoRecipeService.hasBuildableRecipe(repoRootPath: repoRootPath))

        let recipe = RepoRecipeService.deriveRecipe(repoRootPath: repoRootPath)

        #expect(recipe.build?.commandLine == "xcodebuild -scheme <scheme> build")
        #expect(recipe.provenanceByField[.build] == .genericEcosystemDefault)
        #expect(recipe.test?.commandLine == "xcodebuild test")
        #expect(recipe.ecosystemIdentifier == "swift/xcode")
        // A native macOS app: no server, no machinery.
        #expect(recipe.runtimeShape == .pureLocalApp)
    }

    // MARK: - A bare, unrecognized repo is NOT buildable

    @Test func bareUnrecognizedRepoHasNoBuildableRecipe() throws {
        // Nothing but a README — no detector matches, so no field resolves. This
        // is the case that used to hard-refuse; now it yields an empty recipe
        // that routes to the clarification path (plan §7) rather than a crash or
        // a fabricated command.
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "README.md": "# just some docs\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        #expect(RepoRecipeService.hasBuildableRecipe(repoRootPath: repoRootPath) == false)

        let recipe = RepoRecipeService.deriveRecipe(repoRootPath: repoRootPath)
        #expect(recipe.build == nil)
        #expect(recipe.install == nil)
        #expect(recipe.test == nil)
        #expect(recipe.run == nil)
        #expect(recipe.package == nil)
        // No signal resolved the ecosystem — never a fabricated tag.
        #expect(recipe.ecosystemIdentifier == "unknown")
    }

    // MARK: - Precedence: a Makefile `build` target beats a package.json default

    @Test func makefileTargetBeatsPackageJsonFrameworkDefaultForTheBuildField() throws {
        // A polyglot repo: package.json declares Next (so the Node detector
        // offers a FRAMEWORK-DEFAULT `next build`, since no build script is
        // authored) AND a hand-written Makefile declares an explicit `build`
        // target. The Makefile target is author-declared intent (explicitProject-
        // Config), so it OUTRANKS the framework default and wins the build field.
        let repoRootPath = try Self.makeFixtureRepo(files: [
            // Next dependency but NO scripts → build comes from the framework
            // registry, not an authored script.
            "package.json": #"""
            { "dependencies": { "next": "14.0.0" } }
            """#,
            // Recipe bodies are tab-indented; the target lines sit at column 0.
            "Makefile": "build:\n\tnext build\n\ntest:\n\techo running tests\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let recipe = RepoRecipeService.deriveRecipe(repoRootPath: repoRootPath)

        // The Makefile target wins the build field on provenance precedence.
        #expect(recipe.build?.commandLine == "make build")
        #expect(recipe.provenanceByField[.build] == .explicitProjectConfig)

        // The winning command disagreed with the Node framework default, so the
        // merged confidence is penalized to the conflict rung (0.8 × 0.5).
        #expect(recipe.confidenceByField[.build] == 0.4)

        // Sanity: the Node default really was a lower-trust competitor.
        #expect(RepoRecipeNodeWebDetector().detect(repoRootPath: repoRootPath)?
            .provenanceByField[.build] == .frameworkRegistryDefault)

        // Still buildable, of course.
        #expect(recipe.hasABuildableRecipe)
    }

    // MARK: - CI mining: a workflow run: step outranks a guessed generic default

    @Test func ciWorkflowRunStepsOutrankGenericDefaultsAndAConflictLowersConfidence() throws {
        // A Go module: the Go detector derives its build/test from Go's uniform
        // ecosystem CONVENTION (genericEcosystemDefault). A CI workflow's `run:`
        // steps are human-authored AND CI-verified, so they outrank those
        // guessed defaults (ciWorkflowStep sits above genericEcosystemDefault).
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "go.mod": "module example.com/app\n\ngo 1.21\n",
            ".github/workflows/ci.yml": #"""
            name: CI
            on: [push]
            jobs:
              build:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
                  - run: go build ./...
                  - run: go test -race ./...
            """#,
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let recipe = RepoRecipeService.deriveRecipe(repoRootPath: repoRootPath)

        // build: the CI step and the Go default name the SAME command, so CI wins
        // on precedence but there is no conflict — confidence stays at the CI rung.
        #expect(recipe.build?.commandLine == "go build ./...")
        #expect(recipe.provenanceByField[.build] == .ciWorkflowStep)
        #expect(recipe.confidenceByField[.build] == 0.8)

        // test: the CI step (`go test -race ./...`) DISAGREES with the Go default
        // (`go test ./...`), so CI still wins on precedence but the merged
        // confidence is penalized to surface the disagreement.
        #expect(recipe.test?.commandLine == "go test -race ./...")
        #expect(recipe.provenanceByField[.test] == .ciWorkflowStep)
        #expect(recipe.confidenceByField[.test] == 0.4)

        #expect(recipe.ecosystemIdentifier == "go/modules")
        #expect(recipe.runtimeShape == .pureLocalApp)
        #expect(recipe.hasABuildableRecipe)
    }

    // MARK: - Precedence: an authored manifest script outranks a CI step

    @Test func authoredManifestScriptOutranksACIWorkflowStep() throws {
        // Both a package.json build script (explicitProjectConfig) and a CI
        // `run:` build step (ciWorkflowStep) exist. The ratified precedence puts
        // an author-declared manifest script ABOVE a CI step, so the manifest
        // script wins even though the CI step is present.
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "package.json": #"""
            {
              "scripts": { "build": "vite build" },
              "devDependencies": { "vite": "5.0.0" }
            }
            """#,
            "package-lock.json": "",
            ".github/workflows/ci.yml": #"""
            name: CI
            on: [push]
            jobs:
              build:
                steps:
                  - run: npm run build --if-present
            """#,
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let recipe = RepoRecipeService.deriveRecipe(repoRootPath: repoRootPath)

        // The authored script wins the build field.
        #expect(recipe.build?.commandLine == "npm run build")
        #expect(recipe.provenanceByField[.build] == .explicitProjectConfig)
        // The CI step proposed a different command, so the merge marks the
        // ambiguity by lowering confidence below the authored script's own 0.9.
        let buildConfidence = try #require(recipe.confidenceByField[.build])
        #expect(buildConfidence < 0.9)
    }

    // MARK: - CI mining: block-scalar (`run: |`) steps are parsed line by line

    @Test func ciWorkflowBlockScalarRunStepsAreMinedLineByLine() throws {
        // A multi-command block scalar must be split into its individual commands
        // so each is classified on its own — the parser has to recognize `run: |`
        // and gather the more-indented continuation lines beneath it.
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "go.mod": "module example.com/app\n\ngo 1.21\n",
            ".github/workflows/ci.yml": #"""
            name: CI
            on: [push]
            jobs:
              build:
                steps:
                  - run: |
                      go build ./...
                      go test ./...
            """#,
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let recipe = RepoRecipeService.deriveRecipe(repoRootPath: repoRootPath)

        // Both block-scalar lines were mined and classified; each names the same
        // command the Go default would, so CI wins on precedence with no conflict.
        #expect(recipe.build?.commandLine == "go build ./...")
        #expect(recipe.provenanceByField[.build] == .ciWorkflowStep)
        #expect(recipe.test?.commandLine == "go test ./...")
        #expect(recipe.provenanceByField[.test] == .ciWorkflowStep)
    }
}

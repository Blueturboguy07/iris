//
//  RepoRecipeNodeWebDetectorTests.swift
//  leanring-buddyTests
//
//  Fixture-driven unit tests for the Node/JS-web recipe registry row
//  (plan §10.1). Each test builds a tiny real repo in a temp directory, runs
//  the detector's pure static inspection over it, and asserts the derived
//  {install,build,test,run,package} commands, the per-field CONFIDENCE, the
//  per-field PROVENANCE, and the §8 runtime-shape vote.
//
//  The corpus deliberately covers the load-bearing edge cases the plan calls
//  out: package-manager lockfile precedence (bun > pnpm > yarn > npm), the
//  framework registry filling gaps the authored scripts don't cover, the CRA /
//  `npm init` placeholder test rejected as "no suite", a NEGATIVE case (a
//  non-Node repo yields no finding), and a CONFLICT case (two lockfiles lower
//  build + install confidence rather than silently committing to one manager).
//  Pure logic + filesystem — no processes, no network, nothing is ever executed.
//

import Foundation
import Testing
@testable import Iris

@Suite struct RepoRecipeNodeWebDetectorTests {

    // MARK: - Fixture helper

    /// Materialize a throwaway repo: write every (repo-relative path → contents)
    /// pair, creating intermediate directories so a fixture can place nested
    /// files (e.g. "k8s/deployment.yaml"), and return the repo root path. The
    /// caller removes it via `removeFixtureRepo`.
    static func makeFixtureRepo(files: [String: String]) throws -> String {
        let repoRootPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-node-detector-\(UUID().uuidString)")
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

    // MARK: - Next.js with a full set of authored scripts + a pnpm lockfile

    @Test func nextAppWithAuthoredScriptsAndPnpmLockResolvesEveryFieldFromProjectConfig() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "package.json": #"""
            {
              "scripts": {
                "build": "next build",
                "test": "vitest run",
                "start": "next start",
                "dev": "next dev"
              },
              "dependencies": { "next": "14.0.0", "react": "18.2.0" }
            }
            """#,
            "pnpm-lock.yaml": "",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let finding = RepoRecipeNodeWebDetector().detect(repoRootPath: repoRootPath)
        let unwrappedFinding = try #require(finding)

        #expect(unwrappedFinding.matched)
        #expect(unwrappedFinding.ecosystemIdentifier == "node/next")

        // install comes from the pnpm lockfile — an explicit, author-committed
        // signal — so it is high-confidence explicitProjectConfig.
        #expect(unwrappedFinding.commandsByField[.install]?.commandLine == "pnpm install")
        #expect(unwrappedFinding.provenanceByField[.install] == .explicitProjectConfig)
        #expect(unwrappedFinding.confidenceByField[.install] == 0.9)

        // build/test/run all come from authored scripts, PM-prefixed.
        #expect(unwrappedFinding.commandsByField[.build]?.commandLine == "pnpm run build")
        #expect(unwrappedFinding.provenanceByField[.build] == .explicitProjectConfig)
        #expect(unwrappedFinding.confidenceByField[.build] == 0.9)

        #expect(unwrappedFinding.commandsByField[.test]?.commandLine == "pnpm run test")
        #expect(unwrappedFinding.provenanceByField[.test] == .explicitProjectConfig)
        #expect(unwrappedFinding.confidenceByField[.test] == 0.9)

        // Production `start` wins over `dev` for the single run slot.
        #expect(unwrappedFinding.commandsByField[.run]?.commandLine == "pnpm run start")
        #expect(unwrappedFinding.provenanceByField[.run] == .explicitProjectConfig)

        // A Next.js web app has no relaunchable macOS artifact.
        #expect(unwrappedFinding.commandsByField[.package] == nil)

        // Next binds a port (a server) but there is no scale machinery here.
        #expect(unwrappedFinding.runtimeShapeContribution == .localSingleInstanceService)
    }

    // MARK: - Next.js with NO scripts falls back to the framework registry

    @Test func nextAppWithoutScriptsFallsBackToFrameworkRegistryDefaults() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            // No "scripts" section at all, and no lockfile.
            "package.json": #"""
            { "dependencies": { "next": "14.0.0" } }
            """#,
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let unwrappedFinding = try #require(
            RepoRecipeNodeWebDetector().detect(repoRootPath: repoRootPath)
        )

        #expect(unwrappedFinding.ecosystemIdentifier == "node/next")

        // No lockfile → npm by bare convention → genericEcosystemDefault, lower
        // confidence than a lockfile-declared install.
        #expect(unwrappedFinding.commandsByField[.install]?.commandLine == "npm install")
        #expect(unwrappedFinding.provenanceByField[.install] == .genericEcosystemDefault)
        #expect(unwrappedFinding.confidenceByField[.install] == 0.5)

        // build/run are the framework registry's bare templates.
        #expect(unwrappedFinding.commandsByField[.build]?.commandLine == "next build")
        #expect(unwrappedFinding.provenanceByField[.build] == .frameworkRegistryDefault)
        #expect(unwrappedFinding.confidenceByField[.build] == 0.6)

        #expect(unwrappedFinding.commandsByField[.run]?.commandLine == "next start")
        #expect(unwrappedFinding.provenanceByField[.run] == .frameworkRegistryDefault)
        #expect(unwrappedFinding.confidenceByField[.run] == 0.6)

        // No test script and the registry has no test default → honest skip.
        #expect(unwrappedFinding.commandsByField[.test] == nil)
        #expect(unwrappedFinding.provenanceByField[.test] == nil)
    }

    // MARK: - Vite with a yarn lockfile

    @Test func viteAppUsesFrameworkDefaultsAndYarnInstallAndIsPureLocal() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "package.json": #"""
            { "devDependencies": { "vite": "5.0.0" } }
            """#,
            "yarn.lock": "",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let unwrappedFinding = try #require(
            RepoRecipeNodeWebDetector().detect(repoRootPath: repoRootPath)
        )

        #expect(unwrappedFinding.ecosystemIdentifier == "node/vite")

        #expect(unwrappedFinding.commandsByField[.install]?.commandLine == "yarn install")
        #expect(unwrappedFinding.provenanceByField[.install] == .explicitProjectConfig)
        #expect(unwrappedFinding.confidenceByField[.install] == 0.9)

        #expect(unwrappedFinding.commandsByField[.build]?.commandLine == "vite build")
        #expect(unwrappedFinding.provenanceByField[.build] == .frameworkRegistryDefault)

        #expect(unwrappedFinding.commandsByField[.run]?.commandLine == "vite")
        #expect(unwrappedFinding.provenanceByField[.run] == .frameworkRegistryDefault)

        // Vite is a bundler, not a server framework → pure local.
        #expect(unwrappedFinding.runtimeShapeContribution == .pureLocalApp)
        #expect(unwrappedFinding.commandsByField[.package] == nil)
    }

    // MARK: - Electron: authored build script + framework run/package + bun lock

    @Test func electronAppKeepsAuthoredBuildAndGetsFrameworkRunAndPackage() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            // A build script exists (authored wins) but NO start/dev script, so
            // the run slot must come from the electron framework default.
            "package.json": #"""
            {
              "scripts": { "build": "tsc" },
              "devDependencies": { "electron": "30.0.0", "electron-builder": "24.0.0" }
            }
            """#,
            "bun.lockb": "",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let unwrappedFinding = try #require(
            RepoRecipeNodeWebDetector().detect(repoRootPath: repoRootPath)
        )

        #expect(unwrappedFinding.ecosystemIdentifier == "node/electron")

        // bun wins the (single) lockfile.
        #expect(unwrappedFinding.commandsByField[.install]?.commandLine == "bun install")
        #expect(unwrappedFinding.provenanceByField[.install] == .explicitProjectConfig)

        // Authored build script wins over any framework default.
        #expect(unwrappedFinding.commandsByField[.build]?.commandLine == "bun run build")
        #expect(unwrappedFinding.provenanceByField[.build] == .explicitProjectConfig)
        #expect(unwrappedFinding.confidenceByField[.build] == 0.9)

        // No start/dev script → the electron run + package defaults fill in.
        #expect(unwrappedFinding.commandsByField[.run]?.commandLine == "electron .")
        #expect(unwrappedFinding.provenanceByField[.run] == .frameworkRegistryDefault)

        #expect(unwrappedFinding.commandsByField[.package]?.commandLine == "electron-builder")
        #expect(unwrappedFinding.provenanceByField[.package] == .frameworkRegistryDefault)

        // A desktop shell with no server dependency is pure local.
        #expect(unwrappedFinding.runtimeShapeContribution == .pureLocalApp)
    }

    // MARK: - The CRA / `npm init` placeholder test is rejected as "no suite"

    @Test func craPlaceholderTestScriptIsRejectedAsNoSuite() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            // The exact `npm init` / CRA placeholder that only ever fails.
            "package.json": #"""
            {
              "scripts": {
                "build": "react-scripts build",
                "test": "echo \"Error: no test specified\" && exit 1"
              },
              "dependencies": { "react": "18.2.0" }
            }
            """#,
            "package-lock.json": "",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let unwrappedFinding = try #require(
            RepoRecipeNodeWebDetector().detect(repoRootPath: repoRootPath)
        )

        // The placeholder must NOT become a test command — that would fail the
        // build for the wrong reason and mask "there is no real suite".
        #expect(unwrappedFinding.commandsByField[.test] == nil)
        #expect(unwrappedFinding.provenanceByField[.test] == nil)

        // The authored build script is still resolved, npm from the lockfile.
        #expect(unwrappedFinding.commandsByField[.build]?.commandLine == "npm run build")
        #expect(unwrappedFinding.provenanceByField[.build] == .explicitProjectConfig)
        #expect(unwrappedFinding.commandsByField[.install]?.commandLine == "npm install")
        #expect(unwrappedFinding.provenanceByField[.install] == .explicitProjectConfig)

        // No recognized framework, no server framework → base tag + pure local.
        #expect(unwrappedFinding.ecosystemIdentifier == "node/web")
        #expect(unwrappedFinding.runtimeShapeContribution == .pureLocalApp)
    }

    // MARK: - NEGATIVE case: a non-Node repo yields no finding at all

    @Test func nonNodeRepositoryReturnsNilBecauseThereIsNoPackageJSON() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "Cargo.toml": "[package]\nname = \"widget\"\nversion = \"0.1.0\"\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        // No package.json means this detector genuinely has nothing to say —
        // it returns nil rather than a matched:false finding.
        let finding = RepoRecipeNodeWebDetector().detect(repoRootPath: repoRootPath)
        #expect(finding == nil)
    }

    // MARK: - CONFLICT case: two lockfiles lower build + install confidence

    @Test func multipleLockfilesPickHighestPrecedenceAndHalveBuildAndInstallConfidence() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "package.json": #"""
            {
              "scripts": { "build": "next build" },
              "dependencies": { "next": "14.0.0" }
            }
            """#,
            // Two committed lockfiles — the package-manager choice is ambiguous.
            "pnpm-lock.yaml": "",
            "package-lock.json": "",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let unwrappedFinding = try #require(
            RepoRecipeNodeWebDetector().detect(repoRootPath: repoRootPath)
        )

        // Precedence still resolves a manager (pnpm outranks npm) so the recipe
        // is usable, but the confidence is halved to surface the ambiguity to
        // the clarification layer instead of silently committing.
        #expect(unwrappedFinding.commandsByField[.install]?.commandLine == "pnpm install")
        #expect(unwrappedFinding.provenanceByField[.install] == .explicitProjectConfig)
        #expect(unwrappedFinding.confidenceByField[.install] == 0.45)

        #expect(unwrappedFinding.commandsByField[.build]?.commandLine == "pnpm run build")
        #expect(unwrappedFinding.confidenceByField[.build] == 0.45)

        // Sanity: the penalized values really are below the single-lockfile bar.
        let installConfidence = try #require(unwrappedFinding.confidenceByField[.install])
        let buildConfidence = try #require(unwrappedFinding.confidenceByField[.build])
        #expect(installConfidence < 0.9)
        #expect(buildConfidence < 0.9)
    }

    // MARK: - Runtime shape: a server + scale machinery is built-for-scale

    @Test func serverFrameworkWithDockerAndComposeIsBuiltForScale() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "package.json": #"""
            {
              "scripts": { "build": "next build", "start": "next start" },
              "dependencies": { "next": "14.0.0" }
            }
            """#,
            "Dockerfile": "FROM node:20\nEXPOSE 3000\n",
            "docker-compose.yml": "services:\n  web:\n    build: .\n  db:\n    image: postgres\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let unwrappedFinding = try #require(
            RepoRecipeNodeWebDetector().detect(repoRootPath: repoRootPath)
        )
        #expect(unwrappedFinding.runtimeShapeContribution == .builtForScale)
    }

    // MARK: - Runtime shape: an Express server with no machinery is single-instance

    @Test func expressServerWithNoScaleMachineryIsLocalSingleInstance() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "package.json": #"""
            {
              "scripts": { "start": "node server.js" },
              "dependencies": { "express": "4.18.0" }
            }
            """#,
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let unwrappedFinding = try #require(
            RepoRecipeNodeWebDetector().detect(repoRootPath: repoRootPath)
        )

        #expect(unwrappedFinding.runtimeShapeContribution == .localSingleInstanceService)
        // An interpreted server with no build script and no registry framework
        // legitimately has no build command — install-only is still buildable.
        #expect(unwrappedFinding.commandsByField[.build] == nil)
        #expect(unwrappedFinding.commandsByField[.run]?.commandLine == "npm run start")
        #expect(unwrappedFinding.ecosystemIdentifier == "node/web")
    }

    // MARK: - Runtime shape guard: a static frontend + Dockerfile is NOT scaled

    @Test func staticFrontendWithADockerfileIsNotMisclassifiedAsScaled() throws {
        // The documented false-positive to avoid: machinery alone (a Dockerfile)
        // must NOT make a server-less static frontend look "scaled". No server
        // component ⇒ pure local, regardless of machinery.
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "package.json": #"""
            { "devDependencies": { "vite": "5.0.0" } }
            """#,
            "Dockerfile": "FROM nginx\nCOPY dist /usr/share/nginx/html\n",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let unwrappedFinding = try #require(
            RepoRecipeNodeWebDetector().detect(repoRootPath: repoRootPath)
        )
        #expect(unwrappedFinding.runtimeShapeContribution == .pureLocalApp)
    }
}

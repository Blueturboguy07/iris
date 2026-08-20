//
//  RepoRecipeRustTauriDetectorTests.swift
//  leanring-buddyTests
//
//  Fixture-driven unit tests for the Rust / Tauri ecosystem detector (plan
//  §10.1). Each test writes a tiny real repo into a temp directory, runs the
//  detector statically over it, and asserts the resolved commands, the runtime
//  shape vote, and the per-field provenance — plus a negative case (no Rust
//  signal at all) and a conflict case (ambiguous `cargo run` target).
//
//  Everything here is pure static inspection: no network, no execution of the
//  fixture repo's own code, consistent with the detector's own invariants.
//

import Testing
import Foundation
@testable import Iris

@Suite struct RepoRecipeRustTauriDetectorTests {

    private let detector = RepoRecipeRustTauriDetector()

    // MARK: - Tauri branch (tauri.conf.json wins)

    @Test func aTauriConfigUnderSrcTauriResolvesTheComposedBuildAndDevAndPackage() throws {
        let repoRootPath = Self.makeTemporaryRepository()
        defer { Self.removeRepository(repoRootPath) }

        // A Tauri v1-shaped config declaring both frontend hooks.
        Self.writeFile(
            "src-tauri/tauri.conf.json",
            contents: """
            {
              "build": {
                "beforeBuildCommand": "npm run build",
                "beforeDevCommand": "npm run dev",
                "distDir": "../dist",
                "devPath": "http://localhost:3000"
              }
            }
            """,
            intoRepo: repoRootPath
        )
        Self.writeFile("src-tauri/Cargo.toml", contents: "[package]\nname = \"app\"\n", intoRepo: repoRootPath)

        let finding = try #require(detector.detect(repoRootPath: repoRootPath))
        #expect(finding.matched)
        #expect(finding.ecosystemIdentifier == "rust/tauri")
        #expect(finding.runtimeShapeContribution == .pureLocalApp)

        // BUILD composes the declared frontend hook FIRST, then the release
        // compile pointed at the crate under src-tauri/.
        #expect(finding.commandsByField[.build]?.commandLine
            == "npm run build && cargo build --release --manifest-path src-tauri/Cargo.toml")
        #expect(finding.commandsByField[.build]?.workingSubdirectory == nil)
        #expect(finding.confidenceByField[.build] == 0.95)
        #expect(finding.provenanceByField[.build] == .explicitProjectConfig)

        // RUN (dev) is the CLI that manages the frontend dev server itself.
        #expect(finding.commandsByField[.run]?.commandLine == "cargo tauri dev")
        #expect(finding.confidenceByField[.run] == 0.95)
        #expect(finding.provenanceByField[.run] == .explicitProjectConfig)

        // PACKAGE is the relaunchable-macOS-artifact command AppRelaunchService needs.
        #expect(finding.commandsByField[.package]?.commandLine == "cargo tauri build")
        #expect(finding.provenanceByField[.package] == .explicitProjectConfig)

        // The Tauri branch does not emit a cargo `test` slot.
        #expect(finding.commandsByField[.test] == nil)
    }

    @Test func aTauriConfigWithNoFrontendHooksBuildsWithCargoAloneAtLowerConfidence() throws {
        let repoRootPath = Self.makeTemporaryRepository()
        defer { Self.removeRepository(repoRootPath) }

        // An empty build section: no beforeBuildCommand, no beforeDevCommand.
        Self.writeFile(
            "src-tauri/tauri.conf.json",
            contents: "{ \"build\": {} }",
            intoRepo: repoRootPath
        )

        let finding = try #require(detector.detect(repoRootPath: repoRootPath))
        #expect(finding.ecosystemIdentifier == "rust/tauri")
        // No frontend hook to compose, so build is the bare release compile —
        // and confidence drops because we could not see how the frontend builds.
        #expect(finding.commandsByField[.build]?.commandLine
            == "cargo build --release --manifest-path src-tauri/Cargo.toml")
        #expect(finding.confidenceByField[.build] == 0.85)
        #expect(finding.confidenceByField[.run] == 0.85)
        #expect(finding.commandsByField[.run]?.commandLine == "cargo tauri dev")
    }

    @Test func aTauriV2ObjectFormBeforeBuildCommandIsUnwrappedToItsScript() throws {
        let repoRootPath = Self.makeTemporaryRepository()
        defer { Self.removeRepository(repoRootPath) }

        // Tauri v2 permits an object hook: { script, cwd, wait }.
        Self.writeFile(
            "src-tauri/tauri.conf.json",
            contents: """
            {
              "build": {
                "beforeBuildCommand": { "script": "pnpm build", "wait": true },
                "frontendDist": "../dist"
              }
            }
            """,
            intoRepo: repoRootPath
        )

        let finding = try #require(detector.detect(repoRootPath: repoRootPath))
        #expect(finding.commandsByField[.build]?.commandLine
            == "pnpm build && cargo build --release --manifest-path src-tauri/Cargo.toml")
        #expect(finding.confidenceByField[.build] == 0.95)
    }

    @Test func aRootLevelTauriConfigBuildsWithoutAManifestPath() throws {
        let repoRootPath = Self.makeTemporaryRepository()
        defer { Self.removeRepository(repoRootPath) }

        // Crate at the repo root: tauri.conf.json + Cargo.toml both at the top.
        Self.writeFile(
            "tauri.conf.json",
            contents: "{ \"build\": { \"beforeBuildCommand\": \"npm run build\" } }",
            intoRepo: repoRootPath
        )
        Self.writeFile("Cargo.toml", contents: "[package]\nname = \"app\"\n", intoRepo: repoRootPath)

        let finding = try #require(detector.detect(repoRootPath: repoRootPath))
        #expect(finding.ecosystemIdentifier == "rust/tauri")
        // No src-tauri/ nesting, so no --manifest-path is needed.
        #expect(finding.commandsByField[.build]?.commandLine
            == "npm run build && cargo build --release")
    }

    @Test func aTauriConfigWinsOverThePlainCargoRecipeWhenBothArePresent() throws {
        let repoRootPath = Self.makeTemporaryRepository()
        defer { Self.removeRepository(repoRootPath) }

        // The normal Tauri layout: a root workspace Cargo.toml AND a Tauri config.
        // tauri.conf.json is the higher-confidence signal, so the Tauri branch
        // must win — no cargo `test`/`run` recipe leaks through.
        Self.writeFile("Cargo.toml", contents: "[workspace]\nmembers = [\"src-tauri\"]\n", intoRepo: repoRootPath)
        Self.writeFile(
            "src-tauri/tauri.conf.json",
            contents: "{ \"build\": { \"beforeBuildCommand\": \"npm run build\" } }",
            intoRepo: repoRootPath
        )
        Self.writeFile("src-tauri/Cargo.toml", contents: "[package]\nname = \"app\"\n", intoRepo: repoRootPath)

        let finding = try #require(detector.detect(repoRootPath: repoRootPath))
        #expect(finding.ecosystemIdentifier == "rust/tauri")
        #expect(finding.runtimeShapeContribution == .pureLocalApp)
        #expect(finding.commandsByField[.package]?.commandLine == "cargo tauri build")
        // Plain-cargo-only fields must NOT appear on the Tauri finding.
        #expect(finding.commandsByField[.test] == nil)
        #expect(finding.commandsByField[.build]?.commandLine.contains("cargo build --release") == true)
    }

    // MARK: - Plain cargo branch

    @Test func aCargoBinaryCrateResolvesBuildTestAndRun() throws {
        let repoRootPath = Self.makeTemporaryRepository()
        defer { Self.removeRepository(repoRootPath) }

        Self.writeFile("Cargo.toml", contents: "[package]\nname = \"cli\"\nversion = \"0.1.0\"\n", intoRepo: repoRootPath)
        Self.writeFile("src/main.rs", contents: "fn main() {}\n", intoRepo: repoRootPath)

        let finding = try #require(detector.detect(repoRootPath: repoRootPath))
        #expect(finding.ecosystemIdentifier == "rust/cargo")
        #expect(finding.commandsByField[.build]?.commandLine == "cargo build")
        #expect(finding.commandsByField[.test]?.commandLine == "cargo test")
        #expect(finding.commandsByField[.run]?.commandLine == "cargo run")
        #expect(finding.confidenceByField[.run] == 0.9)
        #expect(finding.provenanceByField[.build] == .explicitProjectConfig)
        #expect(finding.provenanceByField[.test] == .explicitProjectConfig)
        #expect(finding.provenanceByField[.run] == .explicitProjectConfig)
        // A bare cargo crate votes no runtime shape — it can't tell CLI from server.
        #expect(finding.runtimeShapeContribution == .unknown)
    }

    @Test func aCargoLibraryCrateWithNoBinaryHasNoRunCommand() throws {
        let repoRootPath = Self.makeTemporaryRepository()
        defer { Self.removeRepository(repoRootPath) }

        // Library-only crate: src/lib.rs, no main.rs, no [[bin]].
        Self.writeFile("Cargo.toml", contents: "[package]\nname = \"libonly\"\n", intoRepo: repoRootPath)
        Self.writeFile("src/lib.rs", contents: "pub fn add(a: i32, b: i32) -> i32 { a + b }\n", intoRepo: repoRootPath)

        let finding = try #require(detector.detect(repoRootPath: repoRootPath))
        #expect(finding.ecosystemIdentifier == "rust/cargo")
        #expect(finding.commandsByField[.build]?.commandLine == "cargo build")
        #expect(finding.commandsByField[.test]?.commandLine == "cargo test")
        // No runnable binary → no run command, never a fabricated guess.
        #expect(finding.commandsByField[.run] == nil)
        #expect(finding.confidenceByField[.run] == nil)
    }

    @Test func anExplicitBinTableEnablesRunEvenWithoutMainRs() throws {
        let repoRootPath = Self.makeTemporaryRepository()
        defer { Self.removeRepository(repoRootPath) }

        Self.writeFile(
            "Cargo.toml",
            contents: """
            [package]
            name = "tool"

            [[bin]]
            name = "tool"
            path = "src/tool.rs"
            """,
            intoRepo: repoRootPath
        )

        let finding = try #require(detector.detect(repoRootPath: repoRootPath))
        #expect(finding.commandsByField[.run]?.commandLine == "cargo run")
        // A single declared binary is unambiguous.
        #expect(finding.confidenceByField[.run] == 0.9)
    }

    // MARK: - Conflict case (ambiguous cargo run target)

    @Test func multipleBinTargetsWithNoDefaultRunLowerTheRunConfidence() throws {
        let repoRootPath = Self.makeTemporaryRepository()
        defer { Self.removeRepository(repoRootPath) }

        // Two explicit binaries and no `default-run`: `cargo run` cannot pick one.
        Self.writeFile(
            "Cargo.toml",
            contents: """
            [package]
            name = "multi"

            [[bin]]
            name = "server"
            path = "src/server.rs"

            [[bin]]
            name = "worker"   # background worker
            path = "src/worker.rs"
            """,
            intoRepo: repoRootPath
        )

        let finding = try #require(detector.detect(repoRootPath: repoRootPath))
        // Build/test stay confident; only run is ambiguous.
        #expect(finding.confidenceByField[.build] == 0.9)
        // Run is still offered, but at low confidence so a clarification is raised
        // instead of a silent wrong pick (plan §7).
        #expect(finding.commandsByField[.run]?.commandLine == "cargo run")
        #expect(finding.confidenceByField[.run] == 0.4)
    }

    @Test func aDefaultRunKeyResolvesTheMultipleBinaryAmbiguity() throws {
        let repoRootPath = Self.makeTemporaryRepository()
        defer { Self.removeRepository(repoRootPath) }

        // Same two binaries, but `default-run` disambiguates — confidence recovers.
        Self.writeFile(
            "Cargo.toml",
            contents: """
            [package]
            name = "multi"
            default-run = "server"

            [[bin]]
            name = "server"
            path = "src/server.rs"

            [[bin]]
            name = "worker"
            path = "src/worker.rs"
            """,
            intoRepo: repoRootPath
        )

        let finding = try #require(detector.detect(repoRootPath: repoRootPath))
        #expect(finding.commandsByField[.run]?.commandLine == "cargo run")
        #expect(finding.confidenceByField[.run] == 0.9)
    }

    // MARK: - Negative case (no Rust/Tauri signal)

    @Test func aRepoWithNoCargoOrTauriSignalIsNotDetected() {
        let repoRootPath = Self.makeTemporaryRepository()
        defer { Self.removeRepository(repoRootPath) }

        // A Node-only repo: no Cargo.toml, no tauri.conf.json.
        Self.writeFile("package.json", contents: "{ \"name\": \"web\", \"scripts\": { \"build\": \"next build\" } }", intoRepo: repoRootPath)
        Self.writeFile("next.config.js", contents: "module.exports = {}\n", intoRepo: repoRootPath)

        // The detector must stay silent (nil), not claim a match.
        #expect(detector.detect(repoRootPath: repoRootPath) == nil)
    }

    @Test func anEmptyRepoIsNotDetected() {
        let repoRootPath = Self.makeTemporaryRepository()
        defer { Self.removeRepository(repoRootPath) }
        #expect(detector.detect(repoRootPath: repoRootPath) == nil)
    }

    // MARK: - Fixture helpers

    private static func makeTemporaryRepository() -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-rust-tauri-detector-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private static func removeRepository(_ repoRootPath: String) {
        try? FileManager.default.removeItem(atPath: repoRootPath)
    }

    /// Write `contents` to a repo-relative path, creating intermediate
    /// directories so a fixture can seed nested files like src-tauri/Cargo.toml.
    private static func writeFile(_ relativePath: String, contents: String, intoRepo repoRootPath: String) {
        let absolutePath = (repoRootPath as NSString).appendingPathComponent(relativePath)
        let directoryPath = (absolutePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        try? contents.write(toFile: absolutePath, atomically: true, encoding: .utf8)
    }
}

//
//  RepoRecipeRustTauriDetector.swift
//  leanring-buddy
//
//  One row of the Feature Engine's data-driven ecosystem registry (plan §4):
//  the Rust / Tauri detector. It statically inspects a clone and reports how to
//  build / test / run / package it, WITHOUT ever executing the repo's own code
//  and WITHOUT touching the network. Every command it emits is lifted from — or
//  keyed on — the repo's own declarative config (`Cargo.toml`,
//  `src-tauri/tauri.conf.json`), which is precisely what keeps the later
//  un-jailed build code-adjudicated rather than model-authored (plan §5).
//
//  Precedence inside this one detector mirrors the global cascade (plan §4): a
//  real Tauri config (`tauri.conf.json`) is the highest-confidence signal and,
//  when present, decides the whole recipe — a Tauri app is a desktop app, so its
//  runtime shape is unambiguously pure-local. Absent a Tauri config, a bare
//  `Cargo.toml` yields the ordinary cargo build/test/run recipe, with `cargo run`
//  offered only when the crate actually declares a runnable binary.
//
//  Pure Foundation: no network, no SwiftUI, and nothing here executes anything
//  from the repo. All file access goes through `RepoRecipeFiles` — the audited,
//  size-capped, repo-confined read surface — so a hostile manifest path can
//  never walk this detector out of the clone.
//

import Foundation

nonisolated struct RepoRecipeRustTauriDetector: EcosystemDetector {

    // MARK: - Signal-file locations

    /// The canonical Tauri config location (Tauri keeps its Rust crate + config
    /// under `src-tauri/`). We also accept a root-level `tauri.conf.json`, in
    /// precedence order, because a few setups keep the crate at the repo root.
    private static let tauriConfigRelativePathsInPrecedenceOrder = [
        "src-tauri/tauri.conf.json",
        "tauri.conf.json",
    ]

    /// The cargo manifest at the repo root — the signal for the plain-cargo
    /// branch and the fallback build-manifest location for a root-level Tauri app.
    private static let cargoManifestRelativePath = "Cargo.toml"

    // MARK: - EcosystemDetector

    /// The protocol requires a single stable tag. This detector can win as either
    /// "rust/tauri" or "rust/cargo"; we advertise the more specific headline stack
    /// here, and the `EcosystemDetectorFinding` it returns carries the
    /// branch-accurate identifier that the merge actually copies into the recipe.
    let ecosystemIdentifier = "rust/tauri"

    func detect(repoRootPath: String) -> EcosystemDetectorFinding? {
        // Highest-confidence signal first: a real Tauri config decides everything,
        // so we never fall through to the plainer cargo recipe for a Tauri app.
        if let tauriConfigRelativePath = Self.firstPresentTauriConfigPath(repoRootPath: repoRootPath) {
            return Self.tauriFinding(
                repoRootPath: repoRootPath,
                tauriConfigRelativePath: tauriConfigRelativePath
            )
        }

        // No Tauri config — fall back to a plain cargo crate if one exists.
        if RepoRecipeFiles.fileExists(Self.cargoManifestRelativePath, underRepoRoot: repoRootPath) {
            return Self.cargoFinding(repoRootPath: repoRootPath)
        }

        // Neither signal file present: this is not a Rust/Tauri repo. Return nil
        // (rather than a matched:false finding) — the detector has nothing at all
        // to say, which is exactly what the protocol asks for in that case.
        return nil
    }

    // MARK: - Tauri branch (tauri.conf.json present — highest confidence)

    private static func firstPresentTauriConfigPath(repoRootPath: String) -> String? {
        for candidateRelativePath in tauriConfigRelativePathsInPrecedenceOrder
        where RepoRecipeFiles.fileExists(candidateRelativePath, underRepoRoot: repoRootPath) {
            return candidateRelativePath
        }
        return nil
    }

    private static func tauriFinding(
        repoRootPath: String,
        tauriConfigRelativePath: String
    ) -> EcosystemDetectorFinding {
        // The Tauri crate and its Cargo.toml live in the same directory as the
        // config, so that directory tells us where to point `cargo build`.
        let tauriDirectoryRelativePath =
            (tauriConfigRelativePath as NSString).deletingLastPathComponent

        // A crate under src-tauri/ needs an explicit --manifest-path so the whole
        // command still runs from the repo root; a crate AT the root needs none,
        // which keeps the root case clean.
        let cargoReleaseBuildCommandLine: String
        if tauriDirectoryRelativePath.isEmpty {
            cargoReleaseBuildCommandLine = "cargo build --release"
        } else {
            let cargoManifestForBuild =
                (tauriDirectoryRelativePath as NSString).appendingPathComponent("Cargo.toml")
            cargoReleaseBuildCommandLine = "cargo build --release --manifest-path \(cargoManifestForBuild)"
        }

        // Read the author-declared frontend hooks. tauri.conf.json is JSON, so it
        // parses through the safe, eval-free JSONSerialization path. A hook value
        // is usually a bare string, but Tauri v2 also allows an object form
        // ({ "script": "...", "cwd": "...", "wait": true }) — handle both.
        let parsedConfig = RepoRecipeFiles.jsonObject(
            atRelativePath: tauriConfigRelativePath,
            underRepoRoot: repoRootPath
        )
        let buildSection = parsedConfig?["build"] as? [String: Any]
        let beforeBuildCommand = frontendHookString(buildSection?["beforeBuildCommand"])
        let beforeDevCommand = frontendHookString(buildSection?["beforeDevCommand"])

        // BUILD — a release compile-check. `cargo build --release` alone would
        // compile the Rust before the frontend assets exist, so when the config
        // declares a beforeBuildCommand we run it FIRST (exactly what `tauri build`
        // does internally). Knowing the frontend hook is what raises confidence.
        let buildCommandLine: String
        let buildConfidence: Double
        if let beforeBuildCommand {
            buildCommandLine = "\(beforeBuildCommand) && \(cargoReleaseBuildCommandLine)"
            buildConfidence = 0.95
        } else {
            buildCommandLine = cargoReleaseBuildCommandLine
            buildConfidence = 0.85
        }

        // RUN (dev) — `cargo tauri dev`. We deliberately do NOT prepend
        // beforeDevCommand: `tauri dev` starts and owns the lifetime of the
        // frontend dev server ITSELF, and a dev-server command typically never
        // returns, so `beforeDevCommand && cargo tauri dev` would block before it
        // ever reached `tauri dev`. Reading beforeDevCommand still confirms this is
        // a real dev flow, which we reflect only as higher confidence.
        let runConfidence: Double = beforeDevCommand == nil ? 0.85 : 0.95

        // PACKAGE — the relaunchable macOS artifact. `cargo tauri build` locates
        // tauri.conf.json whether the crate is at the root or under src-tauri/,
        // producing target/.../bundle/macos/<Name>.app — the exact command
        // AppRelaunchService needs, now derived from config instead of a hardcoded
        // per-stack switch (plan §4: that lookup becomes a RepoRecipe consumer).
        return EcosystemDetectorFinding(
            ecosystemIdentifier: "rust/tauri",
            commandsByField: [
                .build: RepoRecipeCommand(commandLine: buildCommandLine),
                .run: RepoRecipeCommand(commandLine: "cargo tauri dev"),
                .package: RepoRecipeCommand(commandLine: "cargo tauri build"),
            ],
            confidenceByField: [
                .build: buildConfidence,
                .run: runConfidence,
                .package: 0.9,
            ],
            provenanceByField: [
                .build: .explicitProjectConfig,
                .run: .explicitProjectConfig,
                .package: .explicitProjectConfig,
            ],
            // A Tauri app is definitionally a desktop app — no server, no scale
            // machinery — so this branch votes pure-local with confidence.
            runtimeShapeContribution: .pureLocalApp,
            matched: true
        )
    }

    /// A tauri.conf.json `beforeBuildCommand` / `beforeDevCommand` is usually a
    /// bare string, but Tauri v2 also allows an object form
    /// ({ "script": "...", "cwd": "...", "wait": true }). Accept either shape and
    /// return the runnable script, trimmed; an empty or unrecognized value reads
    /// as "hook absent" so the build command falls back to the plain cargo build.
    private static func frontendHookString(_ rawValue: Any?) -> String? {
        if let commandString = rawValue as? String {
            let trimmed = commandString.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let commandObject = rawValue as? [String: Any],
           let script = commandObject["script"] as? String {
            let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    // MARK: - Plain cargo branch (Cargo.toml present, no Tauri config)

    private static func cargoFinding(repoRootPath: String) -> EcosystemDetectorFinding {
        // Cargo.toml is TOML, for which Foundation ships no parser. We only need a
        // couple of small, unambiguous declarations, so we scan the manifest TEXT
        // for them — no eval, no execution, per the Tier-0 rule.
        let manifestText =
            RepoRecipeFiles.readText(cargoManifestRelativePath, underRepoRoot: repoRootPath) ?? ""

        let hasMainEntryPoint = RepoRecipeFiles.fileExists("src/main.rs", underRepoRoot: repoRootPath)
        let explicitBinaryTargetCount = countBinaryTableHeaders(inCargoManifest: manifestText)
        let declaresDefaultRunTarget = declaresDefaultRun(inCargoManifest: manifestText)

        // src/main.rs is the crate's implicit default binary; each [[bin]] is an
        // explicit one. `cargo run` needs exactly one unambiguous target.
        let totalRunnableBinaryCount = explicitBinaryTargetCount + (hasMainEntryPoint ? 1 : 0)
        let crateHasARunnableBinary = totalRunnableBinaryCount >= 1

        // Two or more binaries with no `default-run` = `cargo run` cannot pick one
        // (it errors "could not determine which binary to run"). We still offer
        // `cargo run` but at LOW confidence, which is what routes the ambiguity to
        // a clarification question (plan §7) instead of a silent wrong guess.
        let runTargetIsAmbiguous = totalRunnableBinaryCount >= 2 && !declaresDefaultRunTarget

        // build/test are the universal cargo verbs, derived from the parsed
        // manifest (not merely a filename guess), so their provenance is the
        // author's explicit project config.
        var commandsByField: [RecipeField: RepoRecipeCommand] = [
            .build: RepoRecipeCommand(commandLine: "cargo build"),
            .test: RepoRecipeCommand(commandLine: "cargo test"),
        ]
        var confidenceByField: [RecipeField: Double] = [
            .build: 0.9,
            .test: 0.9,
        ]
        var provenanceByField: [RecipeField: RecipeSignalProvenance] = [
            .build: .explicitProjectConfig,
            .test: .explicitProjectConfig,
        ]

        // `cargo run` only when the crate actually declares something to run — a
        // library-only crate has no run command at all (never a fabricated guess).
        if crateHasARunnableBinary {
            commandsByField[.run] = RepoRecipeCommand(commandLine: "cargo run")
            confidenceByField[.run] = runTargetIsAmbiguous ? 0.4 : 0.9
            provenanceByField[.run] = .explicitProjectConfig
        }

        return EcosystemDetectorFinding(
            ecosystemIdentifier: "rust/cargo",
            commandsByField: commandsByField,
            confidenceByField: confidenceByField,
            provenanceByField: provenanceByField,
            // A bare cargo crate might be a CLI, a library, or a network service,
            // and this detector cannot tell those apart without reading source or
            // dependencies. It abstains (.unknown) and lets the two-axis
            // RuntimeShapeClassifier decide from its own signals — contrast the
            // Tauri branch, which can vote pure-local with certainty.
            runtimeShapeContribution: .unknown,
            matched: true
        )
    }

    // MARK: - Minimal, side-effect-free TOML scanning

    /// Count `[[bin]]` array-of-tables headers in a Cargo.toml via a pure text
    /// scan. A TOML table header stands alone on its line, so trimming comments
    /// and inner whitespace and comparing the whole token to "[[bin]]" is exact —
    /// and it never evaluates anything the manifest contains.
    private static func countBinaryTableHeaders(inCargoManifest manifestText: String) -> Int {
        var binaryTableHeaderCount = 0
        for rawLine in manifestText.split(whereSeparator: { $0.isNewline })
        where normalizedTomlHeader(String(rawLine)) == "[[bin]]" {
            binaryTableHeaderCount += 1
        }
        return binaryTableHeaderCount
    }

    /// Does the manifest declare a `default-run` key (which disambiguates
    /// `cargo run` when several binaries exist)? A text scan for the key at the
    /// start of a line, guarding against a longer key that merely shares the
    /// prefix (e.g. "default-run-mode").
    private static func declaresDefaultRun(inCargoManifest manifestText: String) -> Bool {
        for rawLine in manifestText.split(whereSeparator: { $0.isNewline }) {
            let strippedLine =
                stripTrailingTomlComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard strippedLine.hasPrefix("default-run") else { continue }
            let characterAfterKey = strippedLine.dropFirst("default-run".count).first
            if characterAfterKey == "=" || characterAfterKey == " " || characterAfterKey == "\t" {
                return true
            }
        }
        return false
    }

    /// Strip a trailing `#` comment and ALL whitespace from a line, yielding the
    /// bare header token. Removing inner whitespace means TOML's legal
    /// "[[ bin ]]" spelling matches "[[bin]]"; a header never contains a quoted
    /// string, so cutting at the first `#` is safe for header lines.
    private static func normalizedTomlHeader(_ line: String) -> String {
        stripTrailingTomlComment(line).filter { !$0.isWhitespace }
    }

    /// Return the portion of a line before its first `#`. Used only where a `#`
    /// cannot legitimately appear inside a value we examine (header lines, and the
    /// portion of a key line before the value), so this simple cut is safe.
    private static func stripTrailingTomlComment(_ line: String) -> String {
        if let hashIndex = line.firstIndex(of: "#") {
            return String(line[line.startIndex..<hashIndex])
        }
        return line
    }
}

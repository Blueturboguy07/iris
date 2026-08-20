//
//  RepoRecipe.swift
//  leanring-buddy
//
//  Core value types for the Feature Engine's build/run recipe derivation
//  (plan §4). A `RepoRecipe` is what replaces the coarse, catalog-declared
//  `BreakAppStack → VerificationCommands` lookup: a per-repo description of how
//  to install/build/test/run/package the clone, derived by READING the repo,
//  with per-field confidence and provenance so every command that later runs
//  un-jailed is auditable back to the declarative signal that produced it.
//
//  Everything in this file is pure Foundation — no network, no SwiftUI, and
//  nothing here ever executes a target repo's code. Detectors only inspect
//  files; command strings are built here and adjudicated/executed elsewhere
//  (behind the classifier gate and staged consent, plan §5).
//

import Foundation

// MARK: - A single derived command

/// One command a recipe would run (e.g. "npm ci", "cargo build"), plus the
/// subdirectory of the repo it must run from (monorepos, Tauri's ui/ vs
/// src-tauri/ split). Kept as a plain string + subdir rather than argv so the
/// provenance story stays simple: the string is lifted verbatim from the
/// repo's own declarative config (or a fixed registry template) and can be
/// shown to the reader exactly as it will run.
nonisolated struct RepoRecipeCommand: Sendable, Equatable {
    /// The full shell command line, exactly as it will be handed to the
    /// (un-jailed, classifier-screened) shell runner.
    let commandLine: String

    /// Repo-relative subdirectory to run in; nil means the repo root.
    let workingSubdirectory: String?

    init(commandLine: String, workingSubdirectory: String? = nil) {
        self.commandLine = commandLine
        self.workingSubdirectory = workingSubdirectory
    }
}

// MARK: - Where a command came from

/// Which class of signal produced a recipe field. Declaration order IS the
/// trust precedence (plan §4, echoed by every build-detection tool surveyed):
/// explicit project config > CI workflow step > framework-registry default >
/// generic ecosystem default > sandboxed trial > unknown. Merge logic must
/// never let a lower-trust signal overwrite a higher-trust one, and the
/// recorded provenance is what makes a Railpack-style precedence bug auditable
/// instead of silent.
nonisolated enum RecipeSignalProvenance: String, Sendable, CaseIterable {
    /// Author-declared intent parsed from the repo's own manifest
    /// (package.json scripts, tauri.conf.json beforeBuildCommand, …).
    case explicitProjectConfig

    /// A `run:` step mined from .github/workflows — human-authored AND
    /// CI-verified, the highest-value *inferred* signal.
    case ciWorkflowStep

    /// A dependency-name → command-template registry row
    /// (à la @vercel/frameworks) filled a gap the manifest didn't cover.
    case frameworkRegistryDefault

    /// A bare ecosystem convention ("a Cargo.toml exists → cargo build")
    /// with no corroborating declared script.
    case genericEcosystemDefault

    /// Confirmed only by a Tier-2 sandboxed trial run (ratified decision 2b):
    /// empirically verified, but not author-declared, so it ranks below
    /// every declarative signal.
    case sandboxedTrial

    /// Nothing resolved this field. Confidence must be 0 — never a
    /// fabricated guess (plan §4 graceful degradation).
    case unknown

    /// Lower rank = more trusted. Derived from declaration order so the
    /// precedence lives in exactly one place (the case list above) and can't
    /// drift from a hand-maintained table.
    var trustRank: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

// MARK: - How the app runs (plan §8)

/// The two-axis runtime-shape classification collapsed to its three real
/// outcomes. Drives which SWE-best-practice checklist column the agentic loop
/// applies (idempotency, tenancy, migration style, …) and which auto-commit
/// rung is required (ratified decision 5a: L2 for pure-local, L5 for anything
/// with a server/persistence/tenancy).
nonisolated enum RecipeRuntimeShape: String, Sendable {
    /// No server component at all — native app, CLI, a `bin`.
    case pureLocalApp

    /// Binds a port but has no scale/deploy machinery — the self-hosted
    /// single-user webapp shape (one Next.js + one Postgres).
    case localSingleInstanceService

    /// Server component AND scale machinery (k8s/compose/serverless/queues).
    case builtForScale

    /// Signals were absent or contradictory; callers must not assume local.
    case unknown
}

// MARK: - Recipe fields

/// The five command slots a recipe can fill. String-raw + CaseIterable so
/// merge/precedence logic and tests can iterate every field and so the
/// per-field provenance log reads as plain words in the evidence trail.
nonisolated enum RecipeField: String, Sendable, CaseIterable {
    /// Dependency resolution — needs network, so it always runs in the
    /// un-jailed stage.
    case install

    /// Compile/bundle. May legitimately be nil for interpreted stacks.
    case build

    /// The full existing suite. nil means "no suite" — an honest skip that
    /// caps the verification ladder, never a silent green.
    case test

    /// Launch / boot-verify the app.
    case run

    /// Build the relaunchable macOS artifact, if the stack can produce one.
    case package
}

// MARK: - The derived recipe

/// The per-repo replacement for `VerificationCommands.defaults`' hardcoded
/// per-stack switch. Every field is optional and independently attributed:
/// a consumer can see not just WHAT to run but WHY Iris believes it, which is
/// the invariant that keeps the un-jailed build code-adjudicated (plan §5).
nonisolated struct RepoRecipe: Sendable {
    /// Dependency resolution command, if resolved.
    let install: RepoRecipeCommand?
    /// Build command, if resolved (nil is valid for interpreted stacks).
    let build: RepoRecipeCommand?
    /// Test-suite command, if the repo has a real (non-placeholder) suite.
    let test: RepoRecipeCommand?
    /// Launch/boot command, if resolved.
    let run: RepoRecipeCommand?
    /// Relaunchable-artifact command, if the stack can produce one.
    let package: RepoRecipeCommand?

    /// Human-readable ecosystem tag, e.g. "node/next", "rust/tauri",
    /// "swift/xcode". Free-form (registry-defined), not an enum, so adding a
    /// stack is one detector row, not a type change.
    let ecosystemIdentifier: String

    /// §8 classification; drives the checklist column and the required
    /// auto-commit rung.
    let runtimeShape: RecipeRuntimeShape

    /// 0.0–1.0 per field. A field with no entry is unresolved. Conflicting
    /// signals (two lockfiles, multi-scheme Xcode) LOWER this and raise a
    /// clarification (§7) rather than silently picking.
    let confidenceByField: [RecipeField: Double]

    /// Which signal class produced each field — the audit trail that lets a
    /// reader (and the tamper/anti-gaming layer) trace every un-jailed
    /// command back to a declarative source.
    let provenanceByField: [RecipeField: RecipeSignalProvenance]

    init(
        install: RepoRecipeCommand? = nil,
        build: RepoRecipeCommand? = nil,
        test: RepoRecipeCommand? = nil,
        run: RepoRecipeCommand? = nil,
        package: RepoRecipeCommand? = nil,
        ecosystemIdentifier: String,
        runtimeShape: RecipeRuntimeShape,
        confidenceByField: [RecipeField: Double],
        provenanceByField: [RecipeField: RecipeSignalProvenance]
    ) {
        self.install = install
        self.build = build
        self.test = test
        self.run = run
        self.package = package
        self.ecosystemIdentifier = ecosystemIdentifier
        self.runtimeShape = runtimeShape
        self.confidenceByField = confidenceByField
        self.provenanceByField = provenanceByField
    }

    /// The gate that replaces today's `stackHasARealRebuildRecipe()` refusal.
    /// Either a build or an install command is enough to attempt the un-jailed
    /// stage: interpreted stacks (Python, plain Node) have install-but-no-build
    /// and are still perfectly rebuildable. A recipe failing THIS check routes
    /// to the clarification path (§7), not a hard refusal.
    var hasABuildableRecipe: Bool {
        build != nil || install != nil
    }

    /// Convenience accessor so precedence/merge code can treat the five slots
    /// uniformly without five near-identical branches.
    func command(for field: RecipeField) -> RepoRecipeCommand? {
        switch field {
        case .install: return install
        case .build: return build
        case .test: return test
        case .run: return run
        case .package: return package
        }
    }
}

// MARK: - Detector output

/// What one ecosystem detector reports after statically inspecting a clone.
/// Findings from multiple detectors are merged by trust precedence into one
/// `RepoRecipe`; keeping the per-detector result as its own value (rather than
/// mutating a shared recipe) is what makes conflicts VISIBLE so they can lower
/// confidence and raise a follow-up instead of last-writer-wins.
nonisolated struct EcosystemDetectorFinding: Sendable {
    /// The detector's ecosystem tag, copied into the recipe if this finding
    /// wins the merge.
    let ecosystemIdentifier: String

    /// The commands this detector derived, keyed by field. Absent key =
    /// this detector has no opinion on that field.
    let commandsByField: [RecipeField: RepoRecipeCommand]

    /// Per-field confidence for THIS detector's commands (0.0–1.0).
    let confidenceByField: [RecipeField: Double]

    /// Per-field provenance so a merged recipe stays auditable even when its
    /// fields came from different detectors.
    let provenanceByField: [RecipeField: RecipeSignalProvenance]

    /// This detector's vote on the §8 runtime shape (`.unknown` = no vote).
    /// Kept as a contribution, not a verdict — the RuntimeShapeClassifier
    /// combines votes across detectors and its own two-axis signals.
    let runtimeShapeContribution: RecipeRuntimeShape

    /// True when the detector's signal files were actually present. A
    /// non-matching detector may still return a finding (matched: false) to
    /// report a *negative* signal; mergers must ignore its commands.
    let matched: Bool
}

// MARK: - Detector protocol

/// One row of the data-driven registry (plan §4): signal-file check + safe
/// parse + command templates for a single ecosystem. Adding a stack is adding
/// a conforming type, not rewriting an if/else ladder. Implementations must be
/// pure static inspection — read files via `RepoRecipeFiles` only, never
/// execute anything from the repo, never touch the network.
nonisolated protocol EcosystemDetector {
    /// Stable tag, e.g. "rust/cargo", "node/next" — becomes the recipe's
    /// `ecosystemIdentifier` when this detector wins.
    var ecosystemIdentifier: String { get }

    /// Inspect the clone at `repoRootPath`. Return nil when the detector has
    /// nothing at all to say; return a finding with `matched: false` to
    /// report an explicit negative.
    func detect(repoRootPath: String) -> EcosystemDetectorFinding?
}

// MARK: - Side-effect-free file helpers for detectors

/// The ONLY file-access surface detectors are supposed to use. Read-only by
/// construction, size-capped, and confined to the repo root — a manifest field
/// or workflow line naming "../../.." must never walk a detector out of the
/// clone. Centralizing this here means the "detectors never execute or escape
/// the repo" invariant is enforced in one audited place, not re-implemented
/// per detector.
nonisolated enum RepoRecipeFiles {

    /// Manifests and workflow files are small; anything bigger than this is
    /// not a build-signal file and reading it would only waste memory (or be
    /// a hostile decompression-style input). 4 MB is generous for every real
    /// package.json / Cargo.toml / workflow yml.
    private static let maximumSignalFileByteCount = 4 * 1024 * 1024

    /// Resolve a repo-relative path against the repo root, refusing any path
    /// that escapes it after standardization. Returns nil (not a throw) so
    /// detectors read it as "signal absent" — a hostile path and a missing
    /// file look identical, which is exactly the safe behavior.
    private static func containedAbsolutePath(
        forRelativePath relativePath: String,
        underRepoRoot repoRootPath: String
    ) -> String? {
        // Reject absolute inputs outright: every legitimate detector path is
        // repo-relative, so an absolute one is either a bug or an attempt to
        // read outside the clone.
        guard !relativePath.hasPrefix("/") else { return nil }

        let rootURL = URL(fileURLWithPath: repoRootPath).standardizedFileURL
        let candidateURL = rootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL

        // Compare with a trailing "/" on the root so "/repo-evil-sibling"
        // can't pass a bare hasPrefix("/repo") check.
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidateURL.path == rootURL.path || candidateURL.path.hasPrefix(rootPrefix) else {
            return nil
        }
        return candidateURL.path
    }

    /// Does a repo-relative file (or directory) exist under the repo root?
    /// The cheapest Tier-0 signal check.
    static func fileExists(_ relativePath: String, underRepoRoot repoRootPath: String) -> Bool {
        guard let absolutePath = containedAbsolutePath(
            forRelativePath: relativePath,
            underRepoRoot: repoRootPath
        ) else { return false }
        return FileManager.default.fileExists(atPath: absolutePath)
    }

    /// Read a repo-relative text file as UTF-8. Returns nil for missing,
    /// escaping, oversized, or non-UTF-8 files — all of which a detector
    /// should treat the same way: "this signal is absent."
    static func readText(_ relativePath: String, underRepoRoot repoRootPath: String) -> String? {
        guard let absolutePath = containedAbsolutePath(
            forRelativePath: relativePath,
            underRepoRoot: repoRootPath
        ) else { return nil }

        // Size-check before reading so a huge or hostile file never lands in
        // memory. mappedIfSafe keeps even the accepted read cheap.
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: absolutePath),
            let byteCount = attributes[.size] as? Int,
            byteCount <= maximumSignalFileByteCount
        else { return nil }

        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: absolutePath),
            options: [.mappedIfSafe]
        ) else { return nil }

        return String(data: data, encoding: .utf8)
    }

    /// Parse a repo-relative JSON file (package.json, tauri.conf.json, …)
    /// into a dictionary via JSONSerialization — a safe, side-effect-free
    /// parse with no eval, per the Tier-0 rule. Returns nil when the file is
    /// missing, escaping, oversized, malformed, or not a top-level object.
    static func jsonObject(
        atRelativePath relativePath: String,
        underRepoRoot repoRootPath: String
    ) -> [String: Any]? {
        guard let text = readText(relativePath, underRepoRoot: repoRootPath),
              let data = text.data(using: .utf8)
        else { return nil }

        // Some real-world config files (tsconfig-style) carry stray trailing
        // whitespace or BOMs; JSONSerialization handles those. We do NOT
        // accept fragments — a recipe signal file is always an object.
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any]
        else { return nil }
        return object
    }
}

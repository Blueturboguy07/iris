//
//  RepoRecipeNodeWebDetector.swift
//  leanring-buddy
//
//  One row of the data-driven recipe registry (plan §4): the Node/JS-web
//  ecosystem detector. It signals on a root `package.json`, safely parses it
//  (no eval), and derives install/build/test/run/package commands from
//  author-declared scripts first, falling back to a tiny framework registry
//  (Next/Vite/Electron) only for the fields the scripts didn't cover.
//
//  Everything here is pure Foundation static inspection — it only READS files
//  through `RepoRecipeFiles`, never executes anything from the repo, and never
//  touches the network. Every command string it emits is lifted verbatim from
//  the repo's own declarative config (a package.json script) or from a fixed
//  registry template, and each carries its provenance so the un-jailed build
//  stays code-adjudicated (plan §5), auditable back to the signal that produced
//  it.
//

import Foundation

/// Detects Node/JS web projects and derives their recipe.
///
/// Precedence, matching every build-detection tool the plan surveyed:
/// author-declared `package.json` scripts (`explicitProjectConfig`) outrank the
/// framework-registry defaults (`frameworkRegistryDefault`). The package manager
/// is chosen from the committed lockfile — an explicit, author-declared signal —
/// so `install` and the command prefix reflect how the repo is actually built,
/// not a guess.
nonisolated struct RepoRecipeNodeWebDetector: EcosystemDetector {

    /// The stable base tag for this registry row. The per-repo finding refines
    /// it to `node/next` / `node/vite` / `node/electron` when a framework is
    /// recognized (see `NodeWebFramework.ecosystemIdentifier`), but a bare
    /// package.json with no known framework still resolves to this.
    let ecosystemIdentifier = "node/web"

    // MARK: - Confidence constants
    //
    // Named rather than inlined so the "why is this field trusted this much"
    // story is readable in one place and the tests can pin exact rungs.

    /// A command lifted from an author-written package.json script — the most
    /// trustworthy signal this detector can produce.
    private static let scriptDerivedConfidence = 0.9

    /// A command filled in from the framework registry because no script
    /// covered that field. Trustworthy, but a template rather than a
    /// human-authored line, so it ranks below a real script.
    private static let frameworkRegistryConfidence = 0.6

    /// `install` derived from a committed lockfile: the lockfile explicitly
    /// declares which package manager the author uses.
    private static let lockfileDeclaredInstallConfidence = 0.9

    /// `install` when NO lockfile is present and we fall back to npm by bare
    /// ecosystem convention — a defensible default, but only a default.
    private static let defaultedInstallConfidence = 0.5

    /// When more than one lockfile is present the package-manager choice is
    /// genuinely ambiguous, so the build/install confidence is halved to surface
    /// the conflict to the clarification layer (plan §4/§7) instead of silently
    /// committing to one manager.
    private static let multipleLockfileConfidenceMultiplier = 0.5

    // MARK: - Detection entry point

    func detect(repoRootPath: String) -> EcosystemDetectorFinding? {
        // Signal file: a root package.json. Absent → this detector has nothing
        // at all to say, so return nil (not a `matched: false` finding): a repo
        // with no package.json simply is not a Node project, which is a real
        // negative the merge layer needs to see as "no opinion".
        guard let packageJSON = RepoRecipeFiles.jsonObject(
            atRelativePath: "package.json",
            underRepoRoot: repoRootPath
        ) else {
            return nil
        }

        // Safe, side-effect-free reads of the parsed object. A missing or
        // wrong-typed section is treated as absent, never as a parse error the
        // caller must handle.
        let scripts = (packageJSON["scripts"] as? [String: Any]) ?? [:]
        let declaredDependencyNames = Self.dependencyNames(in: packageJSON)

        let chosenPackageManager = Self.resolvePackageManager(repoRootPath: repoRootPath)
        let primaryFramework = Self.resolvePrimaryFramework(
            fromDependencyNames: declaredDependencyNames
        )

        // Halve build/install confidence when the package-manager choice is
        // ambiguous (multiple lockfiles committed).
        let lockfileConfidenceMultiplier = chosenPackageManager.multipleLockfilesPresent
            ? Self.multipleLockfileConfidenceMultiplier
            : 1.0

        var commandsByField: [RecipeField: RepoRecipeCommand] = [:]
        var confidenceByField: [RecipeField: Double] = [:]
        var provenanceByField: [RecipeField: RecipeSignalProvenance] = [:]

        // MARK: install — always resolvable for a Node repo (PM install)
        commandsByField[.install] = RepoRecipeCommand(
            commandLine: chosenPackageManager.installCommandLine
        )
        if chosenPackageManager.lockfilePresent {
            confidenceByField[.install] =
                Self.lockfileDeclaredInstallConfidence * lockfileConfidenceMultiplier
            provenanceByField[.install] = .explicitProjectConfig
        } else {
            // No lockfile: npm is the bare-convention default, not an authored
            // choice, so it ranks as a generic ecosystem default.
            confidenceByField[.install] =
                Self.defaultedInstallConfidence * lockfileConfidenceMultiplier
            provenanceByField[.install] = .genericEcosystemDefault
        }

        // MARK: build — an authored `build` script wins; else a framework default
        // The script's PRESENCE is the signal; the command that runs is the
        // PM-prefixed `<pm> run build`, so the script body itself is not needed.
        if Self.nonEmptyScript(named: "build", in: scripts) != nil {
            commandsByField[.build] = RepoRecipeCommand(
                commandLine: "\(chosenPackageManager.runCommandPrefix) build"
            )
            confidenceByField[.build] = Self.scriptDerivedConfidence * lockfileConfidenceMultiplier
            provenanceByField[.build] = .explicitProjectConfig
        } else if let frameworkBuild = primaryFramework?.buildDefaultCommandLine {
            commandsByField[.build] = RepoRecipeCommand(commandLine: frameworkBuild)
            confidenceByField[.build] = Self.frameworkRegistryConfidence * lockfileConfidenceMultiplier
            provenanceByField[.build] = .frameworkRegistryDefault
        }
        // else: no build field — valid for an interpreted/plain Node project.

        // MARK: test — an authored, NON-placeholder `test` script only
        if let testScript = Self.nonEmptyScript(named: "test", in: scripts),
           !Self.isPlaceholderTestScript(testScript) {
            commandsByField[.test] = RepoRecipeCommand(
                commandLine: "\(chosenPackageManager.runCommandPrefix) test"
            )
            confidenceByField[.test] = Self.scriptDerivedConfidence
            provenanceByField[.test] = .explicitProjectConfig
        }
        // else: no real suite. An honest skip that caps the verification ladder,
        // NEVER a silent green — the CRA/`npm init` placeholder that echoes and
        // forces `exit 1` is deliberately rejected here.

        // MARK: run — production `start` wins over `dev`, then a framework default
        if Self.nonEmptyScript(named: "start", in: scripts) != nil {
            commandsByField[.run] = RepoRecipeCommand(
                commandLine: "\(chosenPackageManager.runCommandPrefix) start"
            )
            confidenceByField[.run] = Self.scriptDerivedConfidence
            provenanceByField[.run] = .explicitProjectConfig
        } else if Self.nonEmptyScript(named: "dev", in: scripts) != nil {
            commandsByField[.run] = RepoRecipeCommand(
                commandLine: "\(chosenPackageManager.runCommandPrefix) dev"
            )
            confidenceByField[.run] = Self.scriptDerivedConfidence
            provenanceByField[.run] = .explicitProjectConfig
        } else if let frameworkRun = primaryFramework?.runDefaultCommandLine {
            commandsByField[.run] = RepoRecipeCommand(commandLine: frameworkRun)
            confidenceByField[.run] = Self.frameworkRegistryConfidence
            provenanceByField[.run] = .frameworkRegistryDefault
        }

        // MARK: package — only frameworks that produce a relaunchable macOS
        // artifact (Electron) contribute one; a web app has a build but no
        // relaunchable native binary (matching AppRelaunchService's stance).
        if let frameworkPackage = primaryFramework?.packageDefaultCommandLine {
            commandsByField[.package] = RepoRecipeCommand(commandLine: frameworkPackage)
            confidenceByField[.package] = Self.frameworkRegistryConfidence
            provenanceByField[.package] = .frameworkRegistryDefault
        }

        let runtimeShapeContribution = Self.classifyRuntimeShape(
            repoRootPath: repoRootPath,
            declaredDependencyNames: declaredDependencyNames
        )

        return EcosystemDetectorFinding(
            ecosystemIdentifier: primaryFramework?.ecosystemIdentifier ?? ecosystemIdentifier,
            commandsByField: commandsByField,
            confidenceByField: confidenceByField,
            provenanceByField: provenanceByField,
            runtimeShapeContribution: runtimeShapeContribution,
            matched: true
        )
    }

    // MARK: - Package manager (lockfile precedence bun > pnpm > yarn > npm)

    /// The four Node package managers, in trust/precedence order. When more than
    /// one lockfile is committed, the highest-precedence one wins the manager
    /// choice AND the ambiguity lowers build/install confidence.
    private struct ResolvedPackageManager {
        let manager: NodePackageManager
        let lockfilePresent: Bool
        let multipleLockfilesPresent: Bool

        var installCommandLine: String { "\(manager.binaryName) install" }
        /// The prefix an authored script is run through, e.g. "pnpm run".
        /// Uniform `<binary> run <script>` because that form works for every one
        /// of the four managers, keeping the emitted command unambiguous.
        var runCommandPrefix: String { "\(manager.binaryName) run" }
    }

    private enum NodePackageManager {
        case bun
        case pnpm
        case yarn
        case npm

        var binaryName: String {
            switch self {
            case .bun: return "bun"
            case .pnpm: return "pnpm"
            case .yarn: return "yarn"
            case .npm: return "npm"
            }
        }

        /// The lockfile filenames (relative to the repo root) that indicate this
        /// manager. Bun has shipped two lockfile names across versions, so both
        /// are recognized.
        var lockfileRelativePaths: [String] {
            switch self {
            case .bun: return ["bun.lockb", "bun.lock"]
            case .pnpm: return ["pnpm-lock.yaml"]
            case .yarn: return ["yarn.lock"]
            case .npm: return ["package-lock.json"]
            }
        }
    }

    /// Resolve the package manager from committed lockfiles. Precedence is the
    /// declaration order below (bun > pnpm > yarn > npm); when none is present,
    /// npm is the bare-convention default and `lockfilePresent` is false so the
    /// caller can lower confidence accordingly.
    private static func resolvePackageManager(repoRootPath: String) -> ResolvedPackageManager {
        let managersInPrecedenceOrder: [NodePackageManager] = [.bun, .pnpm, .yarn, .npm]

        let managersWithACommittedLockfile = managersInPrecedenceOrder.filter { manager in
            manager.lockfileRelativePaths.contains { lockfileRelativePath in
                RepoRecipeFiles.fileExists(lockfileRelativePath, underRepoRoot: repoRootPath)
            }
        }

        let chosenManager = managersWithACommittedLockfile.first ?? .npm
        return ResolvedPackageManager(
            manager: chosenManager,
            lockfilePresent: !managersWithACommittedLockfile.isEmpty,
            multipleLockfilesPresent: managersWithACommittedLockfile.count > 1
        )
    }

    // MARK: - Framework registry (fills gaps the scripts didn't cover)

    /// The small dependency-name → command-template registry, à la
    /// `@vercel/frameworks`. Each case's templates are the plan's fixed strings
    /// (§4); they only fill a field when no authored script covered it, and are
    /// always recorded as `frameworkRegistryDefault` provenance.
    private enum NodeWebFramework {
        case next
        case vite
        case electron

        var ecosystemIdentifier: String {
            switch self {
            case .next: return "node/next"
            case .vite: return "node/vite"
            case .electron: return "node/electron"
            }
        }

        var buildDefaultCommandLine: String? {
            switch self {
            case .next: return "next build"
            case .vite: return "vite build"
            case .electron: return nil // an Electron app's build is its own script; no bare default
            }
        }

        var runDefaultCommandLine: String? {
            switch self {
            case .next: return "next start"
            case .vite: return "vite"
            case .electron: return "electron ."
            }
        }

        var packageDefaultCommandLine: String? {
            switch self {
            case .electron: return "electron-builder"
            case .next, .vite: return nil // web apps have no relaunchable macOS artifact
            }
        }
    }

    /// Choose the single primary framework from the declared dependencies.
    /// Priority next > electron > vite: Next and Electron define the app's whole
    /// shape (a server vs. a desktop shell), while Vite is frequently a
    /// sub-tool of an Electron app, so Electron must win when both appear.
    private static func resolvePrimaryFramework(
        fromDependencyNames declaredDependencyNames: Set<String>
    ) -> NodeWebFramework? {
        if declaredDependencyNames.contains("next") { return .next }
        if declaredDependencyNames.contains("electron") { return .electron }
        if declaredDependencyNames.contains("vite") { return .vite }
        return nil
    }

    // MARK: - Runtime shape (plan §8, two independent axes)

    /// Dependency names that mean "this project stands up an HTTP server that
    /// binds a port". Next is included because `next start`/`next dev` run a
    /// server. This is the "has a server component?" axis.
    private static let serverFrameworkDependencyNames: Set<String> = [
        "express", "fastify", "koa", "next"
    ]

    /// Repo-relative files/directories that mean "this project carries
    /// scale/deploy machinery". The "has scale machinery?" axis. Presence of any
    /// one is enough to consider machinery present.
    private static let scaleMachineryRelativePaths: [String] = [
        "Dockerfile",
        "docker-compose.yml", "docker-compose.yaml",
        "compose.yml", "compose.yaml",
        "k8s", "kubernetes",
        "serverless.yml", "serverless.yaml",
        "vercel.json", "wrangler.toml",
        "fly.toml", "render.yaml",
        "Procfile"
    ]

    /// Combine the two axes into the plan's three outcomes.
    ///
    /// Crucially, machinery ONLY escalates a shape that already has a server —
    /// this is the guard against the documented false positive where a purely
    /// static frontend (no server framework) that happens to ship a Dockerfile
    /// looks "scaled". No server ⇒ pure-local, regardless of machinery.
    private static func classifyRuntimeShape(
        repoRootPath: String,
        declaredDependencyNames: Set<String>
    ) -> RecipeRuntimeShape {
        let hasServerComponent = !declaredDependencyNames
            .isDisjoint(with: serverFrameworkDependencyNames)

        guard hasServerComponent else {
            return .pureLocalApp
        }

        let hasScaleMachinery = scaleMachineryRelativePaths.contains { machineryRelativePath in
            RepoRecipeFiles.fileExists(machineryRelativePath, underRepoRoot: repoRootPath)
        }

        return hasScaleMachinery ? .builtForScale : .localSingleInstanceService
    }

    // MARK: - package.json helpers (pure, safe reads)

    /// Merge the dependency-name keys from every dependency section into one set
    /// so framework/server detection sees a dep regardless of which section
    /// declares it. Version strings are irrelevant — only the presence of a name
    /// matters — so only the keys are collected.
    private static func dependencyNames(in packageJSON: [String: Any]) -> Set<String> {
        let dependencySectionNames = [
            "dependencies", "devDependencies", "peerDependencies", "optionalDependencies"
        ]
        var allNames: Set<String> = []
        for sectionName in dependencySectionNames {
            if let section = packageJSON[sectionName] as? [String: Any] {
                allNames.formUnion(section.keys)
            }
        }
        return allNames
    }

    /// Return the trimmed body of a named script if it exists and is not blank,
    /// else nil. An empty/whitespace script is treated as absent — it can't run.
    private static func nonEmptyScript(named scriptName: String, in scripts: [String: Any]) -> String? {
        guard let rawScript = scripts[scriptName] as? String else { return nil }
        let trimmedScript = rawScript.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedScript.isEmpty ? nil : trimmedScript
    }

    /// The `npm init` / Create-React-App placeholder test — `echo "Error: no
    /// test specified" && exit 1` — is a script that exists only to fail. A real
    /// suite never both starts by echoing and forces a nonzero exit, so a script
    /// matching that shape is rejected as "no suite" rather than run (and would
    /// otherwise fail the build for the wrong reason).
    private static func isPlaceholderTestScript(_ trimmedScript: String) -> Bool {
        let normalizedScript = trimmedScript.lowercased()
        return normalizedScript.hasPrefix("echo") && normalizedScript.contains("exit 1")
    }
}

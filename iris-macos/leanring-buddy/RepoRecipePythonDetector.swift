//
//  RepoRecipePythonDetector.swift
//  leanring-buddy
//
//  One row of the data-driven recipe registry (plan §4): the Python ecosystem
//  detector. Given a clone's root it statically inspects the tree — never
//  executing anything from the repo, never touching the network — and reports
//  how to install/test/run a Python project plus its §8 runtime-shape vote.
//
//  Detection rules (from the Feature Engine spec):
//    - Packaging: pyproject.toml (+ a uv/poetry/pipenv lockfile) else
//      requirements.txt. install = `uv sync` / `poetry install` /
//      `pipenv install` / `pip install -r requirements.txt`.
//    - build is usually nil for an interpreted stack, so this detector emits no
//      build command (an absent field is "unresolved", which is honest, not a
//      fabricated guess — plan §4 graceful degradation).
//    - test = `pytest` when there is a tests/ directory or pytest config; `tox`
//      when tox.ini is present (tox orchestrates the test envs, so it is the
//      right top-level command when it exists).
//    - run = a [project.scripts] console entry, else `python manage.py
//      runserver` for Django, else `flask run` for Flask.
//    - runtimeShape (§8) is a two-axis vote: a web/server framework
//      (flask/django/fastapi/…) gives the "has a server" axis; deploy/scale
//      machinery (Dockerfile EXPOSE, multi-service compose, k8s/Helm,
//      serverless configs, migrations + a DATABASE_URL) gives the "scale" axis.
//
//  Everything is pure Foundation and side-effect-free: file reads go only
//  through `RepoRecipeFiles` (the repo-confined, size-capped surface), and the
//  command strings are lifted from declarative signals so a later un-jailed
//  build stays code-adjudicated (plan §5), never model-authored.
//

import Foundation

nonisolated struct RepoRecipePythonDetector: EcosystemDetector {

    // MARK: - Stable detector identity

    /// The detector's stable family tag. The *specific* ecosystem a clone
    /// resolves to ("python/uv", "python/poetry", "python/pipenv",
    /// "python/pip") is repo-dependent and can only be known after inspection,
    /// so it is reported on the finding — this property is just the registry
    /// row's name, which cannot depend on a repo it has not seen yet.
    let ecosystemIdentifier: String = "python"

    // MARK: - Confidence constants
    //
    // Named so the precedence is legible at a glance and a test can pin the
    // "confident" vs. "ambiguous" boundary rather than a magic number.

    /// A committed tool lockfile (uv.lock / poetry.lock / Pipfile.lock) is the
    /// strongest install signal: it names both the tool AND the resolved deps.
    private static let lockfileInstallConfidence = 0.95

    /// A pyproject tool table ([tool.poetry] / [tool.uv]) with no lockfile:
    /// the tool is author-declared but the exact resolution is not pinned.
    private static let pyprojectToolInstallConfidence = 0.9

    /// requirements.txt is an author-declared dependency list, so
    /// `pip install -r requirements.txt` is directly derived from a real file.
    private static let requirementsInstallConfidence = 0.85

    /// A bare pyproject/setup.py with no lockfile, no tool table, and no
    /// requirements.txt: `pip install .` is a convention, not a declared recipe.
    private static let genericPipInstallConfidence = 0.6

    /// Two different tool lockfiles present at once is exactly the §4
    /// multi-lockfile conflict: pick a deterministic winner but DROP confidence
    /// so the merger raises a clarification (§7) instead of silently trusting it.
    private static let conflictingLockfileInstallConfidence = 0.4

    /// tox.ini is an explicit, author-authored test-orchestration config.
    private static let toxTestConfidence = 0.9

    /// pytest named in project config (pytest.ini / [tool.pytest.ini_options] /
    /// [tool:pytest] / conftest.py) is an explicit declaration.
    private static let pytestConfiguredTestConfidence = 0.9

    /// A bare tests/ directory with no pytest config is a strong convention but
    /// not a declaration, so it ranks below configured pytest.
    private static let pytestByDirectoryTestConfidence = 0.7

    /// manage.py is Django's declared server runner — a very specific signal.
    private static let djangoRunConfidence = 0.9

    /// A [project.scripts] console entry is an explicit, author-declared entry
    /// point that becomes an executable after install.
    private static let scriptRunConfidence = 0.8

    /// `flask run` comes from a framework-registry template keyed on the flask
    /// dependency, not from an author-declared command, so it ranks lower.
    private static let flaskRunConfidence = 0.7

    // MARK: - The one packaging tool a Python project is managed by

    /// Which dependency manager owns the project. Declaration order is the
    /// deterministic precedence used to break a multi-lockfile conflict.
    private enum PythonPackagingTool {
        case uv
        case poetry
        case pipenv

        var installCommandLine: String {
            switch self {
            case .uv: return "uv sync"
            case .poetry: return "poetry install"
            case .pipenv: return "pipenv install"
            }
        }

        var ecosystemIdentifier: String {
            switch self {
            case .uv: return "python/uv"
            case .poetry: return "python/poetry"
            case .pipenv: return "python/pipenv"
            }
        }
    }

    // MARK: - Entry point

    func detect(repoRootPath: String) -> EcosystemDetectorFinding? {
        // Tier-0 filename table: the presence of ANY of these is what makes a
        // clone "a Python project" for this detector. Absent all of them, the
        // detector has nothing to say and returns nil so a non-Python repo is a
        // clean negative rather than a fabricated match.
        let hasPyproject = RepoRecipeFiles.fileExists("pyproject.toml", underRepoRoot: repoRootPath)
        let hasRequirements = RepoRecipeFiles.fileExists("requirements.txt", underRepoRoot: repoRootPath)
        let hasPipfile = RepoRecipeFiles.fileExists("Pipfile", underRepoRoot: repoRootPath)
        let hasPipfileLock = RepoRecipeFiles.fileExists("Pipfile.lock", underRepoRoot: repoRootPath)
        let hasSetupPy = RepoRecipeFiles.fileExists("setup.py", underRepoRoot: repoRootPath)
        let hasSetupCfg = RepoRecipeFiles.fileExists("setup.cfg", underRepoRoot: repoRootPath)
        let hasManagePy = RepoRecipeFiles.fileExists("manage.py", underRepoRoot: repoRootPath)
        let hasToxIni = RepoRecipeFiles.fileExists("tox.ini", underRepoRoot: repoRootPath)
        let hasUvLock = RepoRecipeFiles.fileExists("uv.lock", underRepoRoot: repoRootPath)
        let hasPoetryLock = RepoRecipeFiles.fileExists("poetry.lock", underRepoRoot: repoRootPath)

        let anyPythonSignalPresent =
            hasPyproject || hasRequirements || hasPipfile || hasPipfileLock ||
            hasSetupPy || hasSetupCfg || hasManagePy || hasToxIni || hasUvLock || hasPoetryLock
        guard anyPythonSignalPresent else { return nil }

        // Read the declarative signal files ONCE. Any of these may be nil
        // (missing/oversized/non-UTF-8) — the callers treat nil as "signal
        // absent", which is the safe default.
        let pyprojectText = RepoRecipeFiles.readText("pyproject.toml", underRepoRoot: repoRootPath)
        let dependencyText = concatenatedDependencyDeclaringText(repoRootPath: repoRootPath)

        // The three resolvable command slots (build is intentionally omitted for
        // an interpreted stack). Each returns its command, confidence, and
        // provenance so the finding stays field-by-field auditable.
        let installResolution = resolveInstall(
            hasUvLock: hasUvLock,
            hasPoetryLock: hasPoetryLock,
            hasPipfile: hasPipfile,
            hasPipfileLock: hasPipfileLock,
            hasRequirements: hasRequirements,
            hasPyproject: hasPyproject,
            hasSetupPy: hasSetupPy,
            pyprojectText: pyprojectText
        )

        let testResolution = resolveTest(
            repoRootPath: repoRootPath,
            hasToxIni: hasToxIni,
            hasSetupCfg: hasSetupCfg,
            pyprojectText: pyprojectText
        )

        let runResolution = resolveRun(
            repoRootPath: repoRootPath,
            hasManagePy: hasManagePy,
            pyprojectText: pyprojectText,
            dependencyText: dependencyText
        )

        let runtimeShapeContribution = resolveRuntimeShape(
            repoRootPath: repoRootPath,
            hasManagePy: hasManagePy,
            dependencyText: dependencyText
        )

        // Assemble the per-field maps from whichever slots resolved. An absent
        // key means "this detector has no opinion on that field" — never a
        // zero-confidence placeholder — so the merger can tell resolved-nil
        // (interpreted stacks have no build) from unresolved.
        var commandsByField: [RecipeField: RepoRecipeCommand] = [:]
        var confidenceByField: [RecipeField: Double] = [:]
        var provenanceByField: [RecipeField: RecipeSignalProvenance] = [:]

        if let installResolution {
            commandsByField[.install] = installResolution.command
            confidenceByField[.install] = installResolution.confidence
            provenanceByField[.install] = installResolution.provenance
        }
        if let testResolution {
            commandsByField[.test] = testResolution.command
            confidenceByField[.test] = testResolution.confidence
            provenanceByField[.test] = testResolution.provenance
        }
        if let runResolution {
            commandsByField[.run] = runResolution.command
            confidenceByField[.run] = runResolution.confidence
            provenanceByField[.run] = runResolution.provenance
        }

        // The finding's ecosystem tag comes from the install resolution (which
        // knows the packaging tool). If install could not resolve at all — e.g.
        // only a tox.ini with no dependency files — fall back to the generic
        // Python/pip tag rather than an empty string.
        let resolvedEcosystemIdentifier = installResolution?.ecosystemIdentifier ?? "python/pip"

        return EcosystemDetectorFinding(
            ecosystemIdentifier: resolvedEcosystemIdentifier,
            commandsByField: commandsByField,
            confidenceByField: confidenceByField,
            provenanceByField: provenanceByField,
            runtimeShapeContribution: runtimeShapeContribution,
            matched: true
        )
    }

    // MARK: - install resolution

    /// The install command bundled with everything a caller needs to attribute
    /// it: the field's confidence, its provenance, and the ecosystem tag the
    /// packaging tool implies.
    private struct InstallResolution {
        let command: RepoRecipeCommand
        let confidence: Double
        let provenance: RecipeSignalProvenance
        let ecosystemIdentifier: String
    }

    private func resolveInstall(
        hasUvLock: Bool,
        hasPoetryLock: Bool,
        hasPipfile: Bool,
        hasPipfileLock: Bool,
        hasRequirements: Bool,
        hasPyproject: Bool,
        hasSetupPy: Bool,
        pyprojectText: String?
    ) -> InstallResolution? {
        // A pyproject tool table declares the tool even without a committed
        // lockfile (e.g. a fresh `uv init` before the first `uv lock`).
        let pyprojectDeclaresPoetry = pyprojectText.map { tomlText($0, hasExactTableHeader: "[tool.poetry]") } ?? false
        let pyprojectDeclaresUv = pyprojectText.map { tomlText($0, hasExactTableHeader: "[tool.uv]") } ?? false

        // Collect every tool the repo shows evidence for, in a fixed precedence
        // order. Two distinct tools = the §4 multi-lockfile conflict.
        var candidateTools: [PythonPackagingTool] = []
        if hasUvLock || pyprojectDeclaresUv { candidateTools.append(.uv) }
        if hasPoetryLock || pyprojectDeclaresPoetry { candidateTools.append(.poetry) }
        if hasPipfile || hasPipfileLock { candidateTools.append(.pipenv) }

        if let winningTool = candidateTools.first {
            let hasConflict = candidateTools.count >= 2

            // Confidence: a real lockfile is strongest; a tool table alone is
            // slightly weaker; a conflict is deliberately low so the merger asks.
            let confidence: Double
            if hasConflict {
                confidence = Self.conflictingLockfileInstallConfidence
            } else {
                let winningToolHasLockfile: Bool
                switch winningTool {
                case .uv: winningToolHasLockfile = hasUvLock
                case .poetry: winningToolHasLockfile = hasPoetryLock
                case .pipenv: winningToolHasLockfile = hasPipfileLock
                }
                confidence = winningToolHasLockfile
                    ? Self.lockfileInstallConfidence
                    : Self.pyprojectToolInstallConfidence
            }

            return InstallResolution(
                command: RepoRecipeCommand(commandLine: winningTool.installCommandLine),
                confidence: confidence,
                // The tool is always author-declared (a committed lockfile or a
                // pyproject table); the low confidence, not a weaker provenance,
                // is what carries the ambiguity of a conflict.
                provenance: .explicitProjectConfig,
                ecosystemIdentifier: winningTool.ecosystemIdentifier
            )
        }

        // No managed tool: fall back to pip. requirements.txt is an explicit
        // declared file; a bare pyproject/setup.py is only a convention.
        if hasRequirements {
            return InstallResolution(
                command: RepoRecipeCommand(commandLine: "pip install -r requirements.txt"),
                confidence: Self.requirementsInstallConfidence,
                provenance: .explicitProjectConfig,
                ecosystemIdentifier: "python/pip"
            )
        }
        if hasPyproject || hasSetupPy {
            return InstallResolution(
                command: RepoRecipeCommand(commandLine: "pip install ."),
                confidence: Self.genericPipInstallConfidence,
                provenance: .genericEcosystemDefault,
                ecosystemIdentifier: "python/pip"
            )
        }

        // Reached only when the sole Python signal was a config with no
        // dependency source (e.g. a lone tox.ini). Leave install unresolved
        // rather than inventing one — this routes to clarification (§7).
        return nil
    }

    // MARK: - test resolution

    private struct CommandResolution {
        let command: RepoRecipeCommand
        let confidence: Double
        let provenance: RecipeSignalProvenance
    }

    private func resolveTest(
        repoRootPath: String,
        hasToxIni: Bool,
        hasSetupCfg: Bool,
        pyprojectText: String?
    ) -> CommandResolution? {
        // tox.ini wins: tox orchestrates the test environments, so it is the
        // correct top-level test command whenever the repo commits one.
        if hasToxIni {
            return CommandResolution(
                command: RepoRecipeCommand(commandLine: "tox"),
                confidence: Self.toxTestConfidence,
                provenance: .explicitProjectConfig
            )
        }

        // pytest configured in project config is an explicit declaration.
        let pyprojectDeclaresPytest = pyprojectText.map {
            tomlText($0, hasExactTableHeader: "[tool.pytest.ini_options]")
        } ?? false
        let setupCfgDeclaresPytest = hasSetupCfg
            && (RepoRecipeFiles.readText("setup.cfg", underRepoRoot: repoRootPath)?
                .contains("[tool:pytest]") ?? false)
        let pytestIsConfigured =
            RepoRecipeFiles.fileExists("pytest.ini", underRepoRoot: repoRootPath)
            || RepoRecipeFiles.fileExists("conftest.py", underRepoRoot: repoRootPath)
            || pyprojectDeclaresPytest
            || setupCfgDeclaresPytest

        if pytestIsConfigured {
            return CommandResolution(
                command: RepoRecipeCommand(commandLine: "pytest"),
                confidence: Self.pytestConfiguredTestConfidence,
                provenance: .explicitProjectConfig
            )
        }

        // A bare tests/ (or test/) directory is a strong convention: pytest can
        // discover and run it even with no config, so it is a valid — if weaker
        // — test command.
        let hasTestDirectory =
            RepoRecipeFiles.fileExists("tests", underRepoRoot: repoRootPath)
            || RepoRecipeFiles.fileExists("test", underRepoRoot: repoRootPath)
        if hasTestDirectory {
            return CommandResolution(
                command: RepoRecipeCommand(commandLine: "pytest"),
                confidence: Self.pytestByDirectoryTestConfidence,
                provenance: .genericEcosystemDefault
            )
        }

        // No suite at all: leave test unresolved. An honest "no suite" that
        // caps the verification ladder, never a silent green.
        return nil
    }

    // MARK: - run resolution

    private func resolveRun(
        repoRootPath: String,
        hasManagePy: Bool,
        pyprojectText: String?,
        dependencyText: String
    ) -> CommandResolution? {
        // Django's manage.py is the definitive, unambiguous way to launch the
        // app, and it pairs with the django runtime-shape vote — so it wins.
        if hasManagePy {
            return CommandResolution(
                command: RepoRecipeCommand(commandLine: "python manage.py runserver"),
                confidence: Self.djangoRunConfidence,
                provenance: .explicitProjectConfig
            )
        }

        // A [project.scripts] / [tool.poetry.scripts] console entry is an
        // author-declared executable. Sort for determinism; if several are
        // declared, the first is a defensible default (still explicit intent).
        if let pyprojectText {
            var declaredScriptNames = tomlTableKeys(pyprojectText, underTableHeader: "[project.scripts]")
            declaredScriptNames.append(contentsOf: tomlTableKeys(pyprojectText, underTableHeader: "[tool.poetry.scripts]"))
            if let firstScriptName = declaredScriptNames.sorted().first {
                return CommandResolution(
                    command: RepoRecipeCommand(commandLine: firstScriptName),
                    confidence: Self.scriptRunConfidence,
                    provenance: .explicitProjectConfig
                )
            }
        }

        // Flask's run command is a framework-registry template keyed on the
        // flask dependency — it is not author-declared, hence the lower rung.
        if dependencyText.contains("flask") {
            return CommandResolution(
                command: RepoRecipeCommand(commandLine: "flask run"),
                confidence: Self.flaskRunConfidence,
                provenance: .frameworkRegistryDefault
            )
        }

        // No resolvable launch command (e.g. a FastAPI app with no console
        // script — the module path cannot be guessed safely). Leave run
        // unresolved so the clarification path asks how to run it (§7), rather
        // than fabricating a `uvicorn module:app` that may be wrong.
        return nil
    }

    // MARK: - runtime-shape vote (§8)

    private func resolveRuntimeShape(
        repoRootPath: String,
        hasManagePy: Bool,
        dependencyText: String
    ) -> RecipeRuntimeShape {
        let hasServerComponent = repoHasServerComponent(
            repoRootPath: repoRootPath,
            hasManagePy: hasManagePy,
            dependencyText: dependencyText
        )
        let hasScaleMachinery = repoHasScaleMachinery(repoRootPath: repoRootPath)

        // The two-axis collapse. A matched Python project with no server is a
        // legitimate pure-local CLI/library — a real classification, not
        // `.unknown`, which is reserved for genuinely contradictory signals.
        switch (hasServerComponent, hasScaleMachinery) {
        case (true, true): return .builtForScale
        case (true, false): return .localSingleInstanceService
        case (false, _): return .pureLocalApp
        }
    }

    /// The "has a server component" axis: a web/server framework in the
    /// declared dependencies, or a Django manage.py, or a WSGI/ASGI entry file.
    private func repoHasServerComponent(
        repoRootPath: String,
        hasManagePy: Bool,
        dependencyText: String
    ) -> Bool {
        if hasManagePy { return true }
        if RepoRecipeFiles.fileExists("wsgi.py", underRepoRoot: repoRootPath) { return true }
        if RepoRecipeFiles.fileExists("asgi.py", underRepoRoot: repoRootPath) { return true }

        // Server/web framework or server-runner dependency tokens. Substring
        // matches on the concatenated, lowercased dependency text — good enough
        // to spot a declared framework without a full TOML/requirements parse.
        let serverFrameworkTokens = [
            "django", "flask", "fastapi", "starlette",
            "aiohttp", "tornado", "sanic", "bottle",
            "gunicorn", "uvicorn", "hypercorn",
        ]
        return serverFrameworkTokens.contains { dependencyText.contains($0) }
    }

    /// The "scale/deploy machinery" axis. Only concrete, well-known paths are
    /// checked (RepoRecipeFiles has no directory listing by design), each a
    /// signal from §8's table. Any one is enough to raise the scale axis.
    private func repoHasScaleMachinery(repoRootPath: String) -> Bool {
        // A Dockerfile that opens a port is a deploy artifact, not a local run.
        if let dockerfileText = RepoRecipeFiles.readText("Dockerfile", underRepoRoot: repoRootPath),
           dockerfileText.range(of: "EXPOSE", options: .caseInsensitive) != nil {
            return true
        }

        // A compose file wiring together two or more services (app + db, …).
        let composeFileNames = ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"]
        for composeFileName in composeFileNames {
            if let composeText = RepoRecipeFiles.readText(composeFileName, underRepoRoot: repoRootPath),
               countComposeServices(inComposeYAML: composeText) >= 2 {
                return true
            }
        }

        // Kubernetes / Helm packaging.
        if RepoRecipeFiles.fileExists("Chart.yaml", underRepoRoot: repoRootPath)
            || RepoRecipeFiles.fileExists("k8s", underRepoRoot: repoRootPath)
            || RepoRecipeFiles.fileExists("kubernetes", underRepoRoot: repoRootPath) {
            return true
        }

        // Serverless / managed-platform deploy descriptors.
        let serverlessDeployConfigs = [
            "vercel.json", "wrangler.toml", "serverless.yml",
            "serverless.yaml", "fly.toml", "render.yaml",
        ]
        for serverlessDeployConfig in serverlessDeployConfigs {
            if RepoRecipeFiles.fileExists(serverlessDeployConfig, underRepoRoot: repoRootPath) {
                return true
            }
        }

        // Migrations + a DATABASE_URL. §8 pairs these deliberately: Django ships
        // migrations/ folders even for single-user apps, so migrations alone is
        // NOT a scale signal — it only counts alongside an externalized DB URL.
        let hasMigrationTooling =
            RepoRecipeFiles.fileExists("alembic.ini", underRepoRoot: repoRootPath)
            || RepoRecipeFiles.fileExists("migrations", underRepoRoot: repoRootPath)
        if hasMigrationTooling && repoReferencesExternalDatabaseURL(repoRootPath: repoRootPath) {
            return true
        }

        return false
    }

    /// Does the repo externalize its database via a DATABASE_URL env var (or a
    /// helper that reads one)? A concrete set of well-known files is scanned —
    /// no globbing, so this stays deterministic and repo-confined.
    private func repoReferencesExternalDatabaseURL(repoRootPath: String) -> Bool {
        let candidateFiles = [
            ".env.example", ".env.sample", ".env.template",
            "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml",
            "settings.py", "config.py",
        ]
        for candidateFile in candidateFiles {
            if let text = RepoRecipeFiles.readText(candidateFile, underRepoRoot: repoRootPath),
               text.contains("DATABASE_URL") {
                return true
            }
        }
        // dj-database-url exists specifically to parse a DATABASE_URL env var.
        return concatenatedDependencyDeclaringText(repoRootPath: repoRootPath).contains("dj-database-url")
    }

    // MARK: - Declarative-text helpers (pure, side-effect-free)

    /// The union of every dependency-declaring file's text, lowercased, for
    /// substring framework/driver detection. Reading them all once and matching
    /// case-insensitively is enough to spot a declared dependency name without a
    /// per-format (TOML/INI/requirements) parser.
    private func concatenatedDependencyDeclaringText(repoRootPath: String) -> String {
        let dependencyDeclaringFiles = [
            "pyproject.toml", "requirements.txt", "Pipfile",
            "setup.py", "setup.cfg",
        ]
        var combined = ""
        for dependencyDeclaringFile in dependencyDeclaringFiles {
            if let text = RepoRecipeFiles.readText(dependencyDeclaringFile, underRepoRoot: repoRootPath) {
                combined += "\n"
                combined += text
            }
        }
        return combined.lowercased()
    }

    /// True when the TOML text contains a table header line exactly equal to
    /// `exactHeader` (e.g. "[tool.poetry]"). A whole-line match, not a
    /// substring — so "[tool.poetry.scripts]" does NOT satisfy "[tool.poetry]".
    private func tomlText(_ text: String, hasExactTableHeader exactHeader: String) -> Bool {
        for rawLine in text.components(separatedBy: "\n") {
            if rawLine.trimmingCharacters(in: .whitespaces) == exactHeader {
                return true
            }
        }
        return false
    }

    /// The key names (left-hand side of `key = value` lines) declared directly
    /// under a TOML table header, stopping at the next header. Used to read
    /// [project.scripts] / [tool.poetry.scripts] console-script names. A
    /// deliberately simple table reader (no inline-table support) — sufficient
    /// for the standard multi-line scripts table and, by construction, free of
    /// any eval or side effect.
    private func tomlTableKeys(_ text: String, underTableHeader tableHeader: String) -> [String] {
        var keyNames: [String] = []
        var insideTargetTable = false

        for rawLine in text.components(separatedBy: "\n") {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)

            // A table header line switches which table we are inside.
            if trimmedLine.hasPrefix("[") && trimmedLine.hasSuffix("]") {
                insideTargetTable = (trimmedLine == tableHeader)
                continue
            }
            guard insideTargetTable else { continue }
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") { continue }

            guard let equalsIndex = trimmedLine.firstIndex(of: "=") else { continue }
            // String(...) because trimmingCharacters(in:) is a String method,
            // not available on the Substring the slice produces.
            let rawKey = String(trimmedLine[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            let unquotedKey = rawKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !unquotedKey.isEmpty {
                keyNames.append(unquotedKey)
            }
        }
        return keyNames
    }

    /// Counts the direct child keys under a compose file's top-level
    /// `services:` mapping — i.e. how many services it defines. A lightweight
    /// indentation scan (no YAML library): find `services:`, then count the
    /// keys at the first indentation level beneath it until the block ends.
    private func countComposeServices(inComposeYAML composeYAML: String) -> Int {
        let lines = composeYAML.components(separatedBy: "\n")
        var isInsideServicesBlock = false
        var servicesHeaderIndent = 0
        var serviceEntryIndent: Int? = nil
        var serviceCount = 0

        for rawLine in lines {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") { continue }

            let indent = rawLine.prefix { $0 == " " }.count

            if !isInsideServicesBlock {
                if trimmedLine == "services:" || trimmedLine.hasPrefix("services:") {
                    isInsideServicesBlock = true
                    servicesHeaderIndent = indent
                }
                continue
            }

            // A key at or above the `services:` indent ends the services block.
            if indent <= servicesHeaderIndent {
                break
            }

            // The first indentation level inside the block holds the service
            // names; deeper lines are a service's own config and are ignored.
            if let establishedServiceEntryIndent = serviceEntryIndent {
                if indent == establishedServiceEntryIndent && trimmedLine.hasSuffix(":") {
                    serviceCount += 1
                }
            } else {
                serviceEntryIndent = indent
                if trimmedLine.hasSuffix(":") {
                    serviceCount += 1
                }
            }
        }
        return serviceCount
    }
}

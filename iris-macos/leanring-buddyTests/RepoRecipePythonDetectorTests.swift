//
//  RepoRecipePythonDetectorTests.swift
//  leanring-buddyTests
//
//  Fixture-driven unit coverage for the Python row of the recipe registry
//  (plan §10.1). Each test writes a tiny real repo into a temp directory, runs
//  the detector against it, and asserts the resolved commands, confidence,
//  provenance, and the §8 runtime-shape vote. Includes the required NEGATIVE
//  case (a non-Python repo must produce no match) and CONFLICT case (two
//  packaging lockfiles must drop install confidence, not silently pick with
//  full confidence). Pure Foundation — no processes, no network.
//

import Foundation
import Testing
@testable import Iris

@Suite struct RepoRecipePythonDetectorTests {

    // MARK: - uv-managed, pure-local CLI

    @Test func uvManagedCliProjectResolvesUvSyncAndItsConsoleScript() throws {
        // A uv.lock is the strongest install signal; [project.scripts] declares
        // the run entry; a tests/ dir gives a discoverable pytest suite; no web
        // framework at all, so the runtime shape is pure-local.
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "pyproject.toml": """
            [project]
            name = "sample-cli"
            version = "0.1.0"

            [project.scripts]
            samplecli = "sample_cli.__main__:main"
            """,
            "uv.lock": "# resolved lockfile\n",
            "tests/test_smoke.py": "def test_ok():\n    assert True\n",
        ])
        defer { Self.removeRepo(repoRootPath) }

        let finding = try #require(RepoRecipePythonDetector().detect(repoRootPath: repoRootPath))

        #expect(finding.matched)
        #expect(finding.ecosystemIdentifier == "python/uv")

        #expect(finding.commandsByField[.install]?.commandLine == "uv sync")
        #expect(finding.confidenceByField[.install] == 0.95)
        #expect(finding.provenanceByField[.install] == .explicitProjectConfig)

        // build is intentionally unresolved for an interpreted stack — an
        // absent field, never a fabricated command.
        #expect(finding.commandsByField[.build] == nil)
        #expect(finding.confidenceByField[.build] == nil)

        #expect(finding.commandsByField[.run]?.commandLine == "samplecli")
        #expect(finding.provenanceByField[.run] == .explicitProjectConfig)

        // tests/ exists but there is no pytest config, so pytest is chosen by
        // convention (the weaker, generic provenance).
        #expect(finding.commandsByField[.test]?.commandLine == "pytest")
        #expect(finding.confidenceByField[.test] == 0.7)
        #expect(finding.provenanceByField[.test] == .genericEcosystemDefault)

        #expect(finding.runtimeShapeContribution == .pureLocalApp)
    }

    // MARK: - Poetry + Django + tox, a local single-instance service

    @Test func poetryDjangoProjectResolvesPoetryInstallToxAndManageRunserver() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "pyproject.toml": """
            [tool.poetry]
            name = "sample-web"
            version = "0.1.0"

            [tool.poetry.dependencies]
            python = "^3.11"
            django = "^4.2"
            """,
            "poetry.lock": "# resolved lockfile\n",
            "tox.ini": "[tox]\nenvlist = py311\n",
            "manage.py": "#!/usr/bin/env python\n",
        ])
        defer { Self.removeRepo(repoRootPath) }

        let finding = try #require(RepoRecipePythonDetector().detect(repoRootPath: repoRootPath))

        #expect(finding.ecosystemIdentifier == "python/poetry")

        #expect(finding.commandsByField[.install]?.commandLine == "poetry install")
        #expect(finding.confidenceByField[.install] == 0.95)
        #expect(finding.provenanceByField[.install] == .explicitProjectConfig)

        // tox.ini present → the top-level test command is tox, not pytest.
        #expect(finding.commandsByField[.test]?.commandLine == "tox")
        #expect(finding.confidenceByField[.test] == 0.9)
        #expect(finding.provenanceByField[.test] == .explicitProjectConfig)

        #expect(finding.commandsByField[.run]?.commandLine == "python manage.py runserver")
        #expect(finding.provenanceByField[.run] == .explicitProjectConfig)

        // Django server, but no deploy/scale machinery → single-instance shape.
        #expect(finding.runtimeShapeContribution == .localSingleInstanceService)
    }

    // MARK: - requirements.txt + Flask, a local single-instance service

    @Test func requirementsFlaskProjectResolvesPipInstallAndFlaskRun() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "requirements.txt": "Flask==3.0.0\n",
            "app.py": "from flask import Flask\napp = Flask(__name__)\n",
            "tests/test_app.py": "def test_home():\n    assert True\n",
        ])
        defer { Self.removeRepo(repoRootPath) }

        let finding = try #require(RepoRecipePythonDetector().detect(repoRootPath: repoRootPath))

        #expect(finding.ecosystemIdentifier == "python/pip")

        #expect(finding.commandsByField[.install]?.commandLine == "pip install -r requirements.txt")
        #expect(finding.confidenceByField[.install] == 0.85)
        #expect(finding.provenanceByField[.install] == .explicitProjectConfig)

        #expect(finding.commandsByField[.test]?.commandLine == "pytest")

        // No manage.py, no console script — Flask supplies the run template.
        #expect(finding.commandsByField[.run]?.commandLine == "flask run")
        #expect(finding.confidenceByField[.run] == 0.7)
        #expect(finding.provenanceByField[.run] == .frameworkRegistryDefault)

        #expect(finding.runtimeShapeContribution == .localSingleInstanceService)
    }

    // MARK: - FastAPI + Docker + multi-service compose = built for scale

    @Test func fastapiWithDockerAndComposeIsClassifiedBuiltForScale() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "requirements.txt": "fastapi==0.110.0\nuvicorn==0.29.0\n",
            "Dockerfile": "FROM python:3.11\nEXPOSE 8000\nCMD [\"uvicorn\", \"main:app\"]\n",
            "docker-compose.yml": """
            services:
              web:
                build: .
                ports:
                  - "8000:8000"
              db:
                image: postgres:15
            """,
            "tests/test_api.py": "def test_root():\n    assert True\n",
        ])
        defer { Self.removeRepo(repoRootPath) }

        let finding = try #require(RepoRecipePythonDetector().detect(repoRootPath: repoRootPath))

        #expect(finding.commandsByField[.install]?.commandLine == "pip install -r requirements.txt")
        #expect(finding.commandsByField[.test]?.commandLine == "pytest")

        // FastAPI has no console script and no manage.py, and a uvicorn module
        // path cannot be guessed safely — run stays honestly unresolved.
        #expect(finding.commandsByField[.run] == nil)

        // Server component (fastapi) + scale machinery (Dockerfile EXPOSE and a
        // two-service compose) → the scaled shape.
        #expect(finding.runtimeShapeContribution == .builtForScale)
    }

    // MARK: - NEGATIVE: a non-Python repo produces no match

    @Test func aNodeOnlyRepoIsNotDetectedAsPython() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "package.json": "{\"name\":\"web\",\"scripts\":{\"build\":\"next build\"}}",
            "next.config.js": "module.exports = {}\n",
        ])
        defer { Self.removeRepo(repoRootPath) }

        // Nothing Python here — the detector must stay silent (nil), which is
        // the clean negative the registry merges as "this row has no opinion".
        #expect(RepoRecipePythonDetector().detect(repoRootPath: repoRootPath) == nil)
    }

    // MARK: - CONFLICT: two lockfiles drop install confidence

    @Test func twoDifferentLockfilesLowerInstallConfidenceInsteadOfSilentlyPicking() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "pyproject.toml": """
            [project]
            name = "ambiguous"
            version = "0.1.0"
            """,
            "uv.lock": "# uv lockfile\n",
            "poetry.lock": "# poetry lockfile\n",
        ])
        defer { Self.removeRepo(repoRootPath) }

        let finding = try #require(RepoRecipePythonDetector().detect(repoRootPath: repoRootPath))

        // A deterministic winner is still chosen (uv, by fixed precedence) so a
        // command exists to offer — but the confidence is DROPPED well below the
        // "confident" band so the merger surfaces a §7 clarification.
        #expect(finding.commandsByField[.install]?.commandLine == "uv sync")
        #expect(finding.ecosystemIdentifier == "python/uv")
        let installConfidence = try #require(finding.confidenceByField[.install])
        #expect(installConfidence == 0.4)
        #expect(installConfidence < 0.6)
    }

    // MARK: - pytest config without a tests/ directory

    @Test func pytestConfiguredInPyprojectIsAnExplicitTestSignal() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "pyproject.toml": """
            [project]
            name = "configured"
            version = "0.1.0"

            [tool.pytest.ini_options]
            testpaths = ["checks"]
            """,
            "requirements.txt": "pytest==8.0.0\n",
        ])
        defer { Self.removeRepo(repoRootPath) }

        let finding = try #require(RepoRecipePythonDetector().detect(repoRootPath: repoRootPath))

        // Configured pytest is an author declaration → higher confidence AND the
        // explicit provenance, even though there is no conventional tests/ dir.
        #expect(finding.commandsByField[.test]?.commandLine == "pytest")
        #expect(finding.confidenceByField[.test] == 0.9)
        #expect(finding.provenanceByField[.test] == .explicitProjectConfig)
    }

    // MARK: - Migrations alone do NOT imply scale

    @Test func djangoMigrationsWithoutADatabaseURLStayLocalSingleInstance() throws {
        // A Django app ships migrations/ folders even when it is single-user;
        // §8 only counts migrations as scale machinery alongside an externalized
        // DATABASE_URL, so this must NOT be misclassified as built-for-scale.
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "requirements.txt": "Django==5.0\n",
            "manage.py": "#!/usr/bin/env python\n",
            "migrations/0001_initial.py": "# generated migration\n",
        ])
        defer { Self.removeRepo(repoRootPath) }

        let finding = try #require(RepoRecipePythonDetector().detect(repoRootPath: repoRootPath))

        #expect(finding.runtimeShapeContribution == .localSingleInstanceService)
    }

    // MARK: - Migrations + a DATABASE_URL DO imply scale

    @Test func migrationsPlusAnExternalDatabaseURLIsBuiltForScale() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "requirements.txt": "Django==5.0\n",
            "manage.py": "#!/usr/bin/env python\n",
            "migrations/0001_initial.py": "# generated migration\n",
            ".env.example": "DATABASE_URL=postgres://user:pass@db:5432/app\n",
        ])
        defer { Self.removeRepo(repoRootPath) }

        let finding = try #require(RepoRecipePythonDetector().detect(repoRootPath: repoRootPath))

        #expect(finding.runtimeShapeContribution == .builtForScale)
    }

    // MARK: - Fixture helpers

    /// Writes `files` (repo-relative path → contents) into a fresh temp
    /// directory, creating any intermediate directories, and returns its root.
    /// A path ending in a nested directory (e.g. "tests/test_x.py") is what
    /// makes that directory exist for a `fileExists("tests")` check.
    static func makeFixtureRepo(files: [String: String]) throws -> String {
        let repoRootPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-python-detector-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(
            atPath: repoRootPath,
            withIntermediateDirectories: true
        )
        for (relativePath, contents) in files {
            let fullPath = repoRootPath + "/" + relativePath
            let parentDirectoryPath = (fullPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parentDirectoryPath,
                withIntermediateDirectories: true
            )
            try contents.write(toFile: fullPath, atomically: true, encoding: .utf8)
        }
        return repoRootPath
    }

    static func removeRepo(_ repoRootPath: String) {
        try? FileManager.default.removeItem(atPath: repoRootPath)
    }
}

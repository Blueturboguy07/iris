//
//  RepoRecipeContainerDetectorTests.swift
//  leanring-buddyTests
//
//  Fixture-driven coverage for the container / orchestration fallback detector
//  (plan §4 recipe derivation, §8 runtime shape). Each case materializes a real
//  temp-dir repo, runs the detector against it, and asserts the resolved
//  commands, their provenance, their (modest-vs-high) confidence, and the
//  two-axis runtime-shape vote — plus the negative case (no signals → no
//  opinion) and the Dockerfile-vs-compose conflict case (compose wins `run`,
//  confidence lowered so the ambiguity is auditable). Pure static inspection:
//  no processes, no network.
//

import Foundation
import Testing
@testable import Iris

@Suite struct RepoRecipeContainerDetectorTests {

    // MARK: - Temp-dir fixture helpers

    /// Create a throwaway repo directory containing exactly `files`
    /// (relativePath → contents) and return its absolute path. Each test
    /// removes it via `defer` so the fixtures never accumulate on disk.
    private func makeFixtureRepository(
        files: [(relativePath: String, contents: String)]
    ) -> String {
        let repositoryRootPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-container-detector-\(UUID().uuidString)")
            .path
        try? FileManager.default.createDirectory(
            atPath: repositoryRootPath, withIntermediateDirectories: true
        )
        for (relativePath, contents) in files {
            let fileURL = URL(fileURLWithPath: repositoryRootPath).appendingPathComponent(relativePath)
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return repositoryRootPath
    }

    private func removeFixtureRepository(_ repositoryRootPath: String) {
        try? FileManager.default.removeItem(atPath: repositoryRootPath)
    }

    // MARK: - Dockerfile: build + run, modest confidence, abstains on shape

    @Test func aPlainDockerfileYieldsModestConfidenceBuildAndRunAndAbstainsOnShape() {
        let repositoryRootPath = makeFixtureRepository(files: [
            ("Dockerfile", "FROM alpine:3.19\nCOPY . /app\nCMD [\"/app/run.sh\"]\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding != nil)
        guard let finding else { return }

        #expect(finding.matched == true)
        #expect(finding.ecosystemIdentifier == "docker")

        // Build and run are lifted from the Dockerfile using the same local tag.
        #expect(finding.commandsByField[.build]
            == RepoRecipeCommand(commandLine: "docker build -t iris-local-image ."))
        #expect(finding.commandsByField[.run]
            == RepoRecipeCommand(commandLine: "docker run --rm iris-local-image"))
        // These container commands run at the repo root, never a subdirectory.
        #expect(finding.commandsByField[.build]?.workingSubdirectory == nil)
        #expect(finding.commandsByField[.run]?.workingSubdirectory == nil)

        // A Dockerfile is a generic ecosystem default, and its confidence is
        // deliberately modest so a language detector wins the language fields.
        #expect(finding.provenanceByField[.build] == .genericEcosystemDefault)
        #expect(finding.provenanceByField[.run] == .genericEcosystemDefault)
        #expect((finding.confidenceByField[.build] ?? 1.0) <= 0.5)
        #expect((finding.confidenceByField[.run] ?? 1.0) <= 0.5)

        // No EXPOSE and no other scale machinery → the detector abstains rather
        // than mislabeling a container-built app as scaled.
        #expect(finding.runtimeShapeContribution == .unknown)

        // A bare Dockerfile declares no test, install, or macOS package.
        #expect(finding.commandsByField[.test] == nil)
        #expect(finding.commandsByField[.install] == nil)
        #expect(finding.commandsByField[.package] == nil)
    }

    @Test func aDockerfileWithAnExposedPortVotesBuiltForScale() {
        let repositoryRootPath = makeFixtureRepository(files: [
            ("Dockerfile", "FROM node:20\nWORKDIR /srv\nCOPY . .\nEXPOSE 8080\nCMD [\"node\", \"server.js\"]\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding?.runtimeShapeContribution == .builtForScale)
    }

    @Test func aDockerfileExposingAPortVariableAlsoVotesBuiltForScale() {
        // "EXPOSE $PORT" carries no literal digit but still declares a served
        // port, so the PORT-variable branch of the scale signal must fire.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("Dockerfile", "FROM python:3.12\nEXPOSE $PORT\nCMD [\"python\", \"app.py\"]\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding?.runtimeShapeContribution == .builtForScale)
    }

    // MARK: - Compose: run only, multi-service shape

    @Test func aSingleServiceComposeFileYieldsRunUpAndAbstainsOnShape() {
        let composeText = """
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
        """
        let repositoryRootPath = makeFixtureRepository(files: [
            ("docker-compose.yml", composeText),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding != nil)
        guard let finding else { return }

        #expect(finding.ecosystemIdentifier == "docker/compose")
        #expect(finding.commandsByField[.run]
            == RepoRecipeCommand(commandLine: "docker compose up"))
        #expect(finding.provenanceByField[.run] == .genericEcosystemDefault)
        #expect((finding.confidenceByField[.run] ?? 1.0) <= 0.5)
        // Compose alone provides no separate build command (`up` builds inline).
        #expect(finding.commandsByField[.build] == nil)
        // One service is not a scale signal.
        #expect(finding.runtimeShapeContribution == .unknown)
    }

    @Test func aMultiServiceComposeFileVotesBuiltForScale() {
        let composeText = """
        version: "3.9"
        services:
          web:
            image: nginx
          db:
            image: postgres:16
          cache:
            image: redis
        """
        let repositoryRootPath = makeFixtureRepository(files: [
            ("compose.yaml", composeText),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding?.commandsByField[.run]
            == RepoRecipeCommand(commandLine: "docker compose up"))
        #expect(finding?.runtimeShapeContribution == .builtForScale)
    }

    // MARK: - Conflict: Dockerfile AND compose both want `run`

    @Test func aDockerfileAndComposeTogetherLetComposeWinRunWithLoweredConfidence() {
        let composeText = """
        services:
          app:
            build: .
        """
        let repositoryRootPath = makeFixtureRepository(files: [
            ("Dockerfile", "FROM golang:1.22\nCOPY . .\nRUN go build -o app .\nCMD [\"./app\"]\n"),
            ("docker-compose.yml", composeText),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding != nil)
        guard let finding else { return }

        // Build still comes from the Dockerfile.
        #expect(finding.commandsByField[.build]
            == RepoRecipeCommand(commandLine: "docker build -t iris-local-image ."))
        // Compose orchestrates the app, so `docker compose up` wins the run
        // field over the Dockerfile's bare `docker run`.
        #expect(finding.commandsByField[.run]
            == RepoRecipeCommand(commandLine: "docker compose up"))

        // The two-signal conflict on `run` must LOWER its confidence below the
        // solo build confidence, so the ambiguity is visible in the audit trail
        // rather than silently resolved.
        let runConfidence = finding.confidenceByField[.run] ?? 1.0
        let buildConfidence = finding.confidenceByField[.build] ?? 0.0
        #expect(runConfidence < buildConfidence)
    }

    // MARK: - Makefile: author-declared targets at high precedence

    @Test func aMakefileMapsLifecycleTargetsToMakeTargetsAtExplicitProjectConfig() {
        let makefileText = """
        .PHONY: install build test run clean

        install:
        \tnpm ci

        build:
        \tnpm run build

        test:
        \tnpm test

        run:
        \tnpm start

        clean:
        \trm -rf dist
        """
        let repositoryRootPath = makeFixtureRepository(files: [
            ("Makefile", makefileText),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding != nil)
        guard let finding else { return }

        #expect(finding.ecosystemIdentifier == "make")

        // The four conventional lifecycle targets map to `make <target>`.
        #expect(finding.commandsByField[.install] == RepoRecipeCommand(commandLine: "make install"))
        #expect(finding.commandsByField[.build] == RepoRecipeCommand(commandLine: "make build"))
        #expect(finding.commandsByField[.test] == RepoRecipeCommand(commandLine: "make test"))
        #expect(finding.commandsByField[.run] == RepoRecipeCommand(commandLine: "make run"))

        // A Makefile target is author-declared intent: high-precedence
        // provenance and high confidence, unlike the modest container defaults.
        for field in [RecipeField.install, .build, .test, .run] {
            #expect(finding.provenanceByField[field] == .explicitProjectConfig)
            #expect((finding.confidenceByField[field] ?? 0.0) >= 0.8)
        }

        // `clean` is not a lifecycle target, so no stray command; and a
        // Makefile alone says nothing about scale.
        #expect(finding.commandsByField[.package] == nil)
        #expect(finding.runtimeShapeContribution == .unknown)
    }

    @Test func aMakefileIgnoresDirectivesAndVariableAssignmentsAndNonLifecycleTargets() {
        // .PHONY is a directive, VERSION := ... is a variable assignment, and
        // deploy is a real target but not one of the four lifecycle names —
        // none of them may produce a command.
        let makefileText = """
        .PHONY: build

        VERSION := 1.4.0
        FLAGS:=-O2

        build:
        \tcc $(FLAGS) -o app main.c

        deploy:
        \t./scripts/deploy.sh
        """
        let repositoryRootPath = makeFixtureRepository(files: [
            ("Makefile", makefileText),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding != nil)
        guard let finding else { return }

        #expect(finding.commandsByField[.build] == RepoRecipeCommand(commandLine: "make build"))
        // Everything else stays unmapped.
        #expect(finding.commandsByField[.install] == nil)
        #expect(finding.commandsByField[.test] == nil)
        #expect(finding.commandsByField[.run] == nil)
        #expect(finding.commandsByField[.package] == nil)
    }

    // MARK: - Precedence: Makefile overrides the container command in a field

    @Test func aMakefileBuildTargetOverridesTheDockerfileBuildButLeavesRunToDocker() {
        let makefileText = """
        build:
        \tcargo build --release
        """
        let repositoryRootPath = makeFixtureRepository(files: [
            ("Dockerfile", "FROM rust:1.79\nCOPY . .\nRUN cargo build --release\n"),
            ("Makefile", makefileText),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding != nil)
        guard let finding else { return }

        // The Makefile `build` target (author-declared) overrides the
        // Dockerfile's generic `docker build`.
        #expect(finding.commandsByField[.build] == RepoRecipeCommand(commandLine: "make build"))
        #expect(finding.provenanceByField[.build] == .explicitProjectConfig)

        // The Makefile has no `run` target, so the container fallback still
        // owns `run` — proving the override is per-field, not wholesale.
        #expect(finding.commandsByField[.run]
            == RepoRecipeCommand(commandLine: "docker run --rm iris-local-image"))
        #expect(finding.provenanceByField[.run] == .genericEcosystemDefault)

        // A Makefile produced a command, so the finding advertises "make".
        #expect(finding.ecosystemIdentifier == "make")
    }

    // MARK: - Kubernetes manifest: scale signal, no command

    @Test func aKubernetesDeploymentManifestVotesBuiltForScaleWithNoCommand() {
        let deploymentYaml = """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web
        spec:
          replicas: 3
        """
        let repositoryRootPath = makeFixtureRepository(files: [
            ("k8s/deployment.yaml", deploymentYaml),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding != nil)
        guard let finding else { return }

        #expect(finding.matched == true)
        #expect(finding.runtimeShapeContribution == .builtForScale)
        #expect(finding.ecosystemIdentifier == "container/orchestration")
        // A manifest is a deploy artifact, not a local rebuild recipe, so it
        // contributes no runnable command.
        #expect(finding.commandsByField.isEmpty)
    }

    // MARK: - Serverless config: scale signal

    @Test func aVercelConfigWithFunctionsVotesBuiltForScale() {
        let vercelJson = """
        { "functions": { "api/hello.js": { "memory": 512 } } }
        """
        let repositoryRootPath = makeFixtureRepository(files: [
            ("vercel.json", vercelJson),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding != nil)
        #expect(finding?.runtimeShapeContribution == .builtForScale)
        #expect(finding?.commandsByField.isEmpty == true)
    }

    @Test func aWranglerConfigVotesBuiltForScale() {
        let repositoryRootPath = makeFixtureRepository(files: [
            ("wrangler.toml", "name = \"my-worker\"\nmain = \"src/index.ts\"\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding?.runtimeShapeContribution == .builtForScale)
    }

    // MARK: - Negative cases: nothing to say → nil

    @Test func aRepoWithNoContainerOrOrchestrationSignalsProducesNoFinding() {
        // A README and some source, but no Dockerfile / compose / Makefile /
        // manifest / serverless config: the container detector must stay silent
        // so a language detector, not this fallback, defines the recipe.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("README.md", "# My App\n"),
            ("src/main.swift", "print(\"hello\")\n"),
            ("package.json", "{ \"name\": \"my-app\" }\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding == nil)
    }

    @Test func aStaticVercelConfigWithoutFunctionsIsNotAScaleSignalAndProducesNoFinding() {
        // A plain static-site vercel.json (no `functions`) must NOT be treated
        // as serverless scale machinery — and with no other signal present, the
        // detector has nothing to say.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("vercel.json", "{ \"cleanUrls\": true, \"trailingSlash\": false }\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        let finding = RepoRecipeContainerDetector().detect(repoRootPath: repositoryRootPath)
        #expect(finding == nil)
    }
}

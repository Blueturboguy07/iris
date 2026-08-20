//
//  RepoRecipeGoDetectorTests.swift
//  leanring-buddyTests
//
//  Fixture-driven unit coverage for the Go recipe registry row (plan §10.1).
//  Each test builds a tiny real Go module in a temp directory and asserts the
//  detector resolves the uniform commands, the right per-field confidence and
//  provenance, and the correct two-axis runtime shape. Includes the required
//  negative case (not a Go repo → no match) and the multi-main CONFLICT case
//  (several cmd/* binaries → run confidence drops, build/test do not, and the
//  command is NOT silently narrowed to one binary). Pure logic + filesystem —
//  no processes, no network, nothing from the fixture is ever executed.
//

import Foundation
import Testing
@testable import Iris

@Suite struct RepoRecipeGoDetectorTests {

    // MARK: - Fixture helpers

    /// Materialize a throwaway Go module: write every (repo-relative path →
    /// contents) pair, creating intermediate directories, and return the repo
    /// root path. The caller removes it via `removeFixtureRepo`.
    static func makeFixtureRepo(files: [String: String]) throws -> String {
        let repoRootPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-go-detector-\(UUID().uuidString)")
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

    /// A minimal, valid go.mod for a module named `example.com/app`.
    static let minimalGoMod = """
    module example.com/app

    go 1.21
    """

    /// A root main that does NOT start a server — a plain Go CLI.
    static let plainCommandLineMainGo = """
    package main

    import "fmt"

    func main() {
        fmt.Println("hello")
    }
    """

    /// A root main that binds an HTTP listener via raw net/http.
    static let netHTTPServerMainGo = """
    package main

    import "net/http"

    func main() {
        http.ListenAndServe(":8080", nil)
    }
    """

    // MARK: - Positive: the uniform Go commands on a pure-local CLI

    @Test func aGoModuleWithARootMainResolvesTheUniformGoCommands() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "go.mod": Self.minimalGoMod,
            "main.go": Self.plainCommandLineMainGo,
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let finding = RepoRecipeGoDetector().detect(repoRootPath: repoRootPath)
        let unwrappedFinding = try #require(finding)

        #expect(unwrappedFinding.matched)
        #expect(unwrappedFinding.ecosystemIdentifier == "go/modules")

        // The three resolved commands, verbatim and run from the module root.
        #expect(unwrappedFinding.commandsByField[.build]?.commandLine == "go build ./...")
        #expect(unwrappedFinding.commandsByField[.test]?.commandLine == "go test ./...")
        #expect(unwrappedFinding.commandsByField[.run]?.commandLine == "go run .")
        #expect(unwrappedFinding.commandsByField[.build]?.workingSubdirectory == nil)
        #expect(unwrappedFinding.commandsByField[.test]?.workingSubdirectory == nil)
        #expect(unwrappedFinding.commandsByField[.run]?.workingSubdirectory == nil)

        // Go's uniform tooling has no install/package step here.
        #expect(unwrappedFinding.commandsByField[.install] == nil)
        #expect(unwrappedFinding.commandsByField[.package] == nil)

        // build/test are high-confidence; run is deliberately lower even with a
        // single clean entrypoint.
        #expect(unwrappedFinding.confidenceByField[.build] == 0.9)
        #expect(unwrappedFinding.confidenceByField[.test] == 0.9)
        #expect(unwrappedFinding.confidenceByField[.run] == 0.6)

        // Every field is honestly attributed to Go's ecosystem convention —
        // go.mod declares no scripts to lift, so nothing is explicit-config.
        #expect(unwrappedFinding.provenanceByField[.build] == .genericEcosystemDefault)
        #expect(unwrappedFinding.provenanceByField[.test] == .genericEcosystemDefault)
        #expect(unwrappedFinding.provenanceByField[.run] == .genericEcosystemDefault)

        // No server anywhere → pure-local.
        #expect(unwrappedFinding.runtimeShapeContribution == .pureLocalApp)
    }

    // MARK: - Negative: not a Go module

    @Test func aRepoWithoutAGoModIsNotDetectedAsGo() throws {
        // A Node repo, no go.mod anywhere → the detector must have nothing to
        // say (nil), so the merger skips the Go row entirely.
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "package.json": "{\"name\":\"not-go\"}",
            "index.js": "console.log('hi')",
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let finding = RepoRecipeGoDetector().detect(repoRootPath: repoRootPath)
        #expect(finding == nil)
    }

    // MARK: - Conflict: multiple cmd/* mains lower run confidence only

    @Test func multipleCommandMainsLowerRunConfidenceButNotBuildOrTest() throws {
        // The canonical Go multi-binary layout: two cmd/* mains and no root
        // main. `go run .` is ambiguous, so run confidence drops — but `./...`
        // still builds/tests every package unambiguously, so those stay high.
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "go.mod": Self.minimalGoMod,
            "cmd/server/main.go": Self.plainCommandLineMainGo,
            "cmd/worker/main.go": Self.plainCommandLineMainGo,
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let finding = RepoRecipeGoDetector().detect(repoRootPath: repoRootPath)
        let unwrappedFinding = try #require(finding)

        #expect(unwrappedFinding.matched)

        // The ambiguity shows up ONLY as lowered run confidence.
        #expect(unwrappedFinding.confidenceByField[.build] == 0.9)
        #expect(unwrappedFinding.confidenceByField[.test] == 0.9)
        #expect(unwrappedFinding.confidenceByField[.run] == 0.3)
        let runConfidence = try #require(unwrappedFinding.confidenceByField[.run])
        let buildConfidence = try #require(unwrappedFinding.confidenceByField[.build])
        #expect(runConfidence < buildConfidence)

        // Crucially, the command is NOT silently narrowed to one binary — it
        // stays `go run .` and the low confidence is what routes a §7
        // clarification ("which binary should I run?").
        #expect(unwrappedFinding.commandsByField[.run]?.commandLine == "go run .")
    }

    // MARK: - Runtime shape: server without machinery

    @Test func aNetHTTPServerWithoutScaleMachineryIsALocalSingleInstanceService() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "go.mod": Self.minimalGoMod,
            "main.go": Self.netHTTPServerMainGo,
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let finding = RepoRecipeGoDetector().detect(repoRootPath: repoRootPath)
        let unwrappedFinding = try #require(finding)

        // A listener but no Dockerfile/k8s → the self-hosted single-instance
        // service shape, not "built for scale".
        #expect(unwrappedFinding.runtimeShapeContribution == .localSingleInstanceService)
    }

    // MARK: - Runtime shape: a web-framework dependency counts as a server

    @Test func aWebFrameworkDependencyInGoModCountsAsAServer() throws {
        // The listener lives behind gin, so main.go has no raw ListenAndServe;
        // the go.mod dependency is what proves this serves HTTP.
        let ginGoMod = """
        module example.com/app

        go 1.21

        require github.com/gin-gonic/gin v1.9.1
        """
        let ginMainGo = """
        package main

        import "github.com/gin-gonic/gin"

        func main() {
            router := gin.Default()
            router.Run()
        }
        """
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "go.mod": ginGoMod,
            "main.go": ginMainGo,
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let finding = RepoRecipeGoDetector().detect(repoRootPath: repoRootPath)
        let unwrappedFinding = try #require(finding)

        #expect(unwrappedFinding.runtimeShapeContribution == .localSingleInstanceService)
    }

    // MARK: - Runtime shape: server + scale machinery

    @Test func aServerWithADockerfileExposeIsBuiltForScale() throws {
        let dockerfile = """
        FROM golang:1.21
        WORKDIR /app
        COPY . .
        RUN go build ./...
        EXPOSE 8080
        CMD ["/app/app"]
        """
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "go.mod": Self.minimalGoMod,
            "main.go": Self.netHTTPServerMainGo,
            "Dockerfile": dockerfile,
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let finding = RepoRecipeGoDetector().detect(repoRootPath: repoRootPath)
        let unwrappedFinding = try #require(finding)

        #expect(unwrappedFinding.runtimeShapeContribution == .builtForScale)
    }

    @Test func aServerWithKubernetesManifestsIsBuiltForScale() throws {
        let deploymentManifest = """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: app
        spec:
          replicas: 3
        """
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "go.mod": Self.minimalGoMod,
            "main.go": Self.netHTTPServerMainGo,
            // Writing under k8s/ makes the k8s directory signal present.
            "k8s/deployment.yaml": deploymentManifest,
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let finding = RepoRecipeGoDetector().detect(repoRootPath: repoRootPath)
        let unwrappedFinding = try #require(finding)

        #expect(unwrappedFinding.runtimeShapeContribution == .builtForScale)
    }

    // MARK: - A CLI shipped in a plain Dockerfile is still local (server-axis gate)

    @Test func aNonServerCLIWithAPlainDockerfileStaysPureLocal() throws {
        // A Dockerfile that only ships a binary (no EXPOSE) around a non-server
        // CLI must NOT be read as scaled — the server axis gates §8.
        let plainDockerfile = """
        FROM golang:1.21
        WORKDIR /app
        COPY . .
        RUN go build ./...
        CMD ["/app/app"]
        """
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "go.mod": Self.minimalGoMod,
            "main.go": Self.plainCommandLineMainGo,
            "Dockerfile": plainDockerfile,
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let finding = RepoRecipeGoDetector().detect(repoRootPath: repoRootPath)
        let unwrappedFinding = try #require(finding)

        #expect(unwrappedFinding.runtimeShapeContribution == .pureLocalApp)
    }

    // MARK: - A single cmd/* binary keeps the clear-entrypoint run confidence

    @Test func aSingleCommandMainKeepsTheClearEntrypointRunConfidence() throws {
        let repoRootPath = try Self.makeFixtureRepo(files: [
            "go.mod": Self.minimalGoMod,
            "cmd/app/main.go": Self.plainCommandLineMainGo,
        ])
        defer { Self.removeFixtureRepo(repoRootPath) }

        let finding = RepoRecipeGoDetector().detect(repoRootPath: repoRootPath)
        let unwrappedFinding = try #require(finding)

        // Exactly one discernible entrypoint → the higher (still sub-build) run
        // confidence, not the ambiguity floor.
        #expect(unwrappedFinding.confidenceByField[.run] == 0.6)
    }
}

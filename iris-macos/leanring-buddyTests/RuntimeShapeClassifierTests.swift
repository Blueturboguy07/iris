//
//  RuntimeShapeClassifierTests.swift
//  leanring-buddyTests
//
//  Fixture-driven coverage for the plan §8 runtime-shape classifier. Each case
//  materializes a real temp-dir repo, runs the two independent axes and the
//  collapsed classification against it, and asserts the shape plus, where it is
//  the point of the test, the individual axis bools.
//
//  The load-bearing test is the "dev-server-only app must NOT be builtForScale"
//  case (both a Next dev-only app and a Vite SPA): a local dev server is a
//  server-or-nothing, never scale machinery. Pure static inspection: no
//  processes, no network.
//

import Foundation
import Testing
@testable import Iris

@Suite struct RuntimeShapeClassifierTests {

    // MARK: - Temp-dir fixture helpers

    /// Create a throwaway repo directory containing exactly `files`
    /// (relativePath → contents) and return its absolute path. Each test removes
    /// it via `defer` so the fixtures never accumulate on disk.
    private func makeFixtureRepository(
        files: [(relativePath: String, contents: String)]
    ) -> String {
        let repositoryRootPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-runtime-shape-\(UUID().uuidString)")
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

    // MARK: - pureLocalApp: no server, no machinery

    @Test func aRustCommandLineToolIsPureLocalApp() {
        // A Cargo CLI (clap) with a plain main that only prints: no server
        // framework, no listen call, no deploy machinery at all.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("Cargo.toml", """
            [package]
            name = "tinytool"
            version = "0.1.0"

            [dependencies]
            clap = "4"
            """),
            ("src/main.rs", """
            use clap::Parser;

            fn main() {
                println!("hello from a local CLI");
            }
            """),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasServerComponent(repoRootPath: repositoryRootPath) == false)
        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == false)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .pureLocalApp)
    }

    @Test func aNativeDesktopAppWithNoServerAndNoMachineryIsPureLocalApp() {
        // The shape of a Tauri / SwiftUI clone: a build manifest and some source,
        // but nothing that binds a port and nothing that deploys.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("package.json", """
            { "name": "desktop-shell", "dependencies": { "react": "18.2.0" },
              "scripts": { "build": "vite build" } }
            """),
            ("src/main.tsx", "console.log(\"just a UI\")\n"),
            ("README.md", "# A desktop app\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .pureLocalApp)
    }

    // MARK: - localSingleInstanceService: server, no machinery

    @Test func aNextAppWithNoDeployMachineryIsLocalSingleInstanceService() {
        // deps declare `next` (a server), scripts are start/dev, and there is no
        // Dockerfile / compose / k8s — the self-hosted single-instance shape.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("package.json", """
            { "name": "webapp",
              "dependencies": { "next": "14.1.0", "react": "18.2.0" },
              "scripts": { "dev": "next dev", "build": "next build", "start": "next start" } }
            """),
            ("app/page.tsx", "export default function Page() { return null }\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasServerComponent(repoRootPath: repositoryRootPath) == true)
        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == false)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .localSingleInstanceService)
    }

    @Test func anExpressServerFromASourceListenCallIsLocalSingleInstanceService() {
        // No framework in an easily-parsed section (deps only lists express here,
        // but even a hand-rolled server should be caught): app.listen binds a
        // port in source, and a SINGLE-service compose file is NOT machinery.
        let singleServiceCompose = """
        services:
          web:
            build: .
            ports:
              - "3000:3000"
        """
        let repositoryRootPath = makeFixtureRepository(files: [
            ("package.json", """
            { "name": "api", "dependencies": { "express": "4.19.2" },
              "scripts": { "start": "node server.js" } }
            """),
            ("server.js", """
            const express = require("express");
            const app = express();
            app.get("/", (req, res) => res.send("ok"));
            app.listen(3000);
            """),
            ("docker-compose.yml", singleServiceCompose),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasServerComponent(repoRootPath: repositoryRootPath) == true)
        // A single-service compose file must NOT count as scale machinery.
        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == false)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .localSingleInstanceService)
    }

    @Test func aFlaskAppDeclaredInRequirementsIsLocalSingleInstanceService() {
        let repositoryRootPath = makeFixtureRepository(files: [
            ("requirements.txt", "flask==3.0.0\n"),
            ("app.py", """
            from flask import Flask
            app = Flask(__name__)

            @app.route("/")
            def index():
                return "hello"

            if __name__ == "__main__":
                app.run(port=5000)
            """),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasServerComponent(repoRootPath: repositoryRootPath) == true)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .localSingleInstanceService)
    }

    @Test func aDjangoAppWithManagePyButNoDeployMachineryIsLocalSingleInstanceService() {
        // manage.py alone is a server-runner signal; migrations WITHOUT a
        // DATABASE_URL must NOT tip it into builtForScale (the §8 pairing rule).
        let repositoryRootPath = makeFixtureRepository(files: [
            ("manage.py", "#!/usr/bin/env python\n# Django's manage.py\n"),
            ("myproject/settings.py", "DATABASES = {'default': {'ENGINE': 'sqlite3'}}\n"),
            ("myproject/migrations/0001_initial.py", "# generated migration\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasServerComponent(repoRootPath: repositoryRootPath) == true)
        // migrations/ is present, but no DATABASE_URL anywhere → not machinery.
        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == false)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .localSingleInstanceService)
    }

    @Test func aGoServiceWithAListenAndServeCallIsLocalSingleInstanceService() {
        let repositoryRootPath = makeFixtureRepository(files: [
            ("go.mod", "module example.com/svc\n\ngo 1.22\n"),
            ("main.go", """
            package main

            import "net/http"

            func main() {
                http.ListenAndServe(":8080", nil)
            }
            """),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasServerComponent(repoRootPath: repositoryRootPath) == true)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .localSingleInstanceService)
    }

    @Test func aRustAxumServiceIsDetectedAsAServer() {
        // axum is one of the plan's named Rust server frameworks; its presence in
        // Cargo.toml is enough for the server axis on its own.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("Cargo.toml", """
            [package]
            name = "svc"
            version = "0.1.0"

            [dependencies]
            axum = "0.7"
            tokio = { version = "1", features = ["full"] }
            """),
            ("src/main.rs", "fn main() { /* axum::serve elsewhere */ }\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasServerComponent(repoRootPath: repositoryRootPath) == true)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .localSingleInstanceService)
    }

    // MARK: - builtForScale: machinery present

    @Test func aNextAppWithADockerfileExposingAPortIsBuiltForScale() {
        let repositoryRootPath = makeFixtureRepository(files: [
            ("package.json", """
            { "name": "webapp", "dependencies": { "next": "14.1.0" },
              "scripts": { "start": "next start" } }
            """),
            ("Dockerfile", "FROM node:20\nWORKDIR /srv\nCOPY . .\nEXPOSE 3000\nCMD [\"npm\", \"start\"]\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasServerComponent(repoRootPath: repositoryRootPath) == true)
        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == true)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .builtForScale)
    }

    @Test func aMultiServiceComposeAppIsBuiltForScale() {
        let multiServiceCompose = """
        version: "3.9"
        services:
          web:
            build: .
          db:
            image: postgres:16
          cache:
            image: redis
        """
        let repositoryRootPath = makeFixtureRepository(files: [
            ("package.json", """
            { "name": "webapp", "dependencies": { "express": "4.19.2" },
              "scripts": { "start": "node server.js" } }
            """),
            ("compose.yaml", multiServiceCompose),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == true)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .builtForScale)
    }

    @Test func aKubernetesDeploymentManifestMakesItBuiltForScale() {
        let deploymentYaml = """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: web
        spec:
          replicas: 3
        """
        let repositoryRootPath = makeFixtureRepository(files: [
            ("package.json", """
            { "name": "webapp", "dependencies": { "fastify": "4.26.0" } }
            """),
            ("k8s/deployment.yaml", deploymentYaml),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == true)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .builtForScale)
    }

    @Test func aWranglerServerlessConfigMakesItBuiltForScale() {
        let repositoryRootPath = makeFixtureRepository(files: [
            ("package.json", "{ \"name\": \"worker\" }\n"),
            ("wrangler.toml", "name = \"my-worker\"\nmain = \"src/index.ts\"\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == true)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .builtForScale)
    }

    @Test func migrationsPairedWithAnExternalDatabaseUrlMakeItBuiltForScale() {
        // The §8 pairing satisfied: a migrations folder AND a DATABASE_URL in an
        // env template. Compare with the Django test above where the pairing is
        // NOT satisfied and the app stays a single instance.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("package.json", """
            { "name": "api", "dependencies": { "express": "4.19.2", "pg": "8.11.0" } }
            """),
            ("prisma/migrations/0001_init/migration.sql", "CREATE TABLE users ();\n"),
            (".env.example", "DATABASE_URL=postgres://user:pass@host:5432/db\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == true)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .builtForScale)
    }

    @Test func aDeclaredQueueBrokerClientMakesItBuiltForScale() {
        // Pushing work onto Kafka is a hallmark of a service designed to scale
        // past one process.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("package.json", """
            { "name": "worker",
              "dependencies": { "express": "4.19.2", "kafkajs": "2.2.4" } }
            """),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == true)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .builtForScale)
    }

    @Test func aKubernetesStyleHealthProbeEndpointInSourceMakesItBuiltForScale() {
        let repositoryRootPath = makeFixtureRepository(files: [
            ("go.mod", "module example.com/svc\n\ngo 1.22\n"),
            ("main.go", """
            package main

            import "net/http"

            func main() {
                http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {})
                http.ListenAndServe(":8080", nil)
            }
            """),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == true)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .builtForScale)
    }

    // MARK: - The load-bearing guard: a dev server alone is NOT builtForScale

    @Test func aNextDevServerOnlyAppIsNotBuiltForScale() {
        // The app has a server (next) and a DEV script, but zero deploy
        // machinery. It must land on localSingleInstanceService and must NEVER
        // be misclassified as builtForScale just because a dev server exists.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("package.json", """
            { "name": "webapp",
              "dependencies": { "next": "14.1.0", "react": "18.2.0" },
              "scripts": { "dev": "next dev" } }
            """),
            ("app/page.tsx", "export default function Page() { return null }\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == false)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) != .builtForScale)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .localSingleInstanceService)
    }

    @Test func aViteDevServerOnlyFrontendIsPureLocalAppAndNotBuiltForScale() {
        // A Vite SPA runs a dev server, but Vite is a bundler/dev-server, not an
        // HTTP-server framework — so the app has NO server component and NO
        // machinery. It must be pureLocalApp and, above all, not builtForScale.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("package.json", """
            { "name": "spa",
              "dependencies": { "react": "18.2.0" },
              "devDependencies": { "vite": "5.1.0" },
              "scripts": { "dev": "vite", "build": "vite build" } }
            """),
            ("src/main.tsx", "console.log(\"a static single-page app\")\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasServerComponent(repoRootPath: repositoryRootPath) == false)
        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == false)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) != .builtForScale)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .pureLocalApp)
    }

    // MARK: - Machinery-axis negatives

    @Test func aDockerfileWithNoExposedPortIsNotMachinery() {
        // A Dockerfile that only packages a binary (no EXPOSE) is not, on its
        // own, a scale signal — matching the plan's explicit rule.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("Cargo.toml", """
            [package]
            name = "tool"
            version = "0.1.0"
            """),
            ("Dockerfile", "FROM rust:1.79\nCOPY . .\nRUN cargo build --release\nCMD [\"./target/release/tool\"]\n"),
            ("src/main.rs", "fn main() { println!(\"cli\") }\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == false)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .pureLocalApp)
    }

    @Test func aSingleServiceComposeFileIsNotMachinery() {
        let singleServiceCompose = """
        services:
          app:
            build: .
            ports:
              - "8080:80"
        """
        let repositoryRootPath = makeFixtureRepository(files: [
            ("docker-compose.yml", singleServiceCompose),
            ("README.md", "# nginx-served static site\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == false)
    }

    @Test func aMigrationsFolderWithoutAnyDatabaseUrlIsNotMachinery() {
        // Migrations alone must not tip the scale axis — the pairing with an
        // externalized DATABASE_URL is required.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("package.json", "{ \"name\": \"cli-with-local-db\" }\n"),
            ("migrations/0001_init.sql", "CREATE TABLE t ();\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == false)
    }

    // MARK: - Empty / unknown repo

    @Test func aRepoWithNoRecognizableSignalsIsPureLocalApp() {
        // No manifest, no source we scan, no machinery: the classifier is
        // decisive and treats "nothing at all" as a pure local app rather than
        // guessing a server.
        let repositoryRootPath = makeFixtureRepository(files: [
            ("README.md", "# Just docs\n"),
            ("LICENSE", "MIT\n"),
        ])
        defer { removeFixtureRepository(repositoryRootPath) }

        #expect(RuntimeShapeClassifier.hasServerComponent(repoRootPath: repositoryRootPath) == false)
        #expect(RuntimeShapeClassifier.hasScaleOrDeployMachinery(repoRootPath: repositoryRootPath) == false)
        #expect(RuntimeShapeClassifier.classify(repoRootPath: repositoryRootPath) == .pureLocalApp)
    }
}

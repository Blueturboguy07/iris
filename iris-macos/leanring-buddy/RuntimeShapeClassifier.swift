//
//  RuntimeShapeClassifier.swift
//  leanring-buddy
//
//  The plan §8 runtime-shape classifier: given a clone on disk, decide whether
//  it is a pure local app, a local single-instance service, or a service built
//  for scale — so the agentic feature loop can apply the software-engineering
//  best practices appropriate to HOW the app runs (idempotency / tenancy /
//  migration style, §8 table) and so the required auto-commit rung is chosen
//  (ratified decision 5a: L2 for pure-local, L5 for anything with a
//  server/persistence/tenancy).
//
//  The classification is deliberately TWO INDEPENDENT AXES, scored separately by
//  pure static inspection, then collapsed:
//
//    Axis A — hasServerComponent:        does the app stand up an HTTP server /
//                                        bind a port (express/fastify/koa/next,
//                                        flask/django/fastapi, actix/axum,
//                                        Go net/http listen, …)?
//    Axis B — hasScaleOrDeployMachinery: does the repo carry real scale/deploy
//                                        machinery (Dockerfile EXPOSE+port,
//                                        multi-service compose, k8s/Helm,
//                                        serverless, migrations+DATABASE_URL,
//                                        health probes, queue/broker clients)?
//
//    (no server, no machinery)  → .pureLocalApp
//    (server,    no machinery)  → .localSingleInstanceService
//    (either,    machinery)     → .builtForScale
//
//  Keeping the two axes independent is what avoids the classic false positive
//  the plan calls out: a LOCAL DEV SERVER (`next dev` / `vite` / `flask run`) is
//  NOT scale machinery. The machinery axis keys only off DEPLOY artifacts, never
//  off a dev-server command, so a repo whose sole "server" evidence is a dev
//  script never climbs to `.builtForScale`.
//
//  Everything here is pure Foundation static inspection. Every read goes through
//  `RepoRecipeFiles` (repo-contained, size-capped) or the contained directory
//  listing below; nothing executes anything from the repo, and nothing touches
//  the network — the same invariant every detector in this subsystem holds.
//

import Foundation

nonisolated struct RuntimeShapeClassifier {

    // MARK: - Public API

    /// Classify how the clone at `repoRootPath` runs, per the plan §8 two-axis
    /// collapse. Decisive by construction: every (server, machinery) combination
    /// maps to exactly one of the three concrete shapes, so unlike an individual
    /// ecosystem detector (which abstains with `.unknown`) the classifier always
    /// commits to a shape — it is the component that MAKES the call by combining
    /// signals across the whole repo.
    static func classify(repoRootPath: String) -> RecipeRuntimeShape {
        let repoHasServerComponent = hasServerComponent(repoRootPath: repoRootPath)
        let repoHasScaleOrDeployMachinery = hasScaleOrDeployMachinery(repoRootPath: repoRootPath)

        // Machinery is the dominant axis: real deploy machinery means the app is
        // built to be operated as a scaled service regardless of whether the
        // static scan also spotted the server framework behind it.
        if repoHasScaleOrDeployMachinery {
            return .builtForScale
        }
        // No machinery: a server component means a single self-hosted instance
        // (the shape of most of this user's own clones — one webapp + one DB),
        // and no server at all means a native app / CLI / desktop shell.
        return repoHasServerComponent ? .localSingleInstanceService : .pureLocalApp
    }

    /// Axis A. True when the repo stands up an HTTP server / binds a port. Scored
    /// from author-declared dependencies first (the deterministic, high-signal
    /// path), then framework-runner files, then a bounded source scan for an
    /// explicit listen/serve call — so a raw `http.createServer().listen()` or a
    /// `ListenAndServe` behind no framework is still caught.
    static func hasServerComponent(repoRootPath: String) -> Bool {
        // 1. Node: an author-declared HTTP-server framework in package.json. Exact
        //    dependency-name membership (not substring) so "next" does not match
        //    unrelated names like "nextauth" and "koa" does not match "sokoban".
        if nodePackageDeclaresAServerFramework(repoRootPath: repoRootPath) {
            return true
        }

        // 2. Python: Django's manage.py and a WSGI/ASGI entry file are unambiguous
        //    server-runner signals even before any dependency is parsed.
        for pythonServerRunnerFile in Self.pythonServerRunnerFileNames {
            if RepoRecipeFiles.fileExists(pythonServerRunnerFile, underRepoRoot: repoRootPath) {
                return true
            }
        }

        // 3. Declared server frameworks in the NON-Node dependency manifests.
        //    These tokens (flask/django/fastapi, actix/axum, gin/echo/grpc, …)
        //    are matched as lowercased substrings — deliberately over the
        //    non-Node manifests only, so a Node package name that happens to
        //    contain a framework substring (say "@rocket.chat/..." vs Rust's
        //    "rocket") can never masquerade as a server. Node's own servers are
        //    already handled by the exact-match path in step 1.
        let nonNodeDependencyText = concatenatedManifestText(
            fromRelativePaths: Self.nonNodeDependencyManifestRelativePaths,
            repoRootPath: repoRootPath
        )
        let declaredServerFrameworkTokens =
            Self.pythonServerFrameworkTokens
            + Self.rustServerFrameworkTokens
            + Self.goWebFrameworkModulePaths
        for serverFrameworkToken in declaredServerFrameworkTokens {
            if nonNodeDependencyText.contains(serverFrameworkToken) {
                return true
            }
        }

        // 4. Source-level port binding: a listen/serve call in a conventional
        //    entry file, for the many servers whose framework is not declared as
        //    a dependency we recognize (a hand-rolled net/http or http server).
        if anySourceFileSatisfies(
            underRepoRoot: repoRootPath,
            predicate: Self.sourceTextStartsAnHTTPServer(_:fileExtension:)
        ) {
            return true
        }

        return false
    }

    /// Axis B. True when the repo carries real scale/deploy machinery — the §8
    /// signals. Ordered cheapest-first. Crucially, NONE of these keys off a
    /// dev-server command: a `next dev` / `vite` / `flask run` script is never
    /// machinery, which is the guard against the "a local dev server looks
    /// scaled" false positive the plan explicitly warns about.
    static func hasScaleOrDeployMachinery(repoRootPath: String) -> Bool {
        // A Dockerfile that EXPOSEs a port is a container built to LISTEN, not
        // merely to ship a binary — a deploy artifact. (A Dockerfile with no
        // EXPOSE is just packaging and is NOT, on its own, a scale signal.)
        if dockerfileExposesAPort(underRepoRoot: repoRootPath) {
            return true
        }

        // A compose file wiring together two or more services (app + db + cache)
        // is the "multi-service compose" scale signal. ONE service is not.
        if aComposeFileDeclaresMultipleServices(underRepoRoot: repoRootPath) {
            return true
        }

        // Kubernetes / Helm packaging: a manifest directory, a Helm chart, or a
        // deployment/HPA manifest kind.
        if declaresKubernetesOrHelmMachinery(underRepoRoot: repoRootPath) {
            return true
        }

        // Serverless / managed-platform deploy descriptors (Vercel functions,
        // Cloudflare Workers, Serverless Framework, AWS SAM, Fly, Render).
        if declaresServerlessOrManagedPlatformDeploy(underRepoRoot: repoRootPath) {
            return true
        }

        // Migrations AND an externalized DATABASE_URL, PAIRED. §8 pairs them on
        // purpose: frameworks ship a migrations/ folder even for single-user
        // local apps, so migrations ALONE is not a scale signal — it only counts
        // alongside a database URL pulled from the environment.
        if hasMigrationsPairedWithExternalDatabaseURL(underRepoRoot: repoRootPath) {
            return true
        }

        // A declared queue / message-broker client (BullMQ, Kafka, RabbitMQ,
        // Celery, …) — work is being pushed onto an external broker, a hallmark
        // of a service built to scale beyond one process.
        if declaresQueueOrMessageBrokerClient(repoRootPath: repoRootPath) {
            return true
        }

        // Kubernetes-idiomatic health-probe endpoints in source (/healthz,
        // /readyz, /livez) or probe fields in a manifest — the app is written to
        // be orchestrated / load-balanced.
        if declaresHealthProbeEndpoints(underRepoRoot: repoRootPath) {
            return true
        }

        return false
    }

    // MARK: - Axis A: server-framework signal tables

    /// Node HTTP-server frameworks, matched as EXACT package.json dependency
    /// names. `next` covers Next.js API routes (the plan's "next-api" signal):
    /// a project depending on `next` runs a server via `next start`/`next dev`.
    private static let nodeServerFrameworkDependencyNames: Set<String> = [
        "express", "fastify", "koa", "next",
        "@nestjs/core", "hapi", "@hapi/hapi",
        "restify", "sails", "hono", "h3", "polka",
        "@adonisjs/core", "@feathersjs/feathers",
    ]

    /// Python server / web frameworks and the WSGI/ASGI servers that host them.
    /// Distinctive lowercased substrings, safe to match over concatenated
    /// dependency text. flask/django/fastapi are the plan's named three; the
    /// rest are the common companions that equally prove "this serves HTTP".
    private static let pythonServerFrameworkTokens: [String] = [
        "flask", "django", "fastapi", "starlette",
        "aiohttp", "tornado", "sanic", "bottle", "falcon", "quart",
        "gunicorn", "uvicorn", "hypercorn", "waitress",
    ]

    /// Rust HTTP-server frameworks. actix/axum are the plan's named two; the
    /// rest are the other well-known server crates. `hyper` is intentionally
    /// EXCLUDED because it is equally the basis of HTTP *clients*, so depending
    /// on it does not prove the repo serves.
    private static let rustServerFrameworkTokens: [String] = [
        "actix-web", "actix", "axum", "rocket", "warp",
        "tide", "poem", "salvo", "ntex", "gotham", "tower-http",
    ]

    /// Go web-framework module paths. Importing one is an unambiguous "this
    /// serves HTTP" signal — you do not pull gin/echo/fiber/chi/grpc into a
    /// client — complementing the source-level `ListenAndServe` scan for the
    /// many services whose listener sits behind a framework call.
    private static let goWebFrameworkModulePaths: [String] = [
        "github.com/gin-gonic/gin",
        "github.com/labstack/echo",
        "github.com/gofiber/fiber",
        "github.com/go-chi/chi",
        "github.com/gorilla/mux",
        "github.com/valyala/fasthttp",
        "github.com/beego/beego",
        "github.com/astaxie/beego",
        "github.com/gobuffalo/buffalo",
        "google.golang.org/grpc",
    ]

    /// Python files whose mere presence at the repo root declares a server
    /// runner: Django's `manage.py`, and the WSGI/ASGI entry modules a
    /// production server is pointed at.
    private static let pythonServerRunnerFileNames: [String] = [
        "manage.py", "wsgi.py", "asgi.py",
    ]

    /// Does the root package.json declare an HTTP-server framework? Parsed
    /// safely (no eval) via `RepoRecipeFiles`; a missing/malformed manifest is
    /// simply "no server declared here".
    private static func nodePackageDeclaresAServerFramework(repoRootPath: String) -> Bool {
        guard let packageJSON = RepoRecipeFiles.jsonObject(
            atRelativePath: "package.json",
            underRepoRoot: repoRootPath
        ) else {
            return false
        }
        let declaredDependencyNames = nodeDependencyNames(inPackageJSON: packageJSON)
        return !declaredDependencyNames.isDisjoint(with: nodeServerFrameworkDependencyNames)
    }

    /// Merge the dependency-name keys from every package.json dependency section
    /// so a server framework is spotted regardless of which section declares it.
    /// Only the KEYS matter (a name's presence), so version strings are ignored.
    private static func nodeDependencyNames(inPackageJSON packageJSON: [String: Any]) -> Set<String> {
        let dependencySectionNames = [
            "dependencies", "devDependencies", "peerDependencies", "optionalDependencies",
        ]
        var allDependencyNames: Set<String> = []
        for sectionName in dependencySectionNames {
            if let section = packageJSON[sectionName] as? [String: Any] {
                allDependencyNames.formUnion(section.keys)
            }
        }
        return allDependencyNames
    }

    /// The source-level "binds a port / starts a server" signal, per file
    /// extension. We key off the SERVE/LISTEN call, not a bare import, because an
    /// import (e.g. Go's `net/http`, present in clients too) proves nothing about
    /// serving — the listen call is what actually opens a port.
    private static func sourceTextStartsAnHTTPServer(_ sourceText: String, fileExtension: String) -> Bool {
        switch fileExtension {
        case "go":
            // `ListenAndServe` also matches `ListenAndServeTLS` as a substring.
            return sourceText.contains("ListenAndServe") || sourceText.contains("http.Serve(")
        case "js", "mjs", "cjs", "ts", "tsx", "jsx":
            // app.listen(port) / server.listen(port) / http.createServer() and
            // the Bun/Deno serve entry points.
            return sourceText.contains(".listen(")
                || sourceText.contains("createServer(")
                || sourceText.contains("Bun.serve(")
                || sourceText.contains("Deno.serve(")
        case "py":
            // Flask's app.run(), uvicorn.run(), a wsgiref make_server(), or an
            // explicit host-bound run().
            return sourceText.contains("app.run(")
                || sourceText.contains("uvicorn.run(")
                || sourceText.contains("make_server(")
                || sourceText.contains("run(host=")
                || sourceText.contains("run(host =")
        case "rs":
            // actix-web's HttpServer::new and axum's Server / serve entry points.
            return sourceText.contains("HttpServer::new")
                || sourceText.contains("axum::Server")
                || sourceText.contains("axum::serve")
        default:
            return false
        }
    }

    // MARK: - Axis B: Dockerfile EXPOSE

    /// True when a root Dockerfile declares an EXPOSEd port — the §8 "Dockerfile
    /// EXPOSE+PORT" signal. Satisfied by a literal port (`EXPOSE 8080`) or a
    /// PORT-style variable (`EXPOSE $PORT`); a bare `EXPOSE` with no argument is
    /// not a served port and does not count.
    private static func dockerfileExposesAPort(underRepoRoot repoRootPath: String) -> Bool {
        guard let dockerfileText = RepoRecipeFiles.readText("Dockerfile", underRepoRoot: repoRootPath) else {
            return false
        }
        for rawLine in dockerfileText.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let upperCasedLine = trimmedLine.uppercased()
            guard upperCasedLine == "EXPOSE" || upperCasedLine.hasPrefix("EXPOSE ") else { continue }

            let exposeArgument = trimmedLine
                .dropFirst("EXPOSE".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if exposeArgument.contains(where: { $0.isNumber }) { return true }
            if exposeArgument.uppercased().contains("PORT") { return true }
        }
        return false
    }

    // MARK: - Axis B: multi-service compose

    /// The compose filenames Docker itself resolves. The first that exists is
    /// read so a repo carrying both a legacy and a modern name is not
    /// double-counted.
    private static let composeFileNamesInPreferenceOrder = [
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml",
    ]

    /// True when a compose file declares two or more services — the §8
    /// "multi-service compose" signal.
    private static func aComposeFileDeclaresMultipleServices(underRepoRoot repoRootPath: String) -> Bool {
        for composeFileName in composeFileNamesInPreferenceOrder {
            guard let composeText = RepoRecipeFiles.readText(composeFileName, underRepoRoot: repoRootPath) else {
                continue
            }
            if countTopLevelComposeServices(inComposeText: composeText) >= 2 {
                return true
            }
        }
        return false
    }

    /// Count the direct entries under a compose file's top-level `services:` key.
    /// A structural indentation scan, not a full YAML parse: locate the
    /// zero-indent `services:` line, then count the mapping keys at the first
    /// child indentation until the block ends (the next zero-indent key). This
    /// mirrors the container detector's counter so the two agree on what "a
    /// service" is.
    private static func countTopLevelComposeServices(inComposeText composeText: String) -> Int {
        let lines = composeText.components(separatedBy: .newlines)

        var indexOfServicesKey: Int? = nil
        for (lineIndex, line) in lines.enumerated() where leadingSpaceCount(ofLine: line) == 0 {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine == "services:" || trimmedLine.hasPrefix("services:") {
                indexOfServicesKey = lineIndex
                break
            }
        }
        guard let servicesKeyIndex = indexOfServicesKey else { return 0 }

        var serviceEntryCount = 0
        var indentationOfDirectChildren: Int? = nil
        var cursor = servicesKeyIndex + 1
        while cursor < lines.count {
            let line = lines[cursor]
            cursor += 1

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") { continue }

            let indentation = leadingSpaceCount(ofLine: line)
            // A zero-indent non-blank line is the NEXT top-level key: the
            // services block has ended.
            if indentation == 0 { break }

            // The first indented child fixes the indentation every direct service
            // entry shares; deeper lines are that service's own properties.
            if indentationOfDirectChildren == nil {
                indentationOfDirectChildren = indentation
            }
            if indentation == indentationOfDirectChildren, isYamlMappingKeyLine(trimmedLine) {
                serviceEntryCount += 1
            }
        }
        return serviceEntryCount
    }

    private static func leadingSpaceCount(ofLine line: String) -> Int {
        var spaceCount = 0
        for character in line {
            if character == " " { spaceCount += 1 } else { break }
        }
        return spaceCount
    }

    /// A compose service entry is a mapping key: an identifier followed by a
    /// colon (`web:`), not a list item (`- foo`) or a quoted scalar.
    private static func isYamlMappingKeyLine(_ trimmedLine: String) -> Bool {
        guard let colonIndex = trimmedLine.firstIndex(of: ":") else { return false }
        let keyName = String(trimmedLine[trimmedLine.startIndex..<colonIndex])
        guard !keyName.isEmpty else { return false }
        return keyName.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber
                    || character == "_" || character == "." || character == "-")
        }
    }

    // MARK: - Axis B: Kubernetes / Helm

    /// Directories / files whose presence declares Kubernetes or Helm packaging.
    private static let kubernetesOrHelmSignalPaths = [
        "k8s", "kubernetes", "helm", "charts", "Chart.yaml", ".helm",
    ]

    /// Conventional locations a Kubernetes workload manifest lives in. A bounded
    /// probe set (RepoRecipeFiles offers no enumeration by design), so this is a
    /// fallback for a repo that keeps a manifest without a dedicated k8s/ dir.
    private static let kubernetesManifestCandidatePaths = [
        "deployment.yaml", "deployment.yml",
        "k8s/deployment.yaml", "k8s/deployment.yml",
        "kubernetes/deployment.yaml", "kubernetes/deployment.yml",
        "deploy/deployment.yaml", "deploy/deployment.yml",
        "manifests/deployment.yaml", "manifests/deployment.yml",
        "k8s.yaml", "k8s.yml",
    ]

    /// Kubernetes workload kinds that mean "meant to be orchestrated / scaled".
    private static let kubernetesScaleWorkloadKinds: Set<String> = [
        "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "HorizontalPodAutoscaler",
    ]

    private static func declaresKubernetesOrHelmMachinery(underRepoRoot repoRootPath: String) -> Bool {
        for signalPath in kubernetesOrHelmSignalPaths {
            if RepoRecipeFiles.fileExists(signalPath, underRepoRoot: repoRootPath) {
                return true
            }
        }
        return anyManifestDeclaresAScaleWorkloadKind(underRepoRoot: repoRootPath)
    }

    /// True when a candidate manifest has a top-level `kind:` line naming a
    /// scaled Kubernetes workload. Line-scanned (not a raw substring match) so a
    /// `kind:` inside a comment or string does not falsely trip it.
    private static func anyManifestDeclaresAScaleWorkloadKind(underRepoRoot repoRootPath: String) -> Bool {
        for candidatePath in kubernetesManifestCandidatePaths {
            guard let contents = RepoRecipeFiles.readText(candidatePath, underRepoRoot: repoRootPath) else {
                continue
            }
            for rawLine in contents.components(separatedBy: .newlines) {
                let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmedLine.hasPrefix("kind:") else { continue }
                let declaredKind = trimmedLine
                    .dropFirst("kind:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if kubernetesScaleWorkloadKinds.contains(declaredKind) { return true }
            }
        }
        return false
    }

    // MARK: - Axis B: serverless / managed-platform deploy

    /// True when the repo carries a serverless-platform or managed-deploy config
    /// — the §8 "serverless config" signal, read generously to include the
    /// managed platforms that stand up a scaled service (Fly, Render). A plain
    /// static-site `vercel.json` (no `functions`) is intentionally NOT a signal.
    private static func declaresServerlessOrManagedPlatformDeploy(underRepoRoot repoRootPath: String) -> Bool {
        // Vercel / Now: only a `functions` field marks it as serverless; a bare
        // static-site config does not.
        for vercelConfigName in ["vercel.json", "now.json"] {
            if let vercelConfig = RepoRecipeFiles.jsonObject(
                atRelativePath: vercelConfigName, underRepoRoot: repoRootPath
            ), vercelConfig["functions"] != nil {
                return true
            }
        }

        // Cloudflare Workers.
        for wranglerConfigName in ["wrangler.toml", "wrangler.json", "wrangler.jsonc"] {
            if RepoRecipeFiles.fileExists(wranglerConfigName, underRepoRoot: repoRootPath) { return true }
        }

        // Serverless Framework.
        for serverlessConfigName in ["serverless.yml", "serverless.yaml"] {
            if RepoRecipeFiles.fileExists(serverlessConfigName, underRepoRoot: repoRootPath) { return true }
        }

        // AWS SAM: a samconfig, or a CloudFormation template carrying the
        // Serverless transform.
        if RepoRecipeFiles.fileExists("samconfig.toml", underRepoRoot: repoRootPath) { return true }
        for samTemplateName in ["template.yaml", "template.yml"] {
            if let samTemplate = RepoRecipeFiles.readText(samTemplateName, underRepoRoot: repoRootPath),
               samTemplate.contains("AWS::Serverless") {
                return true
            }
        }

        // Managed long-running-service platforms that deploy to scaled infra.
        for managedPlatformConfigName in ["fly.toml", "render.yaml"] {
            if RepoRecipeFiles.fileExists(managedPlatformConfigName, underRepoRoot: repoRootPath) { return true }
        }

        return false
    }

    // MARK: - Axis B: migrations paired with an externalized DATABASE_URL

    /// Files/directories that indicate a migration tool is in use.
    private static let migrationToolingSignalPaths = [
        "migrations",
        "prisma/migrations",
        "db/migrate",
        "database/migrations",
        "alembic",
        "alembic.ini",
        "src/migrations",
    ]

    /// Files that commonly reference an externalized `DATABASE_URL`. A concrete,
    /// bounded set (RepoRecipeFiles has no globbing) so the check stays
    /// deterministic and repo-confined.
    private static let databaseURLReferencingFileNames = [
        ".env.example", ".env.sample", ".env.template", ".env", ".env.local",
        "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml",
        "settings.py", "config.py", "prisma/schema.prisma", "config/database.yml",
    ]

    /// The §8 pairing: a migrations folder AND an externalized database URL. Both
    /// are required because a migrations folder alone ships with plenty of
    /// single-user local apps, so on its own it does not imply scale.
    private static func hasMigrationsPairedWithExternalDatabaseURL(underRepoRoot repoRootPath: String) -> Bool {
        let hasMigrationTooling = migrationToolingSignalPaths.contains { migrationSignalPath in
            RepoRecipeFiles.fileExists(migrationSignalPath, underRepoRoot: repoRootPath)
        }
        guard hasMigrationTooling else { return false }
        return repoReferencesExternalDatabaseURL(underRepoRoot: repoRootPath)
    }

    private static func repoReferencesExternalDatabaseURL(underRepoRoot repoRootPath: String) -> Bool {
        for candidateFileName in databaseURLReferencingFileNames {
            if let text = RepoRecipeFiles.readText(candidateFileName, underRepoRoot: repoRootPath),
               text.contains("DATABASE_URL") {
                return true
            }
        }
        // `dj-database-url` exists specifically to parse a DATABASE_URL env var,
        // so declaring it is itself an externalized-database signal.
        let allDependencyText = concatenatedManifestText(
            fromRelativePaths: Self.allDependencyManifestRelativePaths,
            repoRootPath: repoRootPath
        )
        return allDependencyText.contains("dj-database-url")
    }

    // MARK: - Axis B: queue / message-broker clients

    /// Distinctive lowercased tokens for queue / message-broker CLIENTS across
    /// ecosystems. Pushing work onto an external broker is a hallmark of a
    /// service designed to scale past a single process. Kept distinctive on
    /// purpose so a substring match over the concatenated manifest text does not
    /// misfire (e.g. `redis` alone is excluded — it is as often a plain local
    /// cache as a broker).
    private static let queueOrBrokerClientTokens: [String] = [
        // Node
        "bullmq", "bee-queue", "amqplib", "amqp-connection-manager",
        "kafkajs", "node-rdkafka", "@nestjs/microservices", "nats.ws", "nats.js",
        // Python
        "celery", "kombu", "aio-pika", "kafka-python", "confluent-kafka",
        "dramatiq", "faust-streaming", "pika",
        // Go
        "github.com/streadway/amqp", "github.com/rabbitmq/amqp091-go",
        "github.com/segmentio/kafka-go", "github.com/ibm/sarama",
        "github.com/shopify/sarama", "github.com/nats-io/nats.go",
        "github.com/hibiken/asynq",
        // Rust
        "lapin", "rdkafka", "amqprs",
        // Ruby
        "sidekiq", "resque",
    ]

    private static func declaresQueueOrMessageBrokerClient(repoRootPath: String) -> Bool {
        // Queue/broker client names ARE ecosystem-specific and distinctive
        // (kafkajs, celery, sarama, lapin, …), so matching over ALL manifests
        // including package.json is safe from cross-ecosystem noise.
        let allDependencyText = concatenatedManifestText(
            fromRelativePaths: Self.allDependencyManifestRelativePaths,
            repoRootPath: repoRootPath
        )
        return queueOrBrokerClientTokens.contains { brokerClientToken in
            allDependencyText.contains(brokerClientToken)
        }
    }

    // MARK: - Axis B: health-probe endpoints

    /// Kubernetes-idiomatic health-probe route names. These specific spellings
    /// (unlike a bare `/health`, which any local app might expose) strongly
    /// imply the app is written to be orchestrated / load-balanced.
    private static let healthProbeRouteLiterals = ["/healthz", "/readyz", "/livez"]

    /// Probe field names a Kubernetes manifest uses to declare liveness /
    /// readiness / startup checks.
    private static let kubernetesProbeFieldNames = ["livenessProbe", "readinessProbe", "startupProbe"]

    private static func declaresHealthProbeEndpoints(underRepoRoot repoRootPath: String) -> Bool {
        // A probe field in a candidate manifest is the most direct signal.
        for candidatePath in kubernetesManifestCandidatePaths {
            guard let contents = RepoRecipeFiles.readText(candidatePath, underRepoRoot: repoRootPath) else {
                continue
            }
            if kubernetesProbeFieldNames.contains(where: { contents.contains($0) }) {
                return true
            }
        }
        // Otherwise a k8s-idiomatic health route defined in source.
        return anySourceFileSatisfies(underRepoRoot: repoRootPath) { sourceText, _ in
            healthProbeRouteLiterals.contains { routeLiteral in sourceText.contains(routeLiteral) }
        }
    }

    // MARK: - Concatenated dependency-manifest text

    /// The NON-Node dependency manifests. Server-framework substring tokens are
    /// matched over THESE only (never package.json), so a Node package name can
    /// never coincidentally match a Rust/Python/Go framework substring — Node
    /// servers use the exact-match path instead.
    private static let nonNodeDependencyManifestRelativePaths = [
        "Cargo.toml",
        "go.mod",
        "requirements.txt",
        "requirements/base.txt",
        "requirements/prod.txt",
        "pyproject.toml",
        "Pipfile",
        "setup.py",
        "setup.cfg",
        "environment.yml",
        "Gemfile",
        "composer.json",
        "pom.xml",
        "build.gradle",
        "build.gradle.kts",
    ]

    /// Every dependency manifest INCLUDING package.json. Used for the ecosystem-
    /// specific, cross-safe queue/broker tokens and the dj-database-url check.
    private static let allDependencyManifestRelativePaths =
        ["package.json"] + nonNodeDependencyManifestRelativePaths

    /// The union of the named dependency manifests' text, lowercased, for
    /// case-insensitive substring token matching. Missing files are simply
    /// skipped (a missing manifest contributes nothing).
    private static func concatenatedManifestText(
        fromRelativePaths relativePaths: [String],
        repoRootPath: String
    ) -> String {
        var manifestTexts: [String] = []
        for manifestRelativePath in relativePaths {
            if let manifestText = RepoRecipeFiles.readText(manifestRelativePath, underRepoRoot: repoRootPath) {
                manifestTexts.append(manifestText)
            }
        }
        return manifestTexts.joined(separator: "\n").lowercased()
    }

    // MARK: - Bounded, contained source scan

    /// The conventional directories a project's entry / server source lives in.
    /// We scan each of these plus ONE level of their immediate subdirectories
    /// (so `cmd/server/main.go`, `src/api/index.ts`, `app/main/routes.py` are
    /// reached) — bounded, never a full recursive walk.
    private static let sourceScanBaseDirectories = [
        "", "src", "server", "app", "api", "backend",
        "cmd", "internal", "lib", "services", "pkg",
    ]

    /// Source file extensions worth reading for the server / health signals.
    private static let scannableSourceFileExtensions: Set<String> = [
        "go", "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "rs",
    ]

    /// Hard caps so the scan stays cheap and bounded even on a large clone.
    private static let maximumSourceDirectoriesScanned = 80
    private static let maximumSourceFilesScannedPerDirectory = 40

    /// Walk the bounded source-directory set and return true as soon as one
    /// source file's (text, extension) satisfies `predicate`. Read-only and
    /// repo-contained; nothing here executes anything from the repo.
    private static func anySourceFileSatisfies(
        underRepoRoot repoRootPath: String,
        predicate: (_ sourceText: String, _ fileExtension: String) -> Bool
    ) -> Bool {
        for repoRelativeDirectory in repoRelativeSourceDirectoriesToScan(underRepoRoot: repoRootPath) {
            let sourceFileNames = immediateSourceFileNames(
                inRepoRelativeDirectory: repoRelativeDirectory,
                underRepoRoot: repoRootPath
            )
            for sourceFileName in sourceFileNames.prefix(maximumSourceFilesScannedPerDirectory) {
                let repoRelativeFilePath = repoRelativeDirectory.isEmpty
                    ? sourceFileName
                    : "\(repoRelativeDirectory)/\(sourceFileName)"
                guard let sourceText = RepoRecipeFiles.readText(
                    repoRelativeFilePath, underRepoRoot: repoRootPath
                ) else { continue }

                let fileExtension = (sourceFileName as NSString).pathExtension.lowercased()
                if predicate(sourceText, fileExtension) {
                    return true
                }
            }
        }
        return false
    }

    /// The concrete, deduplicated, capped list of repo-relative directories the
    /// source scan visits: each base directory plus one level of its immediate
    /// subdirectories.
    private static func repoRelativeSourceDirectoriesToScan(underRepoRoot repoRootPath: String) -> [String] {
        var directoriesToScan: [String] = []
        var alreadyQueuedDirectories: Set<String> = []

        func enqueue(_ repoRelativeDirectory: String) {
            guard directoriesToScan.count < maximumSourceDirectoriesScanned else { return }
            guard !alreadyQueuedDirectories.contains(repoRelativeDirectory) else { return }
            alreadyQueuedDirectories.insert(repoRelativeDirectory)
            directoriesToScan.append(repoRelativeDirectory)
        }

        for baseDirectory in sourceScanBaseDirectories {
            enqueue(baseDirectory)
            for subdirectoryName in immediateSubdirectoryNames(
                inRepoRelativeDirectory: baseDirectory, underRepoRoot: repoRootPath
            ) {
                let repoRelativeSubdirectory = baseDirectory.isEmpty
                    ? subdirectoryName
                    : "\(baseDirectory)/\(subdirectoryName)"
                enqueue(repoRelativeSubdirectory)
            }
        }
        return directoriesToScan
    }

    // MARK: - Contained directory listing
    //
    // RepoRecipeFiles exposes guarded file reads but not directory enumeration,
    // and scanning source for a listen/serve call fundamentally needs to LIST a
    // directory. We enumerate through FileManager directly but keep the same
    // containment discipline RepoRecipeFiles enforces — every path is resolved
    // under the repo root and rejected if it escapes — so the classifier still
    // cannot walk out of the clone. The entry names we act on come from real
    // filesystem entries, not untrusted manifest text, so they carry no
    // traversal payload of their own. (Same pattern the Go detector uses.)

    /// Immediate child directory names of a repo-relative directory. Empty when
    /// the directory is absent, escapes the root, or is not a directory.
    private static func immediateSubdirectoryNames(
        inRepoRelativeDirectory repoRelativeDirectory: String,
        underRepoRoot repoRootPath: String
    ) -> [String] {
        guard let absoluteDirectoryPath = containedAbsoluteDirectoryPath(
            forRepoRelativeDirectory: repoRelativeDirectory, underRepoRoot: repoRootPath
        ) else { return [] }

        let fileManager = FileManager.default
        guard let childEntryNames = try? fileManager.contentsOfDirectory(atPath: absoluteDirectoryPath) else {
            return []
        }
        return childEntryNames.filter { childEntryName in
            let childPath = (absoluteDirectoryPath as NSString).appendingPathComponent(childEntryName)
            var childIsDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: childPath, isDirectory: &childIsDirectory)
                && childIsDirectory.boolValue
        }
    }

    /// Immediate scannable source file names of a repo-relative directory,
    /// sorted for deterministic scanning. Empty on any failure.
    private static func immediateSourceFileNames(
        inRepoRelativeDirectory repoRelativeDirectory: String,
        underRepoRoot repoRootPath: String
    ) -> [String] {
        guard let absoluteDirectoryPath = containedAbsoluteDirectoryPath(
            forRepoRelativeDirectory: repoRelativeDirectory, underRepoRoot: repoRootPath
        ) else { return [] }

        guard let childEntryNames = try? FileManager.default.contentsOfDirectory(
            atPath: absoluteDirectoryPath
        ) else { return [] }

        return childEntryNames
            .filter { childEntryName in
                let fileExtension = (childEntryName as NSString).pathExtension.lowercased()
                return scannableSourceFileExtensions.contains(fileExtension)
                    // Skip test files: a test helper's httptest server or a
                    // `/healthz` fixture must not masquerade as the app's own.
                    && !childEntryName.hasSuffix("_test.go")
                    && !childEntryName.hasSuffix(".test.ts")
                    && !childEntryName.hasSuffix(".test.js")
                    && !childEntryName.hasSuffix(".spec.ts")
                    && !childEntryName.hasSuffix(".spec.js")
            }
            .sorted()
    }

    /// Resolve a repo-relative directory to an absolute path, returning nil
    /// unless it exists, is a directory, AND is contained within the repo root.
    /// An empty relative path resolves to the root itself. Mirrors
    /// `RepoRecipeFiles`' containment check (which is private to that type).
    private static func containedAbsoluteDirectoryPath(
        forRepoRelativeDirectory repoRelativeDirectory: String,
        underRepoRoot repoRootPath: String
    ) -> String? {
        // An absolute relative-path is always a bug or an escape attempt.
        guard !repoRelativeDirectory.hasPrefix("/") else { return nil }

        let rootURL = URL(fileURLWithPath: repoRootPath).standardizedFileURL
        let candidateURL = repoRelativeDirectory.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(repoRelativeDirectory).standardizedFileURL

        // Compare against the root WITH a trailing slash so a sibling directory
        // sharing the root's name prefix cannot pass.
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidateURL.path == rootURL.path || candidateURL.path.hasPrefix(rootPrefix) else {
            return nil
        }

        var candidateIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: candidateURL.path, isDirectory: &candidateIsDirectory
        ), candidateIsDirectory.boolValue else { return nil }

        return candidateURL.path
    }
}

//
//  RepoRecipeGoDetector.swift
//  leanring-buddy
//
//  One row of the Feature Engine's data-driven recipe registry (plan §4): the
//  Go ecosystem. A `go.mod` at the repo root is the single Tier-0 signal that
//  identifies a Go module, and Go's tooling is famously uniform — `go build
//  ./...`, `go test ./...`, `go run .` are THE canonical commands for every
//  module regardless of its internal layout. That uniformity is why this
//  detector earns HIGH confidence on build/test even though it derives them
//  from an ecosystem convention rather than an author-declared script (go.mod
//  declares no build/test/run scripts of its own to lift verbatim).
//
//  Everything here is pure Foundation, static inspection only: it reads files
//  and lists directories under the repo root, never executes the repo's code,
//  and never touches the network — the invariant the whole detector protocol
//  rests on (RepoRecipe.swift). Command strings are BUILT here; they are
//  adjudicated, classifier-screened, and executed elsewhere (plan §5).
//

import Foundation

/// Derives a `RepoRecipe` finding for a Go module. See file header for why the
/// commands are uniform and why build/test are high-confidence while run is
/// deliberately lower.
nonisolated struct RepoRecipeGoDetector: EcosystemDetector {

    // MARK: - Registry identity

    /// Follows the "language/tooling" convention of the other registry rows
    /// (node/next, rust/tauri, swift/xcode). Go has one toolchain, so the
    /// tooling half is simply "modules" — the go.mod module system.
    let ecosystemIdentifier = "go/modules"

    // MARK: - Tuning constants (named so the confidence policy is auditable)

    /// The Tier-0 signal file. Its mere presence identifies a Go module; its
    /// contents are only mined for the runtime-shape web-framework hint.
    private static let goModuleManifestFileName = "go.mod"

    /// build and test run over `./...`, which compiles/tests every package in
    /// the module. Because that is correct for ANY Go layout, these earn high
    /// confidence — the uniform tooling makes the generic ecosystem default
    /// unusually reliable, which is the whole point of the Go row.
    private static let buildAndTestConfidence = 0.9

    /// run is always less certain than build/test: `./...` has no run analogue,
    /// so `go run .` launches the module ROOT, which is only right when the
    /// root is itself a `package main` and there is no competing binary. When
    /// the layout gives exactly one clear entrypoint we trust it this much —
    /// still below build/test on purpose.
    private static let runConfidenceWithAClearEntrypoint = 0.6

    /// When the layout is ambiguous — the canonical Go multi-binary repo with
    /// several `cmd/*` mains, or a library with no discernible main at all —
    /// run confidence drops to here so the merge surfaces a §7 clarification
    /// ("which binary should I run?") instead of the engine silently launching
    /// the wrong thing. The command STAYS `go run .`: we lower confidence
    /// rather than silently pick one cmd/*, per plan §4.
    private static let runConfidenceWhenTheEntrypointIsAmbiguous = 0.3

    /// A hard cap on how many `.go` files we read per directory while probing
    /// for `package main` / a server-start call. Real entrypoint directories
    /// hold a handful of files; the cap keeps a pathological repo from turning
    /// a static Tier-0 pass into a large read.
    private static let maximumGoSourceFilesScannedPerDirectory = 40

    /// The conventional directory Go projects put their multiple binaries in
    /// (`cmd/<name>/main.go`). Enumerating it is how we detect the multi-main
    /// ambiguity the run confidence keys off.
    private static let commandBinariesDirectoryName = "cmd"

    // MARK: - Detection entry point

    func detect(repoRootPath: String) -> EcosystemDetectorFinding? {
        // Without a go.mod this is not a Go module and the detector has nothing
        // whatsoever to say — return nil so the merger skips it entirely
        // (rather than a matched:false negative, which is for detectors that
        // want to record an explicit "considered and rejected" vote).
        guard RepoRecipeFiles.fileExists(
            Self.goModuleManifestFileName,
            underRepoRoot: repoRootPath
        ) else {
            return nil
        }

        // The manifest text is optional context: it may be unreadable (oversized
        // or non-UTF-8) yet the module is still perfectly buildable with the
        // uniform commands, so a nil read must not sink the whole finding. We
        // only mine it for the web-framework runtime-shape hint.
        let goModuleManifestText = RepoRecipeFiles.readText(
            Self.goModuleManifestFileName,
            underRepoRoot: repoRootPath
        ) ?? ""

        // build/test are the uniform, always-correct Go commands. They run from
        // the repo root (nil subdirectory) because `./...` is resolved relative
        // to the module root.
        let goBuildCommand = RepoRecipeCommand(commandLine: "go build ./...")
        let goTestCommand = RepoRecipeCommand(commandLine: "go test ./...")

        // run is the uncertain one. `go run .` is the honest default; how much
        // we trust it depends on the module's entrypoint layout.
        let goRunCommand = RepoRecipeCommand(commandLine: "go run .")

        let entrypointLayout = Self.inspectEntrypointLayout(repoRootPath: repoRootPath)
        let runConfidence = Self.runConfidence(forEntrypointLayout: entrypointLayout)

        let runtimeShape = Self.classifyRuntimeShape(
            goModuleManifestText: goModuleManifestText,
            entrypointLayout: entrypointLayout,
            repoRootPath: repoRootPath
        )

        return EcosystemDetectorFinding(
            ecosystemIdentifier: ecosystemIdentifier,
            commandsByField: [
                .build: goBuildCommand,
                .test: goTestCommand,
                .run: goRunCommand,
            ],
            confidenceByField: [
                .build: Self.buildAndTestConfidence,
                .test: Self.buildAndTestConfidence,
                .run: runConfidence,
            ],
            // Every field is a generic ecosystem default: go.mod carries no
            // author-declared scripts to lift, so the commands come from Go's
            // uniform convention. Recording this honestly keeps the provenance
            // audit trail truthful even though the confidence is high.
            provenanceByField: [
                .build: .genericEcosystemDefault,
                .test: .genericEcosystemDefault,
                .run: .genericEcosystemDefault,
            ],
            runtimeShapeContribution: runtimeShape,
            matched: true
        )
    }

    // MARK: - Run confidence from the entrypoint layout

    /// How much to trust `go run .`, derived from how many launchable `main`
    /// packages the module appears to have.
    private static func runConfidence(forEntrypointLayout layout: EntrypointLayout) -> Double {
        // Exactly one discernible main — either the root is `package main`, or
        // there is a single `cmd/*` binary and nothing at the root — means the
        // default launch target is unambiguous. Anything else is ambiguous:
        // several `cmd/*` mains (the canonical multi-binary repo, the case the
        // spec calls out), a root main competing with a cmd main, or no main we
        // could find at all (a library). All of those get the low confidence
        // that routes to a clarification.
        layout.totalNumberOfDiscernibleMainPackages == 1
            ? runConfidenceWithAClearEntrypoint
            : runConfidenceWhenTheEntrypointIsAmbiguous
    }

    // MARK: - Runtime-shape classification (plan §8, two-axis)

    /// Votes this detector's runtime shape from two independent axes: does the
    /// module have a server component, and (only if it does) does it carry
    /// scale/deploy machinery. The server axis GATES the classification — a
    /// non-server binary shipped in a container is still local, never "scaled"
    /// — which is exactly the §8 guard against a local tool looking scaled.
    private static func classifyRuntimeShape(
        goModuleManifestText: String,
        entrypointLayout: EntrypointLayout,
        repoRootPath: String
    ) -> RecipeRuntimeShape {
        let hasServerComponent =
            entrypointLayout.anyEntrypointStartsAnHTTPServer
            || goModuleDependsOnAWebFramework(goModuleManifestText: goModuleManifestText)

        guard hasServerComponent else {
            // No listener anywhere: a Go CLI, tool, or library. Per §8 the
            // machinery axis only matters once there is a server to scale.
            return .pureLocalApp
        }

        return repoDeclaresScaleMachinery(repoRootPath: repoRootPath)
            ? .builtForScale
            : .localSingleInstanceService
    }

    /// A server component inferred from the module's dependencies. Importing a
    /// Go web framework is an unambiguous "this serves HTTP" signal — you do
    /// not pull in gin/echo/fiber/chi for a client — so it complements the
    /// source-level `ListenAndServe` scan for the many services whose listener
    /// lives behind a framework call rather than raw net/http.
    private static func goModuleDependsOnAWebFramework(goModuleManifestText: String) -> Bool {
        let knownWebFrameworkModulePaths = [
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
        return knownWebFrameworkModulePaths.contains { frameworkModulePath in
            goModuleManifestText.contains(frameworkModulePath)
        }
    }

    /// Scale/deploy machinery, per the two signals the spec names (Dockerfile /
    /// k8s). Kept deliberately conservative so a plain local service is not
    /// mislabeled "built for scale".
    private static func repoDeclaresScaleMachinery(repoRootPath: String) -> Bool {
        // Signal 1: a Dockerfile that EXPOSEs a port — a container built to
        // LISTEN, not merely to ship a binary. A Dockerfile with no EXPOSE is
        // just packaging and does not, on its own, imply scale.
        if let dockerfileText = RepoRecipeFiles.readText("Dockerfile", underRepoRoot: repoRootPath),
           dockerfileText.contains("EXPOSE") {
            return true
        }

        // Signal 2: Kubernetes / Helm deployment machinery. Any of these
        // directories or a root-level deployment manifest is a strong "meant to
        // be orchestrated" tell.
        let kubernetesSignalPaths = [
            "k8s",
            "kubernetes",
            "helm",
            "charts",
            "deployment.yaml",
            "deployment.yml",
        ]
        return kubernetesSignalPaths.contains { signalPath in
            RepoRecipeFiles.fileExists(signalPath, underRepoRoot: repoRootPath)
        }
    }

    // MARK: - Entrypoint layout inspection

    /// A compact summary of how many launchable `main` packages the module has
    /// and whether any entrypoint starts an HTTP server. Everything the run
    /// confidence and the (source-level) server axis need in one value.
    private nonisolated struct EntrypointLayout {
        let repoRootIsAMainPackage: Bool
        let numberOfCommandDirectoryMainPackages: Int
        let anyEntrypointStartsAnHTTPServer: Bool

        /// Total launchable binaries we could discern. `go run .` is a safe
        /// default only when this is exactly 1.
        var totalNumberOfDiscernibleMainPackages: Int {
            (repoRootIsAMainPackage ? 1 : 0) + numberOfCommandDirectoryMainPackages
        }
    }

    /// Probe the module root and every `cmd/*` subdirectory for `package main`
    /// declarations and server-start calls. Bounded and read-only.
    private static func inspectEntrypointLayout(repoRootPath: String) -> EntrypointLayout {
        let repoRootScan = scanGoSourceDirectory(
            repoRelativeDirectory: "",
            underRepoRoot: repoRootPath
        )

        var numberOfCommandDirectoryMainPackages = 0
        var anyCommandBinaryStartsAnHTTPServer = false
        for commandSubdirectoryName in immediateSubdirectoryNames(
            inRepoRelativeDirectory: commandBinariesDirectoryName,
            underRepoRoot: repoRootPath
        ) {
            let commandBinaryScan = scanGoSourceDirectory(
                repoRelativeDirectory: "\(commandBinariesDirectoryName)/\(commandSubdirectoryName)",
                underRepoRoot: repoRootPath
            )
            if commandBinaryScan.declaresAMainPackage {
                numberOfCommandDirectoryMainPackages += 1
            }
            if commandBinaryScan.startsAnHTTPServer {
                anyCommandBinaryStartsAnHTTPServer = true
            }
        }

        return EntrypointLayout(
            repoRootIsAMainPackage: repoRootScan.declaresAMainPackage,
            numberOfCommandDirectoryMainPackages: numberOfCommandDirectoryMainPackages,
            anyEntrypointStartsAnHTTPServer:
                repoRootScan.startsAnHTTPServer || anyCommandBinaryStartsAnHTTPServer
        )
    }

    /// What one directory's `.go` files told us: whether any declares
    /// `package main`, and whether any starts an HTTP server.
    private nonisolated struct GoSourceDirectoryScan {
        let declaresAMainPackage: Bool
        let startsAnHTTPServer: Bool
    }

    /// Read up to the cap's worth of non-test `.go` files in one directory and
    /// aggregate the two signals we care about. Test files (`*_test.go`) are
    /// skipped so a test helper's `package main` or an httptest server can't
    /// masquerade as the app's real entrypoint/listener.
    private static func scanGoSourceDirectory(
        repoRelativeDirectory: String,
        underRepoRoot repoRootPath: String
    ) -> GoSourceDirectoryScan {
        var declaresAMainPackage = false
        var startsAnHTTPServer = false

        let goSourceFileNames = immediateGoSourceFileNames(
            inRepoRelativeDirectory: repoRelativeDirectory,
            underRepoRoot: repoRootPath
        )
        for goSourceFileName in goSourceFileNames.prefix(maximumGoSourceFilesScannedPerDirectory) {
            let repoRelativeFilePath = repoRelativeDirectory.isEmpty
                ? goSourceFileName
                : "\(repoRelativeDirectory)/\(goSourceFileName)"
            guard let goSourceText = RepoRecipeFiles.readText(
                repoRelativeFilePath,
                underRepoRoot: repoRootPath
            ) else { continue }

            if !declaresAMainPackage, textDeclaresGoMainPackage(goSourceText) {
                declaresAMainPackage = true
            }
            if !startsAnHTTPServer, textStartsAnHTTPServer(goSourceText) {
                startsAnHTTPServer = true
            }
            // Nothing more this directory can tell us once both are set.
            if declaresAMainPackage, startsAnHTTPServer { break }
        }

        return GoSourceDirectoryScan(
            declaresAMainPackage: declaresAMainPackage,
            startsAnHTTPServer: startsAnHTTPServer
        )
    }

    // MARK: - Pure text signals

    /// True when a Go source file's package clause is `package main` — i.e. the
    /// file belongs to a buildable command, not a library package. We scan line
    /// by line (comments and blank lines may precede the clause) and require a
    /// word boundary after "main" so `package mainutil` does not match.
    private static func textDeclaresGoMainPackage(_ goSourceText: String) -> Bool {
        for rawLine in goSourceText.split(separator: "\n", omittingEmptySubsequences: false) {
            // Convert to String first: trimmingCharacters(in:) is a Foundation
            // String method, not available on the Substring `split` yields.
            let trimmedLine = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard trimmedLine.hasPrefix("package main") else { continue }

            let remainderAfterClause = trimmedLine.dropFirst("package main".count)
            // A legal clause ends the line, or is followed by whitespace or a
            // line comment — anything else (a letter/digit) means a different
            // package name that merely starts with "main".
            if remainderAfterClause.isEmpty
                || remainderAfterClause.hasPrefix(" ")
                || remainderAfterClause.hasPrefix("\t")
                || remainderAfterClause.hasPrefix("//") {
                return true
            }
        }
        return false
    }

    /// True when a Go source file contains a call that BINDS an HTTP listener.
    /// We key off the server-start call, not the bare `net/http` import,
    /// because net/http is equally present in pure HTTP *clients* (http.Get,
    /// http.Client) — importing it proves nothing about serving. `ListenAndServe`
    /// also covers `ListenAndServeTLS` as a substring.
    private static func textStartsAnHTTPServer(_ goSourceText: String) -> Bool {
        goSourceText.contains("ListenAndServe") || goSourceText.contains("http.Serve(")
    }

    // MARK: - Contained directory listing

    // RepoRecipeFiles exposes guarded file reads but not directory enumeration,
    // and Go's `cmd/*` multi-binary detection fundamentally needs to LIST the
    // cmd directory. We enumerate through FileManager directly but keep the
    // same containment discipline RepoRecipeFiles enforces — every path is
    // resolved under the repo root and rejected if it escapes — so a detector
    // still cannot walk out of the clone. The subdirectory names we act on come
    // from real filesystem entries, not untrusted manifest text, so they carry
    // no traversal payload of their own.

    /// Immediate child directory names of a repo-relative directory. Empty when
    /// the directory is absent, escapes the root, or is not actually a
    /// directory.
    private static func immediateSubdirectoryNames(
        inRepoRelativeDirectory repoRelativeDirectory: String,
        underRepoRoot repoRootPath: String
    ) -> [String] {
        guard let absoluteDirectoryPath = containedAbsoluteDirectoryPath(
            forRepoRelativeDirectory: repoRelativeDirectory,
            underRepoRoot: repoRootPath
        ) else { return [] }

        let fileManager = FileManager.default
        guard let childEntryNames = try? fileManager.contentsOfDirectory(
            atPath: absoluteDirectoryPath
        ) else { return [] }

        return childEntryNames.filter { childEntryName in
            let childPath = (absoluteDirectoryPath as NSString)
                .appendingPathComponent(childEntryName)
            var childIsDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: childPath, isDirectory: &childIsDirectory)
                && childIsDirectory.boolValue
        }
    }

    /// Immediate non-test `.go` source file names of a repo-relative directory,
    /// sorted for deterministic scanning. Empty on any failure.
    private static func immediateGoSourceFileNames(
        inRepoRelativeDirectory repoRelativeDirectory: String,
        underRepoRoot repoRootPath: String
    ) -> [String] {
        guard let absoluteDirectoryPath = containedAbsoluteDirectoryPath(
            forRepoRelativeDirectory: repoRelativeDirectory,
            underRepoRoot: repoRootPath
        ) else { return [] }

        guard let childEntryNames = try? FileManager.default.contentsOfDirectory(
            atPath: absoluteDirectoryPath
        ) else { return [] }

        return childEntryNames
            .filter { $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") }
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
            atPath: candidateURL.path,
            isDirectory: &candidateIsDirectory
        ), candidateIsDirectory.boolValue else { return nil }

        return candidateURL.path
    }
}

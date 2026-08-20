//
//  RepoRecipeContainerDetector.swift
//  leanring-buddy
//
//  A LOWER-PRECEDENCE fallback `EcosystemDetector` (plan §4) for the container
//  and build-orchestration signals that sit *below* a language's own manifest:
//  a Dockerfile, a docker-compose file, and a Makefile. The language detectors
//  (node/next, rust/cargo, swift/xcode, python/uv, …) are meant to WIN the
//  language fields, so the commands this detector derives from a Dockerfile or
//  a compose file carry deliberately MODEST confidence — they are the recipe of
//  last resort, filling a field only when nothing more specific claimed it.
//
//  The one exception is a Makefile: a hand-written `build` / `test` / `run` /
//  `install` target is genuine AUTHOR-DECLARED intent, exactly like a
//  package.json script, so those map to `make <target>` at
//  `explicitProjectConfig` provenance (high precedence) and can legitimately
//  override a container command in the same field.
//
//  This detector also carries the §8 "built for scale" runtime-shape signals
//  that live in container / orchestration files — an EXPOSEd port, a
//  multi-service compose file, a Kubernetes Deployment manifest, or a
//  serverless config. It votes `.builtForScale` when it sees one and ABSTAINS
//  (`.unknown`) otherwise, so it never mislabels a pure-local app as scaled and
//  never overrides a language detector's own pure-local vote.
//
//  Pure Foundation, static inspection only. Every read goes through
//  `RepoRecipeFiles` (which enforces repo containment and size caps); nothing
//  here executes anything from the repo, and nothing touches the network.
//

import Foundation

nonisolated struct RepoRecipeContainerDetector: EcosystemDetector {

    init() {}

    /// Stable, low-priority protocol identity. A finding reports a more
    /// specific tag (see `resolvedEcosystemIdentifier`) describing which signal
    /// actually matched; this constant is only the detector's own name.
    let ecosystemIdentifier = "container"

    // MARK: - Tunable confidences and the throwaway local image tag

    /// A hand-written Makefile target is author-declared intent, so it is
    /// trusted like any other explicit project config — high enough to win a
    /// field, and paired with `.explicitProjectConfig` provenance so precedence
    /// is carried by the provenance rank, not by this number alone.
    private static let makefileTargetConfidence = 0.8

    /// A Dockerfile / compose command is a generic ecosystem default. Kept
    /// modest ON PURPOSE (well below a language detector's typical build/run
    /// confidence) so the language field is won by the language detector, not
    /// by this container fallback.
    private static let containerCommandConfidence = 0.35

    /// When BOTH a Dockerfile and a compose file want to own `run`, compose
    /// wins (it orchestrates the whole app) but the confidence drops below the
    /// solo value so the two-signal ambiguity is VISIBLE in the audit trail
    /// rather than silently resolved — the auditable-precedence rule of §4.
    private static let conflictingRunCommandConfidence = 0.2

    /// A local, throwaway image tag Iris uses to build and then run this repo's
    /// own Dockerfile. The SAME tag must appear in the build and the run
    /// command so the run launches the image the build produced.
    private static let localDockerImageTag = "iris-local-image"

    // MARK: - Detect

    func detect(repoRootPath: String) -> EcosystemDetectorFinding? {
        // Read every command-producing signal file up front; a nil result from
        // `RepoRecipeFiles` means "this signal is absent" (missing, escaping,
        // oversized, or unreadable all look identical, which is the safe read).
        let dockerfileText = RepoRecipeFiles.readText("Dockerfile", underRepoRoot: repoRootPath)
        let composeFile = Self.firstExistingComposeFile(underRepoRoot: repoRootPath)
        let makefileText = RepoRecipeFiles.readText("Makefile", underRepoRoot: repoRootPath)

        let dockerfilePresent = dockerfileText != nil
        let composePresent = composeFile != nil
        let makefilePresent = makefileText != nil

        // Scale-machinery signals contribute ONLY to the runtime-shape vote,
        // never to a command (deploying to k8s / Vercel is not a local rebuild).
        let dockerfileExposesAPort = dockerfileText.map(Self.dockerfileExposesAPort(inDockerfileText:)) ?? false
        let composeServiceCount = composeFile.map { Self.countComposeServices(inComposeText: $0.contents) } ?? 0
        let composeIsMultiService = composeServiceCount >= 2
        let kubernetesDeploymentPresent = Self.hasKubernetesDeploymentManifest(underRepoRoot: repoRootPath)
        let serverlessConfigPresent = Self.hasServerlessConfig(underRepoRoot: repoRootPath)

        let anyScaleSignalPresent =
            dockerfileExposesAPort
            || composeIsMultiService
            || kubernetesDeploymentPresent
            || serverlessConfigPresent

        // No container, orchestration, or scale signal at all → the detector
        // has nothing to say, so return nil (the protocol's "no opinion").
        guard dockerfilePresent || composePresent || makefilePresent || anyScaleSignalPresent else {
            return nil
        }

        var commandsByField: [RecipeField: RepoRecipeCommand] = [:]
        var confidenceByField: [RecipeField: Double] = [:]
        var provenanceByField: [RecipeField: RecipeSignalProvenance] = [:]

        // --- Lower-precedence tier: container commands ---

        // A Dockerfile gives an explicit build. It runs at the repo root (the
        // build context is `.`), so no working subdirectory.
        if dockerfilePresent {
            commandsByField[.build] = RepoRecipeCommand(
                commandLine: "docker build -t \(Self.localDockerImageTag) ."
            )
            confidenceByField[.build] = Self.containerCommandConfidence
            provenanceByField[.build] = .genericEcosystemDefault
        }

        // Resolve the `run` field. A compose file orchestrates the whole app,
        // so `docker compose up` supersedes a bare `docker run` — but when both
        // a Dockerfile and a compose file exist that is a genuine two-signal
        // conflict, so the winning command's confidence is lowered to surface
        // it instead of hiding a last-writer-wins pick.
        if composePresent {
            let runConfidence = dockerfilePresent
                ? Self.conflictingRunCommandConfidence
                : Self.containerCommandConfidence
            commandsByField[.run] = RepoRecipeCommand(commandLine: "docker compose up")
            confidenceByField[.run] = runConfidence
            provenanceByField[.run] = .genericEcosystemDefault
        } else if dockerfilePresent {
            commandsByField[.run] = RepoRecipeCommand(
                commandLine: "docker run --rm \(Self.localDockerImageTag)"
            )
            confidenceByField[.run] = Self.containerCommandConfidence
            provenanceByField[.run] = .genericEcosystemDefault
        }

        // --- Higher-precedence tier: Makefile targets (OVERRIDE) ---

        var makefileProducedAnyCommand = false
        if let makefileText {
            let makefileTargetNames = Self.makefileTargetNames(fromMakefileText: makefileText)
            // Only the four conventional lifecycle targets are mapped. A
            // target's ORIGINAL name is preserved in the command so `make Build`
            // still invokes exactly the target the author wrote.
            let conventionalTargetsByField: [(field: RecipeField, conventionalName: String)] = [
                (.install, "install"),
                (.build, "build"),
                (.test, "test"),
                (.run, "run"),
            ]
            for (field, conventionalName) in conventionalTargetsByField {
                guard let matchedTargetName = makefileTargetNames.first(where: {
                    $0.lowercased() == conventionalName
                }) else { continue }
                // A Makefile target is author-declared, so it OVERRIDES any
                // container command already sitting in this field. Provenance
                // and confidence rise accordingly.
                commandsByField[field] = RepoRecipeCommand(commandLine: "make \(matchedTargetName)")
                confidenceByField[field] = Self.makefileTargetConfidence
                provenanceByField[field] = .explicitProjectConfig
                makefileProducedAnyCommand = true
            }
        }

        // The container detector only ever raises the scale flag or abstains;
        // it never votes pure-local (that is the language / port detectors' job)
        // so a Dockerfile-with-a-Makefile utility repo is not mislabeled.
        let runtimeShapeContribution: RecipeRuntimeShape =
            anyScaleSignalPresent ? .builtForScale : .unknown

        return EcosystemDetectorFinding(
            ecosystemIdentifier: Self.resolvedEcosystemIdentifier(
                makefileProducedAnyCommand: makefileProducedAnyCommand,
                composePresent: composePresent,
                dockerfilePresent: dockerfilePresent
            ),
            commandsByField: commandsByField,
            confidenceByField: confidenceByField,
            provenanceByField: provenanceByField,
            runtimeShapeContribution: runtimeShapeContribution,
            matched: true
        )
    }

    // MARK: - Ecosystem tag reported by a finding

    /// Which specific signal this finding should advertise as the recipe's
    /// ecosystem. A Makefile that produced commands leads (it is the
    /// author-declared recipe); otherwise the container files; and a finding
    /// carrying ONLY scale machinery (k8s / serverless, no runnable command)
    /// reports the generic orchestration tag.
    private static func resolvedEcosystemIdentifier(
        makefileProducedAnyCommand: Bool,
        composePresent: Bool,
        dockerfilePresent: Bool
    ) -> String {
        if makefileProducedAnyCommand { return "make" }
        if composePresent { return "docker/compose" }
        if dockerfilePresent { return "docker" }
        return "container/orchestration"
    }

    // MARK: - Compose file location

    /// The compose filenames Docker itself resolves, in the order it prefers
    /// them. The first that exists wins so a repo carrying both the legacy
    /// `docker-compose.yml` and the modern `compose.yaml` is read once, not
    /// double-counted.
    private static let composeFileNamesInPreferenceOrder = [
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml",
    ]

    private static func firstExistingComposeFile(
        underRepoRoot repoRootPath: String
    ) -> (fileName: String, contents: String)? {
        for candidateFileName in composeFileNamesInPreferenceOrder {
            if let contents = RepoRecipeFiles.readText(candidateFileName, underRepoRoot: repoRootPath) {
                return (candidateFileName, contents)
            }
        }
        return nil
    }

    // MARK: - Makefile parsing

    /// Extract the ordered list of runnable target names from a Makefile,
    /// implementing the `^[A-Za-z0-9_.-]+:` rule from the spec directly (no
    /// regex engine, so it stays pure and obvious). Recipe lines are indented
    /// with a tab and are skipped; `.PHONY`-style directives and `NAME :=`
    /// variable assignments are excluded because neither is a target you can
    /// `make`.
    private static func makefileTargetNames(fromMakefileText makefileText: String) -> [String] {
        var targetNames: [String] = []
        for rawLine in makefileText.components(separatedBy: .newlines) {
            // A real target starts at column zero. Anything indented (a recipe
            // body), blank, or a comment cannot be a target line.
            guard let firstCharacter = rawLine.first else { continue }
            if firstCharacter == " " || firstCharacter == "\t" || firstCharacter == "#" { continue }

            guard let colonIndex = rawLine.firstIndex(of: ":") else { continue }
            let candidateTargetName = String(rawLine[rawLine.startIndex..<colonIndex])
            guard !candidateTargetName.isEmpty,
                  candidateTargetName.allSatisfy(isMakefileTargetNameCharacter(_:))
            else { continue }

            // `NAME := value` is a variable assignment, not a target: the
            // character immediately after the colon is `=`.
            let indexAfterColon = rawLine.index(after: colonIndex)
            if indexAfterColon < rawLine.endIndex, rawLine[indexAfterColon] == "=" { continue }

            // `.PHONY`, `.DEFAULT`, `.SUFFIXES`, … are directives, not runnable
            // targets, and every one begins with a dot.
            if candidateTargetName.hasPrefix(".") { continue }

            targetNames.append(candidateTargetName)
        }
        return targetNames
    }

    /// The `[A-Za-z0-9_.-]` character class from the target-name rule, ASCII
    /// only so it matches the spec exactly rather than admitting arbitrary
    /// Unicode letters. Reused by the compose mapping-key check below.
    private static func isMakefileTargetNameCharacter(_ character: Character) -> Bool {
        return character.isASCII
            && (character.isLetter || character.isNumber
                || character == "_" || character == "." || character == "-")
    }

    // MARK: - Dockerfile EXPOSE (scale signal)

    /// True when the Dockerfile declares an EXPOSEd port — the §8 "Dockerfile
    /// w/ EXPOSE+PORT" scale signal. Satisfied by a literal port number
    /// (`EXPOSE 8080`) or a PORT-style variable reference (`EXPOSE $PORT`).
    private static func dockerfileExposesAPort(inDockerfileText dockerfileText: String) -> Bool {
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

    // MARK: - Compose service counting (scale signal)

    /// Count the direct entries under a compose file's top-level `services:`
    /// key. A structural scan, not a full YAML parse: it locates the
    /// zero-indent `services:` line, then counts the mapping keys at the first
    /// child indentation until the block ends (the next zero-indent key). Two
    /// or more services is the §8 "multi-service compose" scale signal.
    private static func countComposeServices(inComposeText composeText: String) -> Int {
        let lines = composeText.components(separatedBy: .newlines)

        // Locate the top-level `services:` key (must be at zero indentation so
        // a nested `services:` under some other block is not mistaken for it).
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

            // The first indented child fixes the indentation every direct
            // service entry shares; deeper lines are that service's own
            // properties (image:, ports:, …) and must not be counted.
            if indentationOfDirectChildren == nil {
                indentationOfDirectChildren = indentation
            }
            if indentation == indentationOfDirectChildren, isComposeMappingKeyLine(trimmedLine) {
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
    /// colon (`web:` or `web: {}`). A list item (`- foo`) or a quoted scalar is
    /// not, so those are excluded from the service count.
    private static func isComposeMappingKeyLine(_ trimmedLine: String) -> Bool {
        guard let colonIndex = trimmedLine.firstIndex(of: ":") else { return false }
        let keyName = String(trimmedLine[trimmedLine.startIndex..<colonIndex])
        guard !keyName.isEmpty else { return false }
        return keyName.allSatisfy(isMakefileTargetNameCharacter(_:))
    }

    // MARK: - Kubernetes Deployment manifest (scale signal)

    /// Conventional locations a Kubernetes Deployment manifest lives in. We
    /// probe a bounded set rather than walking the tree because the detector's
    /// only sanctioned file surface (`RepoRecipeFiles`) is read-only and
    /// path-checked by design and offers no enumeration — a deliberate safety
    /// tradeoff, so this is a fallback scale signal, not an exhaustive scan.
    private static let kubernetesManifestCandidatePaths = [
        "deployment.yaml", "deployment.yml",
        "k8s/deployment.yaml", "k8s/deployment.yml",
        "kubernetes/deployment.yaml", "kubernetes/deployment.yml",
        "deploy/deployment.yaml", "deploy/deployment.yml",
        "manifests/deployment.yaml", "manifests/deployment.yml",
        "k8s.yaml", "k8s.yml",
    ]

    private static func hasKubernetesDeploymentManifest(underRepoRoot repoRootPath: String) -> Bool {
        for candidatePath in kubernetesManifestCandidatePaths {
            guard let contents = RepoRecipeFiles.readText(candidatePath, underRepoRoot: repoRootPath) else { continue }
            if yamlDeclaresKind("Deployment", inYamlText: contents) { return true }
        }
        return false
    }

    /// True when a YAML document has a top-level `kind: <kind>` line — the
    /// standard Kubernetes resource discriminator. Line-scanned (not a raw
    /// substring match) so a `kind:` inside a comment or string does not
    /// falsely trip it.
    private static func yamlDeclaresKind(_ kind: String, inYamlText yamlText: String) -> Bool {
        for rawLine in yamlText.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.hasPrefix("kind:") else { continue }
            let declaredKind = trimmedLine
                .dropFirst("kind:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if declaredKind == kind { return true }
        }
        return false
    }

    // MARK: - Serverless config (scale signal)

    /// True when the repo carries a serverless-platform config — the §8
    /// "serverless config" scale signal. A plain static-site `vercel.json`
    /// (with no `functions`) is intentionally NOT a scale signal.
    private static func hasServerlessConfig(underRepoRoot repoRootPath: String) -> Bool {
        // Vercel / Now: only a `functions` field marks it as serverless.
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

        return false
    }
}

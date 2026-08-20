//
//  RepoRecipeService.swift
//  leanring-buddy
//
//  The Feature Engine's recipe-derivation front door (plan §4/§5): the single
//  entry point that replaces the coarse, catalog-declared
//  `BreakAppStack → VerificationCommands` lookup with a per-repo `RepoRecipe`
//  DERIVED by reading the actual clone. It runs every ecosystem detector in this
//  build, mines `.github/workflows/*.yml` for CI `run:` steps, and MERGES all of
//  those signals per field by trust precedence — so the recipe a consumer later
//  runs is code-adjudicated from declarative signals, never model-authored, and
//  every winning command is auditable back to the signal (and provenance) that
//  produced it.
//
//  Everything here is pure Foundation static inspection: it only reads files
//  (through `RepoRecipeFiles`, or a contained directory listing for the fixed
//  `.github/workflows` folder), never executes anything from the repo, and never
//  touches the network — the same invariant every detector holds. The command
//  strings are only BUILT and SELECTED here; they are classifier-screened and
//  executed elsewhere, behind staged consent (plan §5).
//
//  Merge semantics (the load-bearing logic, mirroring every build-detection tool
//  the plan surveyed):
//    - Per field, gather every detector's command plus any CI `run:` command.
//    - The winner is the candidate with the HIGHEST-TRUST provenance
//      (explicitProjectConfig > ciWorkflowStep > frameworkRegistryDefault >
//      genericEcosystemDefault > sandboxedTrial > unknown, i.e. the lowest
//      `RecipeSignalProvenance.trustRank`); ties are broken by higher confidence,
//      then by detector order (stable).
//    - When candidates DISAGREE on the command (a genuine conflict — two
//      lockfiles, a Makefile vs. a framework default, a CI step vs. a generic
//      default), the winner is kept but the merged confidence is LOWERED so the
//      ambiguity surfaces to the clarification layer (plan §7) instead of being
//      hidden by a silent last-writer-wins pick.
//

import Foundation

nonisolated enum RepoRecipeService {

    // MARK: - The detector registry

    /// Every ecosystem detector this build ships, in precedence order: the
    /// language detectors first (they should WIN their language's fields), and
    /// the container/orchestration detector last as the deliberate fallback
    /// (plan §4 — its Dockerfile/compose commands are the recipe of last resort,
    /// though its Makefile targets are author-declared and carry high provenance).
    ///
    /// `nonisolated(unsafe)` is honest and sufficient here: the array is a `let`
    /// that is never reassigned and each detector is a stateless value type, so
    /// there is no shared mutable state to protect — the annotation only tells
    /// the Swift 6 checker what the immutability already guarantees. Adding a
    /// stack is one row here plus its detector file, not a rewrite (plan §4's
    /// data-driven registry).
    nonisolated(unsafe) static let allDetectors: [EcosystemDetector] = [
        RepoRecipeNodeWebDetector(),
        RepoRecipeRustTauriDetector(),
        RepoRecipeSwiftAppleDetector(),
        RepoRecipePythonDetector(),
        RepoRecipeGoDetector(),
        RepoRecipeContainerDetector(),
    ]

    // MARK: - Tunable merge constants

    /// The confidence assigned to a command lifted from a CI `run:` step. A CI
    /// step is human-authored AND CI-verified, so it ranks above every guessed
    /// default (its `ciWorkflowStep` provenance sits just below an authored
    /// manifest script); this value places it firmly in the "trusted" band while
    /// still leaving a real authored script (typically ≥ 0.85) able to win a
    /// same-provenance-tier comparison it never reaches (CI is a lower tier).
    private static let ciWorkflowStepConfidence = 0.8

    /// When the candidates for one field DISAGREE on the actual command, the
    /// winning command is still selected by precedence but its confidence is
    /// multiplied by this factor, so a genuine conflict reads as lower-confidence
    /// and routes to a clarification (plan §4/§7) rather than being silently
    /// resolved. 0.5 matches the multi-lockfile penalty the Node detector already
    /// applies, keeping the whole subsystem's "ambiguity halves confidence" rule
    /// consistent.
    private static let conflictConfidencePenaltyMultiplier = 0.5

    // MARK: - Public API

    /// Derive the full per-repo `RepoRecipe` for the clone at `repoRootPath` by
    /// running every detector, mining CI workflows, and merging by precedence.
    /// The runtime shape comes from `RuntimeShapeClassifier.classify` (the
    /// decisive whole-repo component, not any single detector's abstaining vote).
    /// A field no signal resolved is left `nil` — an honest "unresolved" that the
    /// clarification path (plan §7) picks up, never a fabricated guess.
    static func deriveRecipe(repoRootPath: String) -> RepoRecipe {
        // 1. Run every detector; keep only the findings that actually MATCHED.
        //    A `matched: false` finding is an explicit negative whose commands
        //    the merge must ignore, and a nil result is "no opinion" — both are
        //    dropped here so only real signals reach the merge.
        let matchedFindings: [EcosystemDetectorFinding] = allDetectors.compactMap { detector in
            guard let finding = detector.detect(repoRootPath: repoRootPath), finding.matched else {
                return nil
            }
            return finding
        }

        // 2. Mine `.github/workflows/*.yml` `run:` steps into per-field candidates
        //    at `ciWorkflowStep` provenance — the plan's "CI step is a
        //    CI-verified recipe that outranks guessed defaults" signal.
        let ciWorkflowCandidatesByField = mineCIWorkflowRunStepCandidates(repoRootPath: repoRootPath)

        // 3. Merge each field independently by trust precedence.
        var mergedCommandByField: [RecipeField: RepoRecipeCommand] = [:]
        var mergedConfidenceByField: [RecipeField: Double] = [:]
        var mergedProvenanceByField: [RecipeField: RecipeSignalProvenance] = [:]

        for field in RecipeField.allCases {
            var candidatesForField: [FieldCandidate] = []

            // Detector candidates, in registry order (so ties stay stable).
            for finding in matchedFindings {
                guard let command = finding.commandsByField[field] else { continue }
                candidatesForField.append(
                    FieldCandidate(
                        command: command,
                        confidence: finding.confidenceByField[field] ?? 0.0,
                        provenance: finding.provenanceByField[field] ?? .unknown
                    )
                )
            }

            // The CI candidate (if any) is appended last; precedence, not order,
            // decides whether it wins.
            if let ciCandidate = ciWorkflowCandidatesByField[field] {
                candidatesForField.append(ciCandidate)
            }

            guard let resolution = resolveField(fromCandidates: candidatesForField) else { continue }
            mergedCommandByField[field] = resolution.command
            mergedConfidenceByField[field] = resolution.confidence
            mergedProvenanceByField[field] = resolution.provenance
        }

        // 4. Runtime shape from the decisive whole-repo classifier (plan §8).
        let runtimeShape = RuntimeShapeClassifier.classify(repoRootPath: repoRootPath)

        // 5. The ecosystem tag comes from the matched finding with the strongest
        //    headline signal (see `chooseEcosystemIdentifier`); "unknown" when no
        //    detector matched at all.
        let ecosystemIdentifier = chooseEcosystemIdentifier(fromMatchedFindings: matchedFindings)

        return RepoRecipe(
            install: mergedCommandByField[.install],
            build: mergedCommandByField[.build],
            test: mergedCommandByField[.test],
            run: mergedCommandByField[.run],
            package: mergedCommandByField[.package],
            ecosystemIdentifier: ecosystemIdentifier,
            runtimeShape: runtimeShape,
            confidenceByField: mergedConfidenceByField,
            provenanceByField: mergedProvenanceByField
        )
    }

    /// The gate that replaces today's hard `stackHasARealRebuildRecipe()` refusal
    /// (plan §4). True when the derived recipe has EITHER a build or an install
    /// command — interpreted stacks (Python, plain Node) are install-but-no-build
    /// and are perfectly rebuildable — which is exactly `RepoRecipe`'s own
    /// `hasABuildableRecipe`. A false result no longer hard-refuses; it routes to
    /// the clarification path (plan §7).
    static func hasBuildableRecipe(repoRootPath: String) -> Bool {
        deriveRecipe(repoRootPath: repoRootPath).hasABuildableRecipe
    }

    // MARK: - Per-field merge

    /// One candidate command for a single recipe field, from a detector or a CI
    /// `run:` step, carrying everything the merge needs to rank it.
    private struct FieldCandidate {
        let command: RepoRecipeCommand
        let confidence: Double
        let provenance: RecipeSignalProvenance
    }

    /// The resolved winner for one field.
    private struct FieldResolution {
        let command: RepoRecipeCommand
        let confidence: Double
        let provenance: RecipeSignalProvenance
    }

    /// Choose the winning command for one field from its candidates.
    ///
    /// Precedence: the candidate with the lowest `provenance.trustRank` (most
    /// trusted signal) wins; a tie on provenance is broken by higher confidence;
    /// a further tie keeps the first-seen candidate (registry order), so the
    /// result is deterministic. When the candidates DISAGREE on the command line
    /// the winner is kept but its confidence is penalized — the plan's rule to
    /// "lower the confidence and surface the ambiguity" instead of hiding a
    /// last-writer-wins pick. Corroborating candidates that name the SAME command
    /// are not a conflict and leave confidence untouched.
    private static func resolveField(fromCandidates candidates: [FieldCandidate]) -> FieldResolution? {
        guard !candidates.isEmpty else { return nil }

        var winnerIndex = 0
        for candidateIndex in 1..<candidates.count {
            let candidate = candidates[candidateIndex]
            let currentWinner = candidates[winnerIndex]

            let candidateIsMoreTrusted =
                candidate.provenance.trustRank < currentWinner.provenance.trustRank
            let candidateTiesButIsMoreConfident =
                candidate.provenance.trustRank == currentWinner.provenance.trustRank
                && candidate.confidence > currentWinner.confidence

            if candidateIsMoreTrusted || candidateTiesButIsMoreConfident {
                winnerIndex = candidateIndex
            }
        }

        let winner = candidates[winnerIndex]

        // A conflict exists when any candidate proposes a DIFFERENT command line
        // than the winner's. Two detectors emitting the identical command is
        // corroboration, not conflict.
        let candidatesDisagreeOnCommand = candidates.contains { candidate in
            candidate.command.commandLine != winner.command.commandLine
        }

        let mergedConfidence = candidatesDisagreeOnCommand
            ? winner.confidence * conflictConfidencePenaltyMultiplier
            : winner.confidence

        return FieldResolution(
            command: winner.command,
            confidence: mergedConfidence,
            provenance: winner.provenance
        )
    }

    // MARK: - Ecosystem identifier selection

    /// Pick the recipe's ecosystem tag from the matched findings. The chosen
    /// finding is the one with the strongest HEADLINE signal — the lowest
    /// provenance rank among the commands it contributed, tie-broken by higher
    /// confidence, then by registry order — so a real language detector's
    /// author-declared recipe names the ecosystem rather than the low-precedence
    /// container fallback, while a repo whose only author-declared recipe is a
    /// Makefile is honestly tagged from that. "unknown" when nothing matched
    /// (the wall-into-capability case: still routed to clarification, never a
    /// fabricated tag).
    private static func chooseEcosystemIdentifier(
        fromMatchedFindings matchedFindings: [EcosystemDetectorFinding]
    ) -> String {
        var bestFindingHeadline: FindingHeadline? = nil
        var bestEcosystemIdentifier = "unknown"

        for finding in matchedFindings {
            let headline = headlineSignal(ofFinding: finding)
            // A finding that contributed no command has no headline and cannot
            // name the ecosystem.
            guard let headline else { continue }

            if bestFindingHeadline == nil || headline.isStrongerThan(bestFindingHeadline!) {
                bestFindingHeadline = headline
                bestEcosystemIdentifier = finding.ecosystemIdentifier
            }
        }

        return bestEcosystemIdentifier
    }

    /// The strength of a finding's best single command, used only to choose the
    /// ecosystem tag. Lower `bestProvenanceRank` is stronger; among equal ranks,
    /// higher `bestConfidence` is stronger.
    private struct FindingHeadline {
        let bestProvenanceRank: Int
        let bestConfidence: Double

        func isStrongerThan(_ other: FindingHeadline) -> Bool {
            if bestProvenanceRank != other.bestProvenanceRank {
                return bestProvenanceRank < other.bestProvenanceRank
            }
            return bestConfidence > other.bestConfidence
        }
    }

    /// The best (lowest-rank, then highest-confidence) command a finding
    /// contributed, or nil when it contributed none.
    private static func headlineSignal(ofFinding finding: EcosystemDetectorFinding) -> FindingHeadline? {
        var headline: FindingHeadline? = nil

        for field in RecipeField.allCases {
            guard finding.commandsByField[field] != nil else { continue }
            let candidateHeadline = FindingHeadline(
                bestProvenanceRank: (finding.provenanceByField[field] ?? .unknown).trustRank,
                bestConfidence: finding.confidenceByField[field] ?? 0.0
            )
            if headline == nil || candidateHeadline.isStrongerThan(headline!) {
                headline = candidateHeadline
            }
        }

        return headline
    }

    // MARK: - CI workflow mining (.github/workflows/*.yml `run:` steps)

    /// The fixed, well-known location GitHub Actions workflow files live in. It
    /// is a constant path (never repo-supplied), so listing it is safe and every
    /// file it yields is still read through `RepoRecipeFiles` (containment +
    /// size cap).
    private static let workflowsRelativeDirectory = ".github/workflows"

    /// Scan every workflow file's `run:` steps and classify each command as an
    /// install / build / test step, returning at most one CI candidate per field
    /// (the FIRST such command encountered, scanning files in sorted order then
    /// top-to-bottom, so the result is deterministic). Recorded at
    /// `ciWorkflowStep` provenance — above every guessed default, below an
    /// author-declared manifest script.
    private static func mineCIWorkflowRunStepCandidates(
        repoRootPath: String
    ) -> [RecipeField: FieldCandidate] {
        var firstCommandByField: [RecipeField: String] = [:]

        for workflowRelativePath in workflowFileRelativePaths(repoRootPath: repoRootPath) {
            guard let workflowText = RepoRecipeFiles.readText(
                workflowRelativePath,
                underRepoRoot: repoRootPath
            ) else { continue }

            for runCommand in runCommands(inWorkflowYAML: workflowText) {
                guard let field = classifyRunCommand(runCommand) else { continue }
                // Keep only the first command seen for each field.
                if firstCommandByField[field] == nil {
                    firstCommandByField[field] = runCommand
                }
            }
        }

        var candidatesByField: [RecipeField: FieldCandidate] = [:]
        for (field, commandLine) in firstCommandByField {
            candidatesByField[field] = FieldCandidate(
                command: RepoRecipeCommand(commandLine: commandLine),
                confidence: ciWorkflowStepConfidence,
                provenance: .ciWorkflowStep
            )
        }
        return candidatesByField
    }

    /// The repo-relative paths of every `*.yml` / `*.yaml` file directly under
    /// `.github/workflows`, sorted for deterministic scanning. Empty when the
    /// directory is absent or unreadable. Enumerated through `FileManager`
    /// because `RepoRecipeFiles` exposes no listing surface by design; the base
    /// directory is a fixed constant and every yielded name is a real filesystem
    /// entry (never untrusted manifest text), so no traversal escape is possible
    /// and the subsequent reads remain repo-confined.
    private static func workflowFileRelativePaths(repoRootPath: String) -> [String] {
        let workflowsDirectoryPath = URL(fileURLWithPath: repoRootPath)
            .appendingPathComponent(workflowsRelativeDirectory)
            .path

        guard let entryNames = try? FileManager.default.contentsOfDirectory(
            atPath: workflowsDirectoryPath
        ) else {
            return []
        }

        return entryNames
            .filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
            .sorted()
            .map { "\(workflowsRelativeDirectory)/\($0)" }
    }

    /// Extract every shell command a workflow's `run:` steps would execute, in
    /// document order. Handles both the inline form (`run: npm ci`) and the YAML
    /// block-scalar form (`run: |` followed by indented command lines), yielding
    /// each block line as its own command so a multi-command block is classified
    /// line by line. A pure line scan — no YAML engine, no execution.
    private static func runCommands(inWorkflowYAML workflowYAML: String) -> [String] {
        var extractedCommands: [String] = []
        let lines = workflowYAML.components(separatedBy: .newlines)

        var cursor = 0
        while cursor < lines.count {
            let rawLine = lines[cursor]
            cursor += 1

            guard let runKey = runKeyInfo(inLine: rawLine) else { continue }

            if let inlineCommand = runKey.inlineCommand {
                let cleanedInlineCommand = stripInlineYAMLComment(inlineCommand)
                    .trimmingCharacters(in: .whitespaces)
                if !cleanedInlineCommand.isEmpty {
                    extractedCommands.append(cleanedInlineCommand)
                }
                continue
            }

            // Block scalar: collect every following line MORE indented than the
            // `run:` key, treating each non-blank line as its own command. A `#`
            // inside a block scalar is literal shell (a comment in the script),
            // so we do NOT strip it here — only inline scalars get comment
            // stripping.
            while cursor < lines.count {
                let blockLine = lines[cursor]
                let blockLineTrimmed = blockLine.trimmingCharacters(in: .whitespaces)

                if blockLineTrimmed.isEmpty {
                    // A blank line is allowed inside a block scalar; skip it
                    // without ending the block.
                    cursor += 1
                    continue
                }

                // A line indented no further than the `run:` key ends the block.
                // Do NOT consume it — the outer loop must re-read it (it may be
                // the next `- run:` step).
                if leadingSpaceCount(ofLine: blockLine) <= runKey.keyIndentation {
                    break
                }

                extractedCommands.append(blockLineTrimmed)
                cursor += 1
            }
        }

        return extractedCommands
    }

    /// What a single line tells us about a `run:` key: the column the key sits at
    /// (so a block scalar's continuation lines can be measured against it) and,
    /// for the inline form, the command text after `run:`. `inlineCommand == nil`
    /// means a block scalar (`|` / `>`) follows. Returns nil when the line is not
    /// a `run:` key at all.
    private struct RunKeyInfo {
        let keyIndentation: Int
        let inlineCommand: String?
    }

    private static func runKeyInfo(inLine rawLine: String) -> RunKeyInfo? {
        // Start at the first non-space column.
        let leadingSpaces = leadingSpaceCount(ofLine: rawLine)
        var remainder = String(rawLine.dropFirst(leadingSpaces))
        var keyIndentation = leadingSpaces

        // A step is a YAML list item, so the `run:` key is commonly preceded by a
        // "- " list marker (`- run: …`). Strip it and any spaces after it,
        // advancing the effective key column so block-scalar indentation is
        // measured from where `run` actually starts.
        if remainder.hasPrefix("- ") {
            remainder = String(remainder.dropFirst(2))
            keyIndentation += 2
            let spacesAfterMarker = leadingSpaceCount(ofLine: remainder)
            remainder = String(remainder.dropFirst(spacesAfterMarker))
            keyIndentation += spacesAfterMarker
        }

        guard remainder.hasPrefix("run:") else { return nil }

        let afterKey = String(remainder.dropFirst("run:".count))
            .trimmingCharacters(in: .whitespaces)

        // A leading `|` or `>` (literal or folded block indicator, with or
        // without a chomping/indentation suffix like `|-`) means a block scalar
        // follows on the next lines. A real shell command never begins with one
        // of those characters, so this test is unambiguous.
        if afterKey.isEmpty || afterKey.hasPrefix("|") || afterKey.hasPrefix(">") {
            return RunKeyInfo(keyIndentation: keyIndentation, inlineCommand: nil)
        }

        return RunKeyInfo(keyIndentation: keyIndentation, inlineCommand: afterKey)
    }

    /// Remove a trailing YAML comment from an INLINE plain scalar. A `#` only
    /// begins a comment when preceded by whitespace (YAML's plain-scalar rule),
    /// so we cut at the first " #" and keep everything before it. Applied to
    /// inline `run:` values only — never to block-scalar lines, where `#` is
    /// literal shell.
    private static func stripInlineYAMLComment(_ inlineScalar: String) -> String {
        guard let commentRange = inlineScalar.range(of: " #") else { return inlineScalar }
        return String(inlineScalar[inlineScalar.startIndex..<commentRange.lowerBound])
    }

    /// Classify a `run:` command as filling the install, build, or test field, or
    /// nil when it is none of those (a lint step, a deploy step, a checkout, …).
    /// Install is checked FIRST because an install command rarely also mentions
    /// build/test, whereas a build/test command should not be mistaken for an
    /// install. The match is a lowercased substring test — enough to recognize a
    /// declared lifecycle step without a shell parser.
    private static func classifyRunCommand(_ command: String) -> RecipeField? {
        let loweredCommand = command.lowercased()
        if commandLooksLikeInstall(loweredCommand) { return .install }
        if commandLooksLikeBuild(loweredCommand) { return .build }
        if commandLooksLikeTest(loweredCommand) { return .test }
        return nil
    }

    /// Dependency-resolution steps across ecosystems: anything containing
    /// "install" (npm/yarn/pnpm/pip/poetry/pipenv/bundle install), plus the
    /// common install commands that do NOT spell the word — `npm ci`, `uv sync`,
    /// `go mod download`, `cargo fetch`.
    private static func commandLooksLikeInstall(_ loweredCommand: String) -> Bool {
        return loweredCommand.contains("install")
            || loweredCommand.contains("npm ci")
            || loweredCommand.contains("uv sync")
            || loweredCommand.contains("mod download")
            || loweredCommand.contains("cargo fetch")
    }

    /// Build steps: any command mentioning "build" — which covers `npm run
    /// build`, `cargo build`, `go build`, `next build`, `make build`, and even
    /// `xcodebuild … build`.
    private static func commandLooksLikeBuild(_ loweredCommand: String) -> Bool {
        return loweredCommand.contains("build")
    }

    /// Test steps: any command mentioning "test" (npm/go/cargo test, pytest,
    /// vitest, `playwright test`), plus the well-known runners whose name does
    /// not contain "test" (jest, mocha).
    private static func commandLooksLikeTest(_ loweredCommand: String) -> Bool {
        return loweredCommand.contains("test")
            || loweredCommand.contains("jest")
            || loweredCommand.contains("mocha")
    }

    // MARK: - Shared helper

    /// Count the leading SPACE characters of a line — the indentation measure the
    /// YAML block-scalar and key logic use. Tabs are invalid YAML indentation and
    /// are not counted, matching the other detectors' scanners.
    private static func leadingSpaceCount(ofLine line: String) -> Int {
        var spaceCount = 0
        for character in line {
            if character == " " { spaceCount += 1 } else { break }
        }
        return spaceCount
    }
}

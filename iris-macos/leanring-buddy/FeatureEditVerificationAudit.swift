//
//  FeatureEditVerificationAudit.swift
//  leanring-buddy
//
//  The anti-gaming + mutation layer of the Feature Engine's verification ladder
//  (plan §9). Iris is both prosecutor and defendant — it authors the change AND
//  the test that "proves" it — so a green suite is necessary but never
//  sufficient. This file holds the pure, static checks that make "the maker
//  must not grade its own homework" real:
//
//    1. `cheatSignatures(inUnifiedDiff:)` — scans the applied diff for the
//       tamper patterns a self-verifying agent reaches for when it wants a
//       green light without earning it: tautological asserts, catch/except
//       blocks that swallow, newly focused/skipped tests, re-recorded
//       snapshots, a test that mocks the very module it is supposed to
//       exercise, and a net DROP in test/assertion count. This generalizes the
//       existing `VerificationHarness.enforceDiffScope` "weakens tests" check
//       from a line-count heuristic to named cheat signatures.
//
//    2. `mutationCommand(forEcosystem:changedFiles:)` — picks the right mutation
//       tester (Stryker / PIT / cargo-mutants / mutmut) scoped to the changed
//       source files, so an agent-authored test must PROVE it is sensitive
//       (kills injected mutants) before it is trusted — the antidote to a test
//       that runs green while verifying nothing (ratified decision 4b).
//
//    3. `cleanCloneVerifyPlan(repoRootPath:branch:)` — the git commands that
//       stand up a pristine, throwaway checkout of the committed branch OUTSIDE
//       the maker's dirty working tree, so the verification pass runs as a
//       separate CHECKER that cannot see (or be fooled by) the maker's
//       in-progress state.
//
//  Everything here is pure Foundation: static string/diff analysis and command
//  STRING building only. It never spawns a process, never touches the network,
//  never executes anything from the target repo — the commands it composes are
//  handed to the (classifier-screened, staged-consent) shell runner elsewhere,
//  exactly as the recipe commands are.
//

import Foundation

/// The value returned by `cleanCloneVerifyPlan`: the commands to build a
/// pristine checker checkout, plus its throwaway location and teardown. Kept as
/// a plain value (strings, not a live process) so the maker/checker separation
/// is auditable and testable without running anything.
struct CleanCloneVerifyPlan: Sendable, Equatable {
    /// A fresh, throwaway checkout directory — deliberately OUTSIDE
    /// `repoRootPath` (it lives under the OS temp dir) so the checker can never
    /// read the maker's dirty working tree, its stash, or its uncommitted
    /// files. This is the physical enforcement of "maker != checker".
    let freshCheckoutPath: String

    /// The git commands, in order, that populate `freshCheckoutPath` with a
    /// pristine copy of `branch`. Run these before any recipe install/build/
    /// test so the verify runs against exactly what was committed.
    let checkoutCommands: [String]

    /// Removes the throwaway checkout once verification is done. Kept explicit
    /// (rather than a silent auto-clean) so the caller decides when to tear it
    /// down — e.g. after capturing evidence for the log.
    let teardownCommand: String
}

enum FeatureEditVerificationAudit {

    // MARK: - Cheat-signature diff scanner (plan §9 anti-gaming)

    /// Scan an applied change, expressed as a unified diff, for the tamper
    /// patterns that make a suite go green without the change being real.
    /// Returns one human-readable finding per detected signature; an EMPTY
    /// array means the diff carries none of them (an honest diff passes
    /// cleanly). The scanner is intentionally suspicious: a finding is a punch
    /// item for a human/adversarial pass to adjudicate, not proof of malice —
    /// but every listed pattern is one a self-grading agent measurably reaches
    /// for, so surfacing them is the whole point.
    ///
    /// `declaredTestCountBefore` / `declaredTestCountAfter` are optional: when
    /// the harness has actually run the suite before and after and counted the
    /// tests, pass them and a real drop is flagged directly. Left nil, the
    /// scanner still derives a test/assertion drop from the diff itself.
    static func cheatSignatures(
        inUnifiedDiff unifiedDiff: String,
        declaredTestCountBefore: Int? = nil,
        declaredTestCountAfter: Int? = nil
    ) -> [String] {
        let diffLines = unifiedDiff.components(separatedBy: "\n")

        // Pass 1 — figure out which production modules this change touches, so
        // the "mocks the module under test" rule has something to compare a
        // mock target against. The module under test is precisely the set of
        // changed NON-test source files.
        let changedProductionModuleBasenames = productionModuleBasenames(inDiffLines: diffLines)

        var findings: [String] = []

        // Running tallies for the test/assertion-count drop check. Counted
        // across every test file the diff touches, on added vs removed lines.
        var addedAssertionLineCount = 0
        var removedAssertionLineCount = 0
        var addedTestDeclarationCount = 0
        var removedTestDeclarationCount = 0

        // Snapshot files whose content the diff rewrites — reported once each,
        // not once per changed line.
        var reRecordedSnapshotPaths: Set<String> = []

        // Pass 2 — walk the hunks, attributing each +/- line to its file.
        var currentNewFilePath: String? = nil
        var currentOldFilePath: String? = nil

        for diffLine in diffLines {
            // File headers reset the "current file" the following +/- lines
            // belong to. These must be checked BEFORE the +/- content checks,
            // because "+++ " and "--- " also start with + / -.
            if diffLine.hasPrefix("+++ ") {
                // A snapshot file's re-record is confirmed by the per-line loop
                // below (a header alone is not a content change), so this only
                // needs to record which file the following +/- lines belong to.
                currentNewFilePath = filePath(fromDiffHeaderLine: diffLine, markerLength: 4)
                continue
            }
            if diffLine.hasPrefix("--- ") {
                currentOldFilePath = filePath(fromDiffHeaderLine: diffLine, markerLength: 4)
                continue
            }
            // Skip hunk headers and the raw `diff --git`/`index`/mode lines —
            // they are not content, and their leading characters ("@", "d",
            // "i") never collide with the +/- content prefixes.
            if diffLine.hasPrefix("@@") || diffLine.hasPrefix("diff ") { continue }

            let isAddedLine = diffLine.hasPrefix("+")
            let isRemovedLine = diffLine.hasPrefix("-")
            guard isAddedLine || isRemovedLine else { continue }

            let lineContent = String(diffLine.dropFirst())
            let attributedFilePath = (isAddedLine ? currentNewFilePath : currentOldFilePath) ?? ""
            let attributedPathIsATestFile = looksLikeATestPath(attributedFilePath)

            // --- Snapshot re-record: any change inside a snapshot file. ---
            if looksLikeASnapshotPath(attributedFilePath),
               !lineContent.trimmingCharacters(in: .whitespaces).isEmpty {
                reRecordedSnapshotPaths.insert(attributedFilePath)
            }

            // Test/assertion-count tallies run on BOTH directions so a net drop
            // is visible. Only within test files — removing an assert from
            // production code is not test weakening.
            if attributedPathIsATestFile {
                if lineMatchesAnAssertion(lineContent) {
                    if isAddedLine { addedAssertionLineCount += 1 } else { removedAssertionLineCount += 1 }
                }
                if lineDeclaresATest(lineContent) {
                    if isAddedLine { addedTestDeclarationCount += 1 } else { removedTestDeclarationCount += 1 }
                }
            }

            // Every remaining signature is about something NEWLY introduced, so
            // it only fires on ADDED lines. A removed cheat is a cheat being
            // taken OUT — not something to block.
            guard isAddedLine else { continue }

            let trimmedContent = lineContent.trimmingCharacters(in: .whitespaces)

            // --- Tautological assertions. ---
            if let tautologyNeedle = tautologicalAssertionNeedle(inAddedContent: lineContent) {
                findings.append(
                    "tautological assertion in \(displayPath(attributedFilePath)): "
                    + "\(trimmedContent) (matches \(tautologyNeedle))"
                )
            }

            // --- Swallowed error handlers (empty catch / except: pass). ---
            if let swallowDescription = swallowedErrorHandlerDescription(inAddedContent: lineContent) {
                findings.append(
                    "swallowed error handler in \(displayPath(attributedFilePath)): "
                    + "\(trimmedContent) (\(swallowDescription))"
                )
            }

            // --- Newly focused/skipped tests. ---
            if let skipToken = focusedOrSkippedTestToken(
                inAddedContent: lineContent,
                pathIsATestFile: attributedPathIsATestFile
            ) {
                findings.append(
                    "focused/skipped test marker in \(displayPath(attributedFilePath)): "
                    + "\(trimmedContent) (matches \(skipToken))"
                )
            }

            // --- Snapshot update flag baked into the diff. ---
            if let snapshotFlag = snapshotUpdateFlag(inAddedContent: lineContent) {
                findings.append(
                    "snapshot update flag in \(displayPath(attributedFilePath)): \(snapshotFlag)"
                )
            }

            // --- A test that mocks the very module under test. ---
            if attributedPathIsATestFile,
               let mockedModule = mockedModuleUnderTest(
                   inAddedContent: lineContent,
                   changedProductionModuleBasenames: changedProductionModuleBasenames
               ) {
                findings.append(
                    "test mocks the module under test (\(mockedModule)) in "
                    + "\(displayPath(attributedFilePath)): \(trimmedContent)"
                )
            }
        }

        // Snapshot re-records, one finding per file, in a stable order so the
        // output is deterministic for tests and diffs.
        for snapshotPath in reRecordedSnapshotPaths.sorted() {
            findings.append("snapshot re-recorded in \(displayPath(snapshotPath))")
        }

        // Diff-derived assertion/test drops. Fewer asserts or fewer tests
        // AFTER a change than before is the classic "delete what would catch
        // me", generalized from the harness's line-count check to the count of
        // the things that actually verify behavior.
        if removedAssertionLineCount > addedAssertionLineCount {
            findings.append(
                "assertion count dropped in tests (removed \(removedAssertionLineCount) "
                + "assertion lines, added \(addedAssertionLineCount))"
            )
        }
        if removedTestDeclarationCount > addedTestDeclarationCount {
            findings.append(
                "test-declaration count dropped in tests (removed \(removedTestDeclarationCount), "
                + "added \(addedTestDeclarationCount))"
            )
        }

        // Explicit before/after counts, when the harness measured them, are the
        // strongest form of this signal — a real count from a real run.
        if let before = declaredTestCountBefore, let after = declaredTestCountAfter, after < before {
            findings.append("declared test count dropped from \(before) to \(after)")
        }

        return findings
    }

    // MARK: - Mutation testing command (plan §9, ratified decision 4b)

    /// The mutation-testing command to run for a change in `ecosystemIdentifier`
    /// (a `RepoRecipe.ecosystemIdentifier`, e.g. "node/next", "rust/tauri",
    /// "python/uv", "jvm/gradle"), scoped to the CHANGED source files so the
    /// injected mutants land in exactly the production code the agent touched.
    /// A test that cannot kill those mutants has not proven it verifies the new
    /// behavior, so mutation is the gate an agent-authored test must clear.
    ///
    /// Returns nil when there is no mutation tool for the ecosystem (Swift, Go,
    /// …) or when none of the changed files are mutatable source for it — an
    /// honest "no mutation gate available" is never a fabricated green.
    static func mutationCommand(forEcosystem ecosystemIdentifier: String, changedFiles: [String]) -> String? {
        // Match on the language family (the part before the first "/"), so
        // "node/next" and "node/vite" both resolve to Stryker without a row
        // per framework.
        let ecosystemLowercased = ecosystemIdentifier.lowercased()
        let languageFamily = ecosystemLowercased.split(separator: "/").first.map(String.init) ?? ecosystemLowercased

        switch languageFamily {
        case "node", "js", "javascript", "ts", "typescript":
            return strykerCommand(changedFiles: changedFiles)
        case "rust":
            return cargoMutantsCommand(changedFiles: changedFiles)
        case "python", "py":
            return mutmutCommand(changedFiles: changedFiles)
        case "jvm", "java", "kotlin", "scala":
            // PIT ships as a Maven goal or a Gradle plugin; the invocation
            // differs, so branch on the build tool named in the ecosystem tag.
            let usesMaven = ecosystemLowercased.contains("maven")
            return pitestCommand(changedFiles: changedFiles, usesMaven: usesMaven)
        default:
            // Swift (no first-class mutation tester in the plan's roster), Go,
            // Docker, Makefile, … — no gate rather than a wrong one.
            return nil
        }
    }

    // MARK: - Clean-clone verify plan (plan §9, maker != checker)

    /// The git commands that stand up a pristine, throwaway checkout of
    /// `branch` for the CHECKER — separate from the maker's working tree at
    /// `repoRootPath`. The checkout lands under the OS temp dir (never inside
    /// the repo), and the clone uses `--no-local` so its object store is a real
    /// copy, not hardlinks shared with the maker's repo: the checker cannot be
    /// influenced by anything the maker left uncommitted.
    static func cleanCloneVerifyPlan(repoRootPath: String, branch: String) -> CleanCloneVerifyPlan {
        // A per-run unique directory so two verification passes never collide
        // and the maker's tree is never a candidate location.
        let uniqueSuffix = UUID().uuidString
        let freshCheckoutPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-clean-verify-\(uniqueSuffix)")

        let quotedRepoRoot = shellSingleQuoted(repoRootPath)
        let quotedBranch = shellSingleQuoted(branch)
        let quotedFreshCheckout = shellSingleQuoted(freshCheckoutPath)

        // `--no-local` forces a copied object store (no hardlinks) so the
        // checker tree is physically independent; `--single-branch --branch`
        // fetches ONLY the committed branch, so a fresh checkout of exactly
        // what was committed is all the checker ever sees.
        let cloneCommand =
            "git clone --no-local --quiet --single-branch --branch \(quotedBranch) "
            + "\(quotedRepoRoot) \(quotedFreshCheckout)"

        // Detach so the checker can never accidentally advance or push the
        // branch it is only supposed to verify.
        let detachCommand = "git -C \(quotedFreshCheckout) checkout --quiet --detach"

        return CleanCloneVerifyPlan(
            freshCheckoutPath: freshCheckoutPath,
            checkoutCommands: [cloneCommand, detachCommand],
            teardownCommand: "rm -rf \(quotedFreshCheckout)"
        )
    }

    // MARK: - Mutation command builders

    private static func strykerCommand(changedFiles: [String]) -> String? {
        // Stryker mutates JS/TS SOURCE; mutating a test or a type-declaration
        // file is meaningless, so scope `--mutate` to the changed source only.
        let mutatableSourceFiles = changedFiles.filter { candidatePath in
            fileHasAnyExtension(candidatePath, [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"])
                && !candidatePath.lowercased().hasSuffix(".d.ts")
                && !looksLikeATestPath(candidatePath)
                && !looksLikeASnapshotPath(candidatePath)
        }
        guard !mutatableSourceFiles.isEmpty else { return nil }
        let mutateArgument = mutatableSourceFiles
            .map { shellSingleQuoted($0) }
            .joined(separator: ",")
        return "npx stryker run --mutate \(mutateArgument)"
    }

    private static func cargoMutantsCommand(changedFiles: [String]) -> String? {
        // cargo-mutants restricts to files via repeated `--file`. Skip the
        // integration-test directory (`tests/`); inline `#[cfg(test)]` tests
        // are invisible to a static path check and are left to the tool.
        let mutatableSourceFiles = changedFiles.filter { candidatePath in
            fileHasAnyExtension(candidatePath, [".rs"]) && !isRustIntegrationTestPath(candidatePath)
        }
        guard !mutatableSourceFiles.isEmpty else { return nil }
        let fileArguments = mutatableSourceFiles
            .map { "--file \(shellSingleQuoted($0))" }
            .joined(separator: " ")
        return "cargo mutants \(fileArguments)"
    }

    private static func mutmutCommand(changedFiles: [String]) -> String? {
        // mutmut mutates the paths in `--paths-to-mutate`; scope it to changed
        // Python source, excluding tests (mutating a test proves nothing).
        let mutatableSourceFiles = changedFiles.filter { candidatePath in
            fileHasAnyExtension(candidatePath, [".py"]) && !looksLikeATestPath(candidatePath)
        }
        guard !mutatableSourceFiles.isEmpty else { return nil }
        let pathsArgument = mutatableSourceFiles.joined(separator: ",")
        return "mutmut run --paths-to-mutate \(shellSingleQuoted(pathsArgument))"
    }

    private static func pitestCommand(changedFiles: [String], usesMaven: Bool) -> String? {
        // PIT scopes by CLASS, not file, so derive fully-qualified class names
        // from the changed Java/Kotlin source paths and pass them as
        // targetClasses. Test sources are excluded — PIT mutates production
        // classes and runs the tests against them.
        let mutatableSourceFiles = changedFiles.filter { candidatePath in
            fileHasAnyExtension(candidatePath, [".java", ".kt"]) && !looksLikeATestPath(candidatePath)
        }
        let targetClassNames = mutatableSourceFiles.map { fullyQualifiedClassName(fromJvmSourcePath: $0) }
        guard !targetClassNames.isEmpty else { return nil }
        let targetClassesArgument = shellSingleQuoted(targetClassNames.joined(separator: ","))

        if usesMaven {
            return "mvn org.pitest:pitest-maven:mutationCoverage "
                + "-DtargetClasses=\(targetClassesArgument) -DtargetTests='*'"
        }
        return "./gradlew pitest -PtargetClasses=\(targetClassesArgument)"
    }

    /// Turn `src/main/java/com/x/Foo.java` into `com.x.Foo`. Strips the
    /// conventional Maven/Gradle source-root prefixes so the class name PIT
    /// expects is what we pass; falls back to the bare type name when no
    /// recognizable source root is present.
    private static func fullyQualifiedClassName(fromJvmSourcePath jvmSourcePath: String) -> String {
        var remainingPath = jvmSourcePath
        for sourceRootPrefix in ["src/main/java/", "src/main/kotlin/", "src/test/java/", "src/test/kotlin/"] {
            if let prefixRange = remainingPath.range(of: sourceRootPrefix) {
                remainingPath = String(remainingPath[prefixRange.upperBound...])
                break
            }
        }
        // Drop the extension, then map the path separators to package dots.
        let withoutExtension = (remainingPath as NSString).deletingPathExtension
        return withoutExtension.replacingOccurrences(of: "/", with: ".")
    }

    // MARK: - Cheat-signature helpers

    /// The set of production module basenames the diff changes — every changed
    /// file that is source code and is NOT a test/snapshot file, reduced to its
    /// basename without extension, lowercased for case-insensitive comparison.
    private static func productionModuleBasenames(inDiffLines diffLines: [String]) -> Set<String> {
        var basenames: Set<String> = []
        for diffLine in diffLines {
            let parsedPath: String?
            if diffLine.hasPrefix("+++ ") {
                parsedPath = filePath(fromDiffHeaderLine: diffLine, markerLength: 4)
            } else if diffLine.hasPrefix("--- ") {
                parsedPath = filePath(fromDiffHeaderLine: diffLine, markerLength: 4)
            } else {
                parsedPath = nil
            }
            guard let path = parsedPath,
                  isRecognizedSourceCodePath(path),
                  !looksLikeATestPath(path),
                  !looksLikeASnapshotPath(path)
            else { continue }
            let basenameWithoutExtension = ((path as NSString).lastPathComponent as NSString)
                .deletingPathExtension
                .lowercased()
            if !basenameWithoutExtension.isEmpty {
                basenames.insert(basenameWithoutExtension)
            }
        }
        return basenames
    }

    /// Returns the tautology needle an added line matches, or nil. A
    /// tautological assertion encodes a constant that is always true, so it
    /// passes no matter what the code does — the emptiest possible "test".
    private static func tautologicalAssertionNeedle(inAddedContent addedContent: String) -> String? {
        // Compare with all whitespace removed so "XCTAssertTrue( true )" and
        // "XCTAssertTrue(true)" are the same needle.
        let spacelessLowercased = addedContent.lowercased().filter { !$0.isWhitespace }

        // Each needle is a whole assertion over a constant. Kept explicit (not
        // a broad regex) so a real assertion over a variable named `trueCount`
        // or a value `1` is never swept up.
        let constantAssertionNeedles = [
            "assert(true)",
            "assert(1)",
            "assert.ok(1)",
            "assert.ok(true)",
            "assert.equal(1,1)",
            "assert.equal(true,true)",
            "assert.strictequal(1,1)",
            "assert.strictequal(true,true)",
            "assertequal(1,1)",
            "assertequals(1,1)",
            "asserttrue(true)",
            "xctassert(true)",
            "xctasserttrue(true)",
            "xctassertfalse(false)",
            "expect(true).tobe(true)",
            "expect(true).tobetruthy()",
            "expect(1).tobe(1)",
            "expect(1).toequal(1)",
            "assertthat(true).istrue()",
            "#expect(true)",
        ]
        for needle in constantAssertionNeedles where spacelessLowercased.contains(needle) {
            return needle
        }

        // Python's bare `assert True` / `assert 1` has no parentheses, so match
        // it on the trimmed line rather than the spaceless form.
        let trimmedLowercased = addedContent
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if trimmedLowercased.range(of: "^assert\\s+(true|1)\\b", options: .regularExpression) != nil {
            return "assert <constant>"
        }
        return nil
    }

    /// Describes how an added line swallows an error, or nil. A swallow means
    /// an exception is caught and then nothing is done with it — the failure
    /// disappears and a broken path silently "works".
    private static func swallowedErrorHandlerDescription(inAddedContent addedContent: String) -> String? {
        let spacelessLowercased = addedContent.lowercased().filter { !$0.isWhitespace }

        // Empty catch bodies: `catch {}`, `catch (e) {}`, `} catch {}`, and the
        // promise form `.catch(() => {})`. The optional parenthesized binding
        // is allowed, but the body must be empty.
        if spacelessLowercased.range(of: "catch(\\([^)]*\\))?\\{\\}", options: .regularExpression) != nil {
            return "empty catch body"
        }
        if spacelessLowercased.contains(".catch(()=>{})") || spacelessLowercased.contains(".catch(function(){})") {
            return "empty promise catch"
        }

        // Python one-liner swallows: `except ...: pass` / `: continue` / `: ...`
        let trimmedLowercased = addedContent
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if trimmedLowercased.range(of: "^except\\b.*:\\s*(pass|continue|\\.\\.\\.)\\s*$", options: .regularExpression) != nil {
            return "except that swallows"
        }
        // A newly added BARE `except:` (no exception type) is a catch-all — the
        // broadening the plan names, whatever its body does.
        if trimmedLowercased.range(of: "^except\\s*:\\s*$", options: .regularExpression) != nil {
            return "bare catch-all except"
        }
        return nil
    }

    /// Returns the focus/skip token an added line introduces, or nil. A focused
    /// (`.only`, `fit`) or skipped (`.skip`, `xit`, `XCTSkip`, `@pytest.mark.
    /// skip`) test quietly removes coverage — a focus even disables every OTHER
    /// test in the file.
    private static func focusedOrSkippedTestToken(
        inAddedContent addedContent: String,
        pathIsATestFile: Bool
    ) -> String? {
        let lowercased = addedContent.lowercased()

        // Unambiguous runner tokens: these only ever mean focus/skip, so they
        // are flagged wherever they appear.
        let alwaysSuspiciousTokens = [
            "it.only(", "describe.only(", "test.only(", "context.only(",
            "it.skip(", "describe.skip(", "test.skip(", "context.skip(",
            "xit(", "xdescribe(", "xtest(",
            "fit(", "fdescribe(", "ftest(",
            "pytest.mark.skip", "unittest.skip", "pytest.skip(",
            "xctskip",
        ]
        for token in alwaysSuspiciousTokens where lowercased.contains(token) {
            return token
        }

        // swift-testing's `.disabled(...)` is a skip trait, but the identical
        // spelling is an extremely common SwiftUI modifier — so only treat it
        // as a skip when it sits on a `@Test` line.
        if lowercased.contains("@test") && lowercased.contains(".disabled(") {
            return "@Test(.disabled(…))"
        }

        // Bare `.only(` / `.skip(` are ambiguous outside a test file (e.g. a
        // lodash `.skip`), so gate them to test files.
        if pathIsATestFile {
            for token in [".only(", ".skip("] where lowercased.contains(token) {
                return token
            }
        }
        return nil
    }

    /// Returns a snapshot-update flag baked into an added line, or nil. Wiring
    /// `--updateSnapshot` into a test command makes snapshot tests rewrite
    /// themselves to match whatever the code now produces — they can never
    /// fail again.
    private static func snapshotUpdateFlag(inAddedContent addedContent: String) -> String? {
        let lowercased = addedContent.lowercased()
        for flag in ["--updatesnapshot", "--update-snapshots", "--updatesnapshots", "--ci=false"] where lowercased.contains(flag) {
            return flag
        }
        return nil
    }

    /// Returns the changed production module an added line mocks, or nil.
    /// Mocking the module under test replaces the very code the change touched
    /// with a fake, so the test exercises the fake, not the change — green, and
    /// meaningless. Dependencies (mocking `axios`, a clock) are legitimate and
    /// are NOT flagged, which is why this compares against the changed-source
    /// set specifically.
    private static func mockedModuleUnderTest(
        inAddedContent addedContent: String,
        changedProductionModuleBasenames: Set<String>
    ) -> String? {
        guard !changedProductionModuleBasenames.isEmpty else { return nil }
        let lowercased = addedContent.lowercased()

        // Only string-target module mocks are checkable statically.
        let mockCallMarkers = [
            "jest.mock(", "jest.domock(", "jest.setmock(",
            "vi.mock(", "vitest.mock(",
            "mock.patch(", "@mock.patch(", "@patch(", "patch.object(", "mocker.patch(",
        ]
        guard mockCallMarkers.contains(where: { lowercased.contains($0) }) else { return nil }

        guard let mockTarget = firstQuotedSubstring(in: addedContent) else { return nil }

        // A mock target can be a path ("../src/Foo") or a dotted import
        // ("myapp.services.foo.do_it"); split on both separators and compare
        // each component's basename against the changed modules.
        let targetComponents = mockTarget
            .components(separatedBy: CharacterSet(charactersIn: "/."))
            .map { ($0 as NSString).lastPathComponent.lowercased() }
            .filter { !$0.isEmpty }

        // Drop generic path words that would cause coincidental matches.
        let genericPathComponents: Set<String> = [
            "src", "lib", "dist", "app", "index", "..", ".", "test", "tests", "__mocks__",
        ]
        for component in targetComponents where !genericPathComponents.contains(component) {
            if changedProductionModuleBasenames.contains(component) {
                return component
            }
        }
        return nil
    }

    // MARK: - Small pure text utilities

    /// The first single- or double-quoted substring in a line, without the
    /// quotes. Used to pull a mock target out of `jest.mock('…')`.
    private static func firstQuotedSubstring(in line: String) -> String? {
        for quoteCharacter in ["'", "\""] {
            if let openingRange = line.range(of: quoteCharacter),
               let closingRange = line.range(of: quoteCharacter, range: openingRange.upperBound..<line.endIndex) {
                return String(line[openingRange.upperBound..<closingRange.lowerBound])
            }
        }
        return nil
    }

    /// True when a line carries an assertion — used to count assertions on
    /// either side of the diff. Matches `assert`, `expect(`, `XCTAssert`, and
    /// swift-testing's `#expect(`.
    private static func lineMatchesAnAssertion(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return lowercased.range(
            of: "(\\bassert|\\bexpect\\(|xctassert|#expect\\()",
            options: .regularExpression
        ) != nil
    }

    /// True when a line declares a test case — used to count tests on either
    /// side of the diff. Word boundaries keep `latest(` from matching `test(`
    /// and `unit(` from matching `it(`.
    private static func lineDeclaresATest(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return lowercased.range(
            of: "(\\bit\\(|\\btest\\(|func\\s+test|def\\s+test_|@test\\b|\\bfun\\s+test)",
            options: .regularExpression
        ) != nil
    }

    /// Parse a repo-relative path out of a unified-diff file header line such as
    /// "+++ b/src/Foo.ts" or "--- a/src/Foo.ts". Strips the marker, an optional
    /// trailing tab-delimited timestamp, and the git `a/`/`b/` prefix; returns
    /// nil for the "/dev/null" side of an add or delete.
    private static func filePath(fromDiffHeaderLine headerLine: String, markerLength: Int) -> String? {
        let afterMarker = String(headerLine.dropFirst(markerLength))
        // git may append "\t<timestamp>" to the path; keep only the path.
        let pathField = afterMarker.components(separatedBy: "\t").first ?? afterMarker
        let trimmed = pathField.trimmingCharacters(in: .whitespaces)
        if trimmed == "/dev/null" || trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }

    /// A short display form for a path in a finding — the path itself, or
    /// "(unknown file)" when the diff gave us no header to attribute a line to.
    private static func displayPath(_ path: String) -> String {
        path.isEmpty ? "(unknown file)" : path
    }

    /// Mirrors `VerificationHarness.enforceDiffScope`'s notion of a test file so
    /// the two layers agree on what counts as test code.
    private static func looksLikeATestPath(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.contains("test")
            || lowercased.contains("spec")
            || lowercased.contains("__tests__")
    }

    /// True when a path is a snapshot artifact — Jest/Vitest `__snapshots__`
    /// dirs and `.snap` files, and syrupy's `.ambr`.
    private static func looksLikeASnapshotPath(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.contains("__snapshots__")
            || lowercased.hasSuffix(".snap")
            || lowercased.hasSuffix(".snap.js")
            || lowercased.hasSuffix(".ambr")
            || lowercased.hasSuffix(".snapshot")
    }

    /// True when a path is a source-code file in one of the languages the
    /// Feature Engine edits — the universe from which "the module under test"
    /// is drawn.
    private static func isRecognizedSourceCodePath(_ path: String) -> Bool {
        fileHasAnyExtension(path, [
            ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs",
            ".rs", ".py", ".java", ".kt", ".swift", ".go", ".rb", ".cs", ".php", ".scala",
        ])
    }

    /// True when a Rust path is an integration test under a `tests/` directory
    /// (mutating those is not the point; production code is).
    private static func isRustIntegrationTestPath(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.hasPrefix("tests/") || lowercased.contains("/tests/")
    }

    private static func fileHasAnyExtension(_ path: String, _ extensionsIncludingDot: [String]) -> Bool {
        let lowercased = path.lowercased()
        return extensionsIncludingDot.contains { lowercased.hasSuffix($0) }
    }

    /// Single-quote a string for safe use in a POSIX shell command, so a path
    /// or branch name with spaces or metacharacters cannot alter the command.
    /// Embedded single quotes are closed, escaped, and reopened — the standard
    /// `'\''` trick.
    private static func shellSingleQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

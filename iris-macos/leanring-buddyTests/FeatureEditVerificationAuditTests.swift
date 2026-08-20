//
//  FeatureEditVerificationAuditTests.swift
//  leanring-buddyTests
//
//  The anti-gaming scanners are the layer that stops "the maker grades its own
//  homework" (plan §9). These tests are adversarial by construction: each feeds
//  a crafted CHEATING diff and asserts the tamper is caught, and — just as
//  load-bearing — feeds CLEAN diffs and asserts they pass untouched, because a
//  scanner that flags honest work is as broken as one that misses a cheat.
//  Plus the mutation-command selection (right tool, scoped to changed source)
//  and the clean-clone plan that keeps the checker off the maker's dirty tree.
//
//  Pure logic, no processes: every input is a string, every output is a value.
//

import Foundation
import Testing
@testable import Iris

@Suite struct FeatureEditVerificationAuditTests {

    // MARK: - Tautological assertions

    @Test func tautologicalAssertionsInEveryDialectAreCaught() {
        // XCTest, Node's assert, and swift-testing's #expect — each with a
        // constant that is always true, so the "test" verifies nothing.
        let cheatingDiff = """
        diff --git a/Tests/FooTests.swift b/Tests/FooTests.swift
        --- a/Tests/FooTests.swift
        +++ b/Tests/FooTests.swift
        @@ -1,2 +1,7 @@
         import XCTest
        +    XCTAssertTrue(true)
        +    #expect(true)
        diff --git a/test/bar.test.js b/test/bar.test.js
        --- a/test/bar.test.js
        +++ b/test/bar.test.js
        @@ -1,1 +1,2 @@
         const assert = require('assert')
        +    assert.ok(1)
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: cheatingDiff)
        let tautologyFindings = findings.filter { $0.contains("tautological assertion") }
        #expect(tautologyFindings.count == 3)
    }

    @Test func pythonBareAssertTrueIsCaught() {
        let cheatingDiff = """
        --- a/tests/test_thing.py
        +++ b/tests/test_thing.py
        @@ -1,1 +1,2 @@
         import thing
        +    assert True
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: cheatingDiff)
        #expect(findings.contains { $0.contains("tautological assertion") })
    }

    @Test func aRealAssertionOverAVariableIsNotFlaggedAsTautological() {
        // The needle set encodes CONSTANTS only — a real assertion over an
        // expression (`add(1, 2)`, `count`) must never be swept up.
        let honestDiff = """
        --- a/Tests/CalcTests.swift
        +++ b/Tests/CalcTests.swift
        @@ -1,1 +1,3 @@
         import XCTest
        +    XCTAssertEqual(add(1, 2), 3)
        +    XCTAssertTrue(resultIsReady)
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: honestDiff)
        #expect(!findings.contains { $0.contains("tautological") })
    }

    // MARK: - Swallowed error handlers

    @Test func emptyCatchAndExceptPassAreCaught() {
        let cheatingDiff = """
        --- a/src/loader.js
        +++ b/src/loader.js
        @@ -1,1 +1,2 @@
         function load() {
        +  try { risky() } catch (e) {}
        diff --git a/src/reader.py b/src/reader.py
        --- a/src/reader.py
        +++ b/src/reader.py
        @@ -1,1 +1,3 @@
         def read():
        +    try:
        +        parse()
        +    except Exception: pass
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: cheatingDiff)
        let swallowFindings = findings.filter { $0.contains("swallowed error handler") }
        #expect(swallowFindings.count == 2)
    }

    @Test func aCatchWithARealBodyIsNotFlagged() {
        let honestDiff = """
        --- a/src/loader.js
        +++ b/src/loader.js
        @@ -1,1 +1,2 @@
         function load() {
        +  try { risky() } catch (e) { logger.error(e); throw e }
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: honestDiff)
        #expect(!findings.contains { $0.contains("swallowed") })
    }

    // MARK: - Focused / skipped tests

    @Test func focusedAndSkippedTestMarkersAreCaught() {
        let cheatingDiff = """
        --- a/test/suite.test.js
        +++ b/test/suite.test.js
        @@ -1,2 +1,4 @@
         describe('things', () => {
        +  it.only('the one I want green', () => {})
        +  describe.skip('everything else', () => {})
        diff --git a/Tests/EdgeTests.swift b/Tests/EdgeTests.swift
        --- a/Tests/EdgeTests.swift
        +++ b/Tests/EdgeTests.swift
        @@ -1,1 +1,2 @@
         func testEdge() {
        +    throw XCTSkip("later")
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: cheatingDiff)
        let skipFindings = findings.filter { $0.contains("focused/skipped test marker") }
        #expect(skipFindings.count == 3)
    }

    @Test func aSwiftUIDisabledModifierInProductionCodeIsNotMistakenForASkip() {
        // `.disabled(true)` is an everyday SwiftUI modifier; only a `.disabled`
        // on a `@Test` line is a skip. A prod view must pass clean.
        let honestDiff = """
        --- a/Sources/App/SettingsView.swift
        +++ b/Sources/App/SettingsView.swift
        @@ -1,1 +1,2 @@
         var body: some View {
        +    saveButton.disabled(true)
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: honestDiff)
        #expect(findings.isEmpty)
    }

    @Test func aSwiftTestingDisabledTraitIsCaught() {
        let cheatingDiff = """
        --- a/Tests/FlakyTests.swift
        +++ b/Tests/FlakyTests.swift
        @@ -1,1 +1,2 @@
         struct FlakyTests {
        +    @Test(.disabled("flaky")) func checksTheThing() {}
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: cheatingDiff)
        #expect(findings.contains { $0.contains("focused/skipped test marker") })
    }

    // MARK: - Snapshots

    @Test func aReRecordedSnapshotFileIsCaughtOncePerFile() {
        let cheatingDiff = """
        diff --git a/src/__snapshots__/Widget.test.js.snap b/src/__snapshots__/Widget.test.js.snap
        --- a/src/__snapshots__/Widget.test.js.snap
        +++ b/src/__snapshots__/Widget.test.js.snap
        @@ -1,2 +1,2 @@
        -Object { "label": "old" }
        +Object { "label": "new" }
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: cheatingDiff)
        let snapshotFindings = findings.filter { $0.contains("snapshot re-recorded") }
        #expect(snapshotFindings.count == 1)
    }

    @Test func aSnapshotUpdateFlagBakedIntoATestScriptIsCaught() {
        let cheatingDiff = """
        --- a/package.json
        +++ b/package.json
        @@ -1,1 +1,2 @@
         "scripts": {
        +    "test": "jest --updateSnapshot"
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: cheatingDiff)
        #expect(findings.contains { $0.contains("snapshot update flag") })
    }

    // MARK: - Mocking the module under test

    @Test func aTestThatMocksTheChangedModuleIsCaught() {
        // The change touches src/PaymentProcessor.ts and the test then mocks
        // exactly that module — so the test exercises the fake, not the change.
        let cheatingDiff = """
        diff --git a/src/PaymentProcessor.ts b/src/PaymentProcessor.ts
        --- a/src/PaymentProcessor.ts
        +++ b/src/PaymentProcessor.ts
        @@ -1,1 +1,2 @@
         export class PaymentProcessor {
        +  charge() { return this.gateway.submit() }
        diff --git a/test/PaymentProcessor.test.ts b/test/PaymentProcessor.test.ts
        --- a/test/PaymentProcessor.test.ts
        +++ b/test/PaymentProcessor.test.ts
        @@ -1,1 +1,3 @@
         import { PaymentProcessor } from '../src/PaymentProcessor'
        +jest.mock('../src/PaymentProcessor')
        +    expect(charged).toBe(true)
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: cheatingDiff)
        #expect(findings.contains { $0.contains("mocks the module under test") })
    }

    @Test func mockingAGenuineDependencyIsNotFlagged() {
        // Same changed module, but the test mocks `axios` (a real dependency) —
        // legitimate, and must not be flagged.
        let honestDiff = """
        diff --git a/src/PaymentProcessor.ts b/src/PaymentProcessor.ts
        --- a/src/PaymentProcessor.ts
        +++ b/src/PaymentProcessor.ts
        @@ -1,1 +1,2 @@
         export class PaymentProcessor {
        +  charge() { return http.post() }
        diff --git a/test/PaymentProcessor.test.ts b/test/PaymentProcessor.test.ts
        --- a/test/PaymentProcessor.test.ts
        +++ b/test/PaymentProcessor.test.ts
        @@ -1,1 +1,3 @@
         import { PaymentProcessor } from '../src/PaymentProcessor'
        +jest.mock('axios')
        +    expect(charged).toBe(true)
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: honestDiff)
        #expect(!findings.contains { $0.contains("mocks the module under test") })
    }

    // MARK: - Test/assertion count drops

    @Test func aNetDropInAssertionsIsCaught() {
        // Three real assertions removed, one added — the classic "delete what
        // would catch me", generalized to assertion count.
        let cheatingDiff = """
        --- a/Tests/CalcTests.swift
        +++ b/Tests/CalcTests.swift
        @@ -1,5 +1,3 @@
         func testAdd() {
        -    XCTAssertEqual(add(1, 2), 3)
        -    XCTAssertEqual(add(2, 2), 4)
        -    XCTAssertEqual(add(0, 0), 0)
        +    XCTAssertEqual(add(1, 1), 2)
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: cheatingDiff)
        #expect(findings.contains { $0.contains("assertion count dropped in tests") })
    }

    @Test func anExplicitBeforeAfterTestCountDropIsCaught() {
        let findings = FeatureEditVerificationAudit.cheatSignatures(
            inUnifiedDiff: "",
            declaredTestCountBefore: 47,
            declaredTestCountAfter: 40
        )
        #expect(findings == ["declared test count dropped from 47 to 40"])
    }

    @Test func anIncreasedTestCountIsNotADrop() {
        let findings = FeatureEditVerificationAudit.cheatSignatures(
            inUnifiedDiff: "",
            declaredTestCountBefore: 47,
            declaredTestCountAfter: 49
        )
        #expect(findings.isEmpty)
    }

    // MARK: - Clean diffs pass untouched

    @Test func aWholesomeFeatureDiffProducesNoFindings() {
        // A real feature: production code added, plus a genuine test with a
        // real assertion over an expression. Nothing here is a cheat.
        let cleanDiff = """
        diff --git a/src/greeting.ts b/src/greeting.ts
        --- a/src/greeting.ts
        +++ b/src/greeting.ts
        @@ -1,1 +1,3 @@
         export function greet(name: string) {
        +  return `hello ${name}`
        +}
        diff --git a/test/greeting.test.ts b/test/greeting.test.ts
        --- a/test/greeting.test.ts
        +++ b/test/greeting.test.ts
        @@ -1,1 +1,3 @@
         import { greet } from '../src/greeting'
        +  it('greets by name', () => {
        +    expect(greet('ada')).toBe('hello ada')
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: cleanDiff)
        #expect(findings.isEmpty)
    }

    @Test func aProductionOnlyRefactorProducesNoFindings() {
        let cleanDiff = """
        --- a/src/util.ts
        +++ b/src/util.ts
        @@ -1,2 +1,3 @@
         export function clamp(value: number, lo: number, hi: number) {
        +  if (value < lo) return lo
        +  return Math.min(value, hi)
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: cleanDiff)
        #expect(findings.isEmpty)
    }

    @Test func anEmptyDiffProducesNoFindings() {
        #expect(FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: "").isEmpty)
    }

    // MARK: - Multiple cheats accumulate

    @Test func severalDistinctCheatsInOneDiffAreEachReported() {
        let cheatingDiff = """
        --- a/test/mega.test.js
        +++ b/test/mega.test.js
        @@ -1,3 +1,5 @@
         describe('mega', () => {
        +  it.only('focus', () => {})
        +  assert.ok(1)
        +  try { go() } catch (e) {}
        """
        let findings = FeatureEditVerificationAudit.cheatSignatures(inUnifiedDiff: cheatingDiff)
        #expect(findings.contains { $0.contains("focused/skipped test marker") })
        #expect(findings.contains { $0.contains("tautological assertion") })
        #expect(findings.contains { $0.contains("swallowed error handler") })
        #expect(findings.count >= 3)
    }

    // MARK: - Mutation command selection

    @Test func nodeEcosystemSelectsStrykerScopedToChangedSourceOnly() {
        let command = FeatureEditVerificationAudit.mutationCommand(
            forEcosystem: "node/next",
            changedFiles: ["src/checkout.ts", "src/checkout.test.ts", "README.md"]
        )
        #expect(command != nil)
        #expect(command?.contains("stryker") == true)
        #expect(command?.contains("--mutate") == true)
        // The source file is a mutation target; the test file and the README
        // are not.
        #expect(command?.contains("'src/checkout.ts'") == true)
        #expect(command?.contains("checkout.test.ts") == false)
        #expect(command?.contains("README.md") == false)
    }

    @Test func rustEcosystemSelectsCargoMutantsAndExcludesIntegrationTests() {
        let command = FeatureEditVerificationAudit.mutationCommand(
            forEcosystem: "rust/tauri",
            changedFiles: ["src/lib.rs", "tests/integration.rs"]
        )
        #expect(command?.contains("cargo mutants") == true)
        #expect(command?.contains("--file 'src/lib.rs'") == true)
        #expect(command?.contains("integration.rs") == false)
    }

    @Test func pythonEcosystemSelectsMutmutScopedToChangedSource() {
        let command = FeatureEditVerificationAudit.mutationCommand(
            forEcosystem: "python/uv",
            changedFiles: ["app/service.py", "tests/test_service.py"]
        )
        #expect(command?.contains("mutmut run") == true)
        #expect(command?.contains("--paths-to-mutate") == true)
        #expect(command?.contains("app/service.py") == true)
        #expect(command?.contains("test_service.py") == false)
    }

    @Test func jvmMavenSelectsThePitMavenGoalWithFullyQualifiedClasses() {
        let command = FeatureEditVerificationAudit.mutationCommand(
            forEcosystem: "jvm/maven",
            changedFiles: ["src/main/java/com/shop/Cart.java"]
        )
        #expect(command?.contains("pitest-maven:mutationCoverage") == true)
        #expect(command?.contains("com.shop.Cart") == true)
    }

    @Test func jvmGradleSelectsThePitGradleTask() {
        let command = FeatureEditVerificationAudit.mutationCommand(
            forEcosystem: "jvm/gradle",
            changedFiles: ["src/main/kotlin/com/shop/Cart.kt"]
        )
        #expect(command?.contains("gradlew pitest") == true)
        #expect(command?.contains("com.shop.Cart") == true)
    }

    @Test func swiftEcosystemHasNoMutationToolSoReturnsNil() {
        // Honest "no gate" rather than a wrong one — Swift has no first-class
        // mutation tester in the plan's roster.
        let command = FeatureEditVerificationAudit.mutationCommand(
            forEcosystem: "swift/xcode",
            changedFiles: ["Sources/App/Model.swift"]
        )
        #expect(command == nil)
    }

    @Test func anEcosystemWithNoChangedMutatableSourceReturnsNil() {
        // Only docs/tests changed — nothing to mutate, so no command.
        let command = FeatureEditVerificationAudit.mutationCommand(
            forEcosystem: "node/next",
            changedFiles: ["README.md", "src/checkout.test.ts"]
        )
        #expect(command == nil)
    }

    // MARK: - Clean-clone verify plan (maker != checker)

    @Test func theCleanClonePlanCheckoutIsOutsideTheMakersTree() {
        let repoRootPath = "/Users/dev/apps/notetion"
        let plan = FeatureEditVerificationAudit.cleanCloneVerifyPlan(
            repoRootPath: repoRootPath,
            branch: "feature/iris-edit-123"
        )
        // The checker checkout must never be the maker's own tree.
        #expect(plan.freshCheckoutPath != repoRootPath)
        #expect(!plan.freshCheckoutPath.hasPrefix(repoRootPath))
        #expect(plan.freshCheckoutPath.contains("iris-clean-verify"))
    }

    @Test func theCleanClonePlanClonesTheCommittedBranchIndependently() {
        let repoRootPath = "/Users/dev/apps/notetion"
        let branch = "feature/iris-edit-123"
        let plan = FeatureEditVerificationAudit.cleanCloneVerifyPlan(
            repoRootPath: repoRootPath,
            branch: branch
        )
        let cloneCommand = plan.checkoutCommands.first ?? ""
        #expect(cloneCommand.contains("git clone"))
        // --no-local forces a copied object store, so the checker tree shares
        // nothing writable with the maker's repo.
        #expect(cloneCommand.contains("--no-local"))
        #expect(cloneCommand.contains("--single-branch"))
        #expect(cloneCommand.contains("'\(branch)'"))
        #expect(cloneCommand.contains("'\(repoRootPath)'"))
        #expect(cloneCommand.contains(plan.freshCheckoutPath))
        // Teardown removes exactly the throwaway checkout.
        #expect(plan.teardownCommand.contains("rm -rf"))
        #expect(plan.teardownCommand.contains("'\(plan.freshCheckoutPath)'"))
    }

    @Test func theCleanClonePlanDetachesSoItCannotAdvanceTheBranch() {
        let plan = FeatureEditVerificationAudit.cleanCloneVerifyPlan(
            repoRootPath: "/Users/dev/apps/notetion",
            branch: "main"
        )
        #expect(plan.checkoutCommands.contains { $0.contains("checkout") && $0.contains("--detach") })
    }

    @Test func aBranchNameWithSpacesIsSafelyQuoted() {
        // A hostile or unusual branch/path must not be able to break out of the
        // command it is interpolated into.
        let plan = FeatureEditVerificationAudit.cleanCloneVerifyPlan(
            repoRootPath: "/tmp/weird repo",
            branch: "feat x; rm -rf /"
        )
        let cloneCommand = plan.checkoutCommands.first ?? ""
        #expect(cloneCommand.contains("'feat x; rm -rf /'"))
        #expect(cloneCommand.contains("'/tmp/weird repo'"))
    }

    @Test func twoPlansGetDistinctThrowawayCheckouts() {
        // Per-run unique dirs so concurrent verifications never collide.
        let first = FeatureEditVerificationAudit.cleanCloneVerifyPlan(repoRootPath: "/a", branch: "main")
        let second = FeatureEditVerificationAudit.cleanCloneVerifyPlan(repoRootPath: "/a", branch: "main")
        #expect(first.freshCheckoutPath != second.freshCheckoutPath)
    }
}

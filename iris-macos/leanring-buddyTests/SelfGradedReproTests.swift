//
//  SelfGradedReproTests.swift
//  leanring-buddyTests
//
//  The screen that stops a model grading itself.
//
//  Every case here is drawn from a real observation, not invented: on
//  2026-08-26 the edit battery watched a run rewrite `src/parser.rs` — inline
//  `#[cfg(test)]` module and all — then offer `cargo test --quiet --lib` as its
//  repro. `--lib` runs the library target's tests, which live in `src/`, so the
//  model was graded by tests it had just written. It passed. The engine
//  reported "applied, built, suite green" for a tree that did not COMPILE
//  against the held-out suite.
//
//  The existing `reproMerelyReReadsTheChange` screen could not catch it: that
//  one rejects a repro that merely READS a changed file, and explicitly lets
//  anything through that genuinely runs code — which `cargo test` does.
//

import Foundation
import Testing
@testable import Iris

struct SelfGradedReproTests {

    // MARK: - The case that got through

    @Test("the cargo --lib repro that graded a model by its own inline tests is refused")
    func theRustInlineTestReproIsRefused() {
        let reason = MaintainTierCFixer.reproIsGradedByTestsThisChangeWrote(
            "cargo test --offline --quiet --lib 2>&1 | grep -q \"test result: ok\"",
            changedPaths: ["src/parser.rs"]
        )
        #expect(reason != nil)
        #expect(reason?.contains("src/parser.rs") == true)
    }

    @Test("the same repro is fine when the change did not touch the crate's source")
    func theSameReproSurvivesWhenTheChangeIsElsewhere() {
        // Only `docs/` changed — the inline tests are not this change's work,
        // so running them is a real check.
        #expect(MaintainTierCFixer.reproIsGradedByTestsThisChangeWrote(
            "cargo test --quiet --lib", changedPaths: ["docs/GRAMMAR.md"]
        ) == nil)
    }

    @Test("every cargo flag that selects an in-source test target is covered")
    func allInlineTargetFlagsAreCovered() {
        for flag in ["--lib", "--bins", "--bin", "--doc"] {
            let reason = MaintainTierCFixer.reproIsGradedByTestsThisChangeWrote(
                "cargo test \(flag) app", changedPaths: ["src/main.rs"]
            )
            #expect(reason != nil, "\(flag) should be refused")
        }
    }

    @Test("a cargo --test target the change authored is refused")
    func anAuthoredIntegrationTargetIsRefused() {
        let reason = MaintainTierCFixer.reproIsGradedByTestsThisChangeWrote(
            "cargo test --test parser_spec", changedPaths: ["tests/parser_spec.rs"]
        )
        #expect(reason?.contains("parser_spec") == true)
    }

    @Test("a cargo --test target the change did NOT author is allowed")
    func anUntouchedIntegrationTargetIsAllowed() {
        #expect(MaintainTierCFixer.reproIsGradedByTestsThisChangeWrote(
            "cargo test --test oracle", changedPaths: ["src/parser.rs", "tests/parser_spec.rs"]
        ) == nil)
    }

    // MARK: - Naming a test file the change wrote, in any language

    @Test("a repro pointed at a test file this change wrote is refused")
    func aRunnerPointedAtAnAuthoredTestFileIsRefused() {
        let cases: [(String, [String])] = [
            ("pytest tests/test_csvlite.py -q", ["tests/test_csvlite.py"]),
            ("npx vitest run src/money.test.js", ["src/money.test.js"]),
            ("npm test -- filters.spec.ts", ["src/filters.spec.ts"]),
        ]
        for (command, changed) in cases {
            #expect(
                MaintainTierCFixer.reproIsGradedByTestsThisChangeWrote(command, changedPaths: changed) != nil,
                "should refuse: \(command)"
            )
        }
    }

    // MARK: - What must STILL be allowed

    /// The screen is about WHO WROTE the tests, not about how narrow the repro
    /// is. A tightly-scoped repro aimed at the reported symptom is exactly what
    /// the protocol asks for, and refusing those would gut the only path from
    /// "applied" to "verified".
    @Test("a narrow repro against a test the change did not write is allowed")
    func aNarrowReproAgainstSomebodyElsesTestIsAllowed() {
        let allowed: [(String, [String])] = [
            // Narrow, targeted, and the test is pre-existing.
            ("pytest tests/test_csvlite.py::test_quotes -q", ["src/csvlite.py"]),
            ("npx vitest run src/money.test.js", ["src/money.js"]),
            ("cargo test --test oracle", ["src/parser.rs"]),
            // The repo's own whole suite is always fine.
            ("npm test", ["src/money.js"]),
            ("cargo test", ["src/parser.rs"]),
            // A real symptom reproduction that runs the program.
            ("node -e \"assert.equal(require('./src/money').split(1000,3).length,3)\"", ["src/money.js"]),
        ]
        for (command, changed) in allowed {
            #expect(
                MaintainTierCFixer.reproIsGradedByTestsThisChangeWrote(command, changedPaths: changed) == nil,
                "should allow: \(command)"
            )
        }
    }

    /// A DIRECTORY-scoped run is deliberately allowed, even when the change
    /// added a test file inside that directory.
    ///
    /// `go test ./parser` with a new `parser/parser_test.go` in the change
    /// LOOKS self-graded, and sometimes is — but the same command also runs
    /// every pre-existing test in that package, which the model did not write.
    /// A pure function cannot tell those apart without reading the repository,
    /// and guessing wrong in this direction has a real cost: it would discard
    /// honest repros and quietly cap good fixes at "applied". So the screen
    /// stays quiet. This is a KNOWN LIMIT, not an oversight — the narrower,
    /// unambiguous cases above are the ones it takes.
    @Test("a directory-scoped run is allowed even when the change added a test in it")
    func aDirectoryScopedRunIsAKnownLimit() {
        #expect(MaintainTierCFixer.reproIsGradedByTestsThisChangeWrote(
            "go test ./parser -run TestAssoc", changedPaths: ["parser/parser_test.go"]
        ) == nil)
    }

    @Test("an empty change or an empty command is not an accusation")
    func theScreenIsQuietWithNothingToJudge() {
        #expect(MaintainTierCFixer.reproIsGradedByTestsThisChangeWrote("cargo test --lib", changedPaths: []) == nil)
        #expect(MaintainTierCFixer.reproIsGradedByTestsThisChangeWrote("", changedPaths: ["src/parser.rs"]) == nil)
        #expect(MaintainTierCFixer.reproIsGradedByTestsThisChangeWrote(
            "cargo test --lib", changedPaths: [""]
        ) == nil)
    }

    /// A short basename must not collide with ordinary words — the same
    /// guard `reproMerelyReReadsTheChange` already applies, for the same reason.
    @Test("a short test file name does not trigger on an unrelated word")
    func aShortNameDoesNotFalselyAccuse() {
        #expect(MaintainTierCFixer.reproIsGradedByTestsThisChangeWrote(
            "npm run build && npm test", changedPaths: ["t.js"]
        ) == nil)
    }
}

// MARK: - A broken edit block must not eat a good move that rode with it

/// The second defect the adversarial review caught on 2026-08-26: the steer
/// that reports an unreadable ```write/```edit block ran BEFORE BLOCKED, DONE,
/// the manifest parse and `extractBashCommand`, and it `continue`s — so a reply
/// carrying a truncated block AND a legal move had the legal move discarded.
///
/// The realistic producer of a truncated block is the output cap cutting a
/// reply mid-write, and such a reply can easily also carry a genuine `BLOCKED:`
/// that the reader is waiting on.
@MainActor
struct BrokenEditBlockDoesNotEatALegalMoveTests {

    @Test("a reply with only a broken edit block has nothing else to act on")
    func aBrokenBlockAloneIsStillSteered() {
        let reply = """
        Writing the fix now.

        ```write src/app.js
        export function go() {
        """
        #expect(!MaintainTierCFixer.replyCarriesALegalMoveBesidesFileEdits(reply))
    }

    @Test("a BLOCKED riding a truncated write block survives")
    func aBlockedSurvivesATruncatedWrite() {
        let reply = """
        ```write docs/NOTES.md
        # Notes

        BLOCKED: the signing key lives in the vendor's key service and is not in this repository.
        """
        #expect(MaintainTierCFixer.replyCarriesALegalMoveBesidesFileEdits(reply))
    }

    @Test("a DONE riding a broken block survives")
    func aDoneSurvivesABrokenBlock() {
        let reply = """
        ```edit src/app.js
        <<<<<<< SEARCH
        broken

        DONE
        """
        #expect(MaintainTierCFixer.replyCarriesALegalMoveBesidesFileEdits(reply))
    }

    @Test("a runnable command riding a broken block survives")
    func aCommandSurvivesABrokenBlock() {
        let reply = """
        Checking the other caller first.

        ```bash
        grep -rn "parseRow" src/
        ```

        ```write src/app.js
        export function go() {
        """
        #expect(MaintainTierCFixer.replyCarriesALegalMoveBesidesFileEdits(reply))
    }

    @Test("prose alone is not a legal move")
    func proseAloneIsNotAMove() {
        #expect(!MaintainTierCFixer.replyCarriesALegalMoveBesidesFileEdits(
            "I think the problem is probably in the parser somewhere."
        ))
        #expect(!MaintainTierCFixer.replyCarriesALegalMoveBesidesFileEdits(""))
    }

    /// "DONE" inside a sentence is not a declaration — the loop wants it alone
    /// on its line, and this predicate must agree or it would rescue replies
    /// the dispatch cannot actually act on.
    @Test("the word done inside prose does not count")
    func doneInsideProseDoesNotCount() {
        #expect(!MaintainTierCFixer.replyCarriesALegalMoveBesidesFileEdits(
            "Once the parser is fixed we are DONE with this part."
        ))
    }
}

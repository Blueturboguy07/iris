//
//  MaintainFileEditApplierTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import Iris

@Suite struct MaintainFileEditApplierTests {

    private static func makeRepo() -> String {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-fileedit-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        return repo
    }

    @Test func parsesWholeFileWritePreservingPathCase() {
        let reply = "Rewriting it.\n```write src/Foo.rs\nfn main() {}\nlet x = 1;\n```"
        let requests = MaintainFileEditApplier.parse(fromModelReply: reply)
        #expect(requests == [.writeWholeFile(filePath: "src/Foo.rs", content: "fn main() {}\nlet x = 1;")])
    }

    @Test func parsesSearchReplaceEdit() {
        let reply = "```edit src/a.rs\n<<<<<<< SEARCH\nold line\n=======\nnew line\n>>>>>>> REPLACE\n```"
        let requests = MaintainFileEditApplier.parse(fromModelReply: reply)
        #expect(requests == [.replaceInFile(filePath: "src/a.rs", search: "old line", replace: "new line")])
    }

    @Test func writeCreatesAndReplacesFileContentsAtomically() throws {
        let repo = Self.makeRepo(); defer { try? FileManager.default.removeItem(atPath: repo) }
        let result = MaintainFileEditApplier.applyToRepo(
            .writeWholeFile(filePath: "src/new.rs", content: "line1\nline2\n"), repoRootPath: repo
        )
        #expect((try? result.get()) != nil)
        #expect((try? String(contentsOfFile: repo + "/src/new.rs", encoding: .utf8)) == "line1\nline2\n")
    }

    @Test func replaceRequiresExactlyOneMatch() throws {
        let repo = Self.makeRepo(); defer { try? FileManager.default.removeItem(atPath: repo) }
        try "a\nTARGET\nb\nTARGET\n".write(toFile: repo + "/f.txt", atomically: true, encoding: .utf8)
        // Two matches → refused, file untouched.
        let twice = MaintainFileEditApplier.applyToRepo(
            .replaceInFile(filePath: "f.txt", search: "TARGET", replace: "X"), repoRootPath: repo
        )
        if case .failure(.searchTextFoundMoreThanOnce) = twice {} else { Issue.record("expected ambiguous-match refusal") }
        #expect((try? String(contentsOfFile: repo + "/f.txt", encoding: .utf8)) == "a\nTARGET\nb\nTARGET\n")
        // A unique match applies.
        try "a\nONLY\nb\n".write(toFile: repo + "/g.txt", atomically: true, encoding: .utf8)
        _ = MaintainFileEditApplier.applyToRepo(
            .replaceInFile(filePath: "g.txt", search: "ONLY", replace: "DONE"), repoRootPath: repo
        )
        #expect((try? String(contentsOfFile: repo + "/g.txt", encoding: .utf8)) == "a\nDONE\nb\n")
    }

    @Test func buildScriptFilesAreRefusedAndRouteToManifest() {
        let repo = Self.makeRepo(); defer { try? FileManager.default.removeItem(atPath: repo) }
        let result = MaintainFileEditApplier.applyToRepo(
            .writeWholeFile(filePath: "Cargo.toml", content: "[package]\n"), repoRootPath: repo
        )
        if case .failure(.fileIsABuildScript) = result {} else { Issue.record("expected build-script refusal") }
    }

    @Test func pathEscapesAreRefused() {
        let repo = Self.makeRepo(); defer { try? FileManager.default.removeItem(atPath: repo) }
        for bad in ["../evil.rs", "/etc/passwd", "~/secret", "a/../../b.rs"] {
            let result = MaintainFileEditApplier.applyToRepo(
                .writeWholeFile(filePath: bad, content: "x"), repoRootPath: repo
            )
            if case .failure = result {} else { Issue.record("\(bad) should be refused") }
        }
    }
}

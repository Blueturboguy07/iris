//
//  FeatureEditRepositoryContextTests.swift
//  leanring-buddyTests
//
//  Focused checks for the bounded unchanged-source context used by the
//  adversarial reviewer. These tests exercise path confinement, byte bounds,
//  source/doc allowlisting, and the distinction between missing evidence and a
//  demonstrated issue.
//

import Foundation
import Darwin
import Testing
@testable import Iris

@Suite struct FeatureEditRepositoryContextTests {

    @Test func collectsOnlyExplicitEligibleFilesAndLabelsCoverage() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try write("src/filter.js", contents: "function applyOne(row) { return row >= 0; }\n", under: temporaryRoot)
        try write("src/operators.js", contents: "export function eq(left, right) { return left === right; }\n", under: temporaryRoot)
        try write("README.md", contents: "The filter keeps numeric rows.\n", under: temporaryRoot)
        try write("package.json", contents: "{\"scripts\":{\"test\":\"node test.js\"}}\n", under: temporaryRoot)

        let context = FeatureEditRepositoryContext.collect(
            repoRootPath: temporaryRoot,
            relativePaths: ["src/filter.js", "src/operators.js", "README.md", "package.json"],
            maxBytes: 1024
        )

        #expect(context.files.map(\.repoRelativePath) == ["src/filter.js", "src/operators.js", "README.md"])
        #expect(context.omittedFileCount == 1)
        #expect(context.promptSection.contains("BEGIN REPOSITORY FILE: src/filter.js"))
        #expect(!context.promptSection.contains("\"scripts\""))
        #expect(context.promptSection.contains("Paths not shown were not inspected"))
    }

    @Test func doesNotPartiallyIncludeAFileWhenTheByteBudgetIsTooSmall() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try write("src/first.js", contents: "12345678", under: temporaryRoot)
        try write("src/second.js", contents: "abcdefgh", under: temporaryRoot)

        let context = FeatureEditRepositoryContext.collect(
            repoRootPath: temporaryRoot.path,
            relativePaths: ["src/first.js", "src/second.js"],
            maxBytes: 10
        )

        #expect(context.files.count == 1)
        #expect(context.files[0].repoRelativePath == "src/first.js")
        #expect(context.files[0].utf8Text == "12345678")
        #expect(context.includedByteCount == 8)
        #expect(context.omittedFileCount == 1)
        #expect(context.maxBytes == 10)
    }

    @Test func rejectsTraversalHiddenConfigAndUnsupportedPaths() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try write("src/allowed.swift", contents: "struct Allowed {}", under: temporaryRoot)
        try write(".env", contents: "TOKEN=do-not-read", under: temporaryRoot)
        try write("config.json", contents: "{\"token\":\"do-not-read\"}", under: temporaryRoot)
        try write("image.png", contents: "not source", under: temporaryRoot)

        let context = FeatureEditRepositoryContext.collect(
            repoRootPath: temporaryRoot,
            relativePaths: [
                "src/allowed.swift",
                "../outside.swift",
                ".env",
                "config.json",
                "image.png",
                "/etc/passwd",
                "src/../allowed.swift",
            ],
            maxBytes: 4096
        )

        #expect(context.files.map(\.repoRelativePath) == ["src/allowed.swift"])
        #expect(context.omittedFileCount == 6)
        #expect(!context.promptSection.contains("do-not-read"))
    }

    @Test func rejectsAFileSymlinkEvenWhenItsTargetIsInsideTheRoot() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try write("src/real.swift", contents: "struct Real {}", under: temporaryRoot)
        let linkURL = temporaryRoot.appendingPathComponent("src/link.swift")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: temporaryRoot.appendingPathComponent("src/real.swift")
        )

        let context = FeatureEditRepositoryContext.collect(
            repoRootPath: temporaryRoot,
            relativePaths: ["src/link.swift"],
            maxBytes: 4096
        )

        #expect(context.files.isEmpty)
        #expect(context.omittedFileCount == 1)
    }

    @Test func rejectsASymbolicLinkUsedAsTheRepositoryRoot() throws {
        let temporaryRoot = try makeTemporaryRoot()
        let linkedRoot = temporaryRoot
            .deletingLastPathComponent()
            .appendingPathComponent("iris-review-context-link-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: linkedRoot)
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        try write("src/real.swift", contents: "struct Real {}", under: temporaryRoot)
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: temporaryRoot
        )

        let context = FeatureEditRepositoryContext.collect(
            repoRootPath: linkedRoot,
            relativePaths: ["src/real.swift"],
            maxBytes: 4096
        )

        #expect(context.files.isEmpty)
        #expect(context.omittedFileCount == 1)
    }

    @Test func rejectsAnIntermediateDirectorySymlink() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try write("target/real.swift", contents: "struct Real {}", under: temporaryRoot)
        let linkURL = temporaryRoot.appendingPathComponent("src/link", isDirectory: true)
        try FileManager.default.createDirectory(
            at: linkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: temporaryRoot.appendingPathComponent("target", isDirectory: true)
        )

        let context = FeatureEditRepositoryContext.collect(
            repoRootPath: temporaryRoot,
            relativePaths: ["src/link/real.swift"],
            maxBytes: 4096
        )

        #expect(context.files.isEmpty)
        #expect(context.omittedFileCount == 1)
    }

    @Test func rejectsAFIFOWithoutBlocking() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let fifoURL = temporaryRoot.appendingPathComponent("src/pipe.swift")
        try FileManager.default.createDirectory(
            at: fifoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard mkfifo(fifoURL.path, mode_t(0o600)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let start = Date()
        let context = FeatureEditRepositoryContext.collect(
            repoRootPath: temporaryRoot,
            relativePaths: ["src/pipe.swift"],
            maxBytes: 4096
        )

        #expect(context.files.isEmpty)
        #expect(context.omittedFileCount == 1)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func nilReviewerContextStatesThatUnseenCodeIsNotAProvenDefect() {
        let (system, user) = FeatureEditAdversarialReviewer.reviewPrompt(
            request: "Add numeric row filtering",
            kind: .feature,
            unifiedDiff: "+function applyOne(row) {}",
            evidenceLog: []
        )

        #expect(system.contains("INSUFFICIENT:"))
        #expect(!system.contains("(insufficiencyLineMarker)"))
        #expect(user.contains("none was supplied"))
        #expect(user.contains("unseen context"))
        #expect(user.contains("not evidence that they are absent"))
    }

    @Test func boundedReviewerContextIsIncludedAsUntrustedEvidence() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try write("src/filter.js", contents: "function applyOne(row) { return row >= 0; }", under: temporaryRoot)

        let context = FeatureEditRepositoryContext.collect(
            repoRootPath: temporaryRoot,
            relativePaths: ["src/filter.js"],
            maxBytes: 4096
        )
        let (_, user) = FeatureEditAdversarialReviewer.reviewPrompt(
            request: "Add numeric row filtering",
            kind: .feature,
            unifiedDiff: "+function applyOne(row) {}",
            evidenceLog: ["Tests: 16/16"],
            repositoryContext: context
        )

        #expect(user.contains("BEGIN REPOSITORY FILE: src/filter.js"))
        #expect(user.contains("return row >= 0"))
        #expect(user.contains("untrusted read-only evidence"))
        #expect(!user.contains("none was supplied"))
    }

    @Test func insufficiencyIsFailClosedButKeptSeparateFromProvenIssues() {
        let reply = """
        INSUFFICIENT: The unchanged caller is outside the supplied context.
        VERDICT: DISQUALIFYING
        """
        let verdict = FeatureEditAdversarialReviewer.parse(reply: reply)

        #expect(verdict.isDisqualifying)
        #expect(verdict.issues.isEmpty)
        #expect(verdict.insufficiencies == ["The unchanged caller is outside the supplied context."])
        #expect(verdict.readerFacingIssues == [
            "INSUFFICIENT CONTEXT: The unchanged caller is outside the supplied context.",
        ])
    }

    @Test func anInsufficiencyCannotHideUnderACleanVerdict() {
        let verdict = FeatureEditAdversarialReviewer.parse(
            reply: "INSUFFICIENT: The validator was not supplied.\nVERDICT: CLEAN"
        )

        #expect(verdict.isDisqualifying)
        #expect(verdict.issues.isEmpty)
        #expect(verdict.insufficiencies.count == 1)
    }

    @Test func anEmptyInsufficiencyMarkerIsMalformedAndCannotClear() {
        let verdict = FeatureEditAdversarialReviewer.parse(
            reply: "INSUFFICIENT:\nVERDICT: CLEAN"
        )

        #expect(verdict.isDisqualifying)
        #expect(verdict.issues.isEmpty)
        #expect(verdict.insufficiencies.count == 1)
        #expect(verdict.insufficiencies[0].contains("empty insufficiency marker"))
    }

    @Test func aProvenIssueAndInsufficiencyRemainDistinct() {
        let verdict = FeatureEditAdversarialReviewer.parse(
            reply: """
            ISSUE: The diff drops the lower-bound guard.
            INSUFFICIENT: The unrelated caller was not supplied.
            VERDICT: DISQUALIFYING
            """
        )

        #expect(verdict.issues == ["The diff drops the lower-bound guard."])
        #expect(verdict.insufficiencies == ["The unrelated caller was not supplied."])
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-review-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ relativePath: String, contents: String, under root: URL) throws {
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

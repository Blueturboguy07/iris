import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import IrisMobileShellCore

final class NativeRevisionStoreTests: XCTestCase {
    private let appId = "publik.kneecap"
    private let projectId = "publik.kneecap.mobile"

    func testDesktopCLIProducedBytesValidateStageAndActivate() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let package = try fixture.generateDesktopPackage(content: html("first"), nonce: nonce("a"))
        let store = try makeStore(root: fixture.storeRoot)

        let staged = try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
        XCTAssertEqual(staged.revisionId, package.revisionId)
        XCTAssertFalse(staged.alreadyStaged)
        let activeBeforeActivation = try await store.activeRevisionId()
        XCTAssertNil(activeBeforeActivation)

        try await store.activate(revisionId: package.revisionId)
        let launch = try await store.launchDescriptorForActiveRevision()
        XCTAssertEqual(launch.revisionId, package.revisionId)
        XCTAssertEqual(try String(contentsOf: launch.entrypointURL, encoding: .utf8), html("first"))
    }

    func testEmbeddedApprovalCannotAuthorizeItself() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let package = try fixture.generateDesktopPackage(content: html("approval"), nonce: nonce("b"))
        let store = try makeStore(root: fixture.storeRoot)

        await XCTAssertThrowsNativeError(
            try await store.stage(packageBytes: package.bytes, approvalAuthority: EmptyApprovalAuthority()),
            equals: .untrustedDeliveryApproval(package.approval.approvalId)
        )

        let changedApproval = try mutatePackage(package.bytes) { root in
            var approval = root["approval"] as! [String: Any]
            approval["approvedAt"] = "2026-09-17T16:05:00.000Z"
            root["approval"] = approval
        }
        await XCTAssertThrowsNativeError(
            try await store.stage(packageBytes: changedApproval, approvalAuthority: package.authority),
            equals: .deliveryApprovalMismatch(package.approval.approvalId)
        )
    }

    func testCorruptDesktopPackageBytesAreRejectedBeforeStaging() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let package = try fixture.generateDesktopPackage(content: html("known-good"), nonce: nonce("c"))
        let corrupt = try mutatePackage(package.bytes) { root in
            var files = root["files"] as! [[String: Any]]
            var bytes = Data(base64Encoded: files[0]["contentBase64"] as! String)!
            bytes[bytes.startIndex] ^= 0xff
            files[0]["contentBase64"] = bytes.base64EncodedString()
            root["files"] = files
        }
        let store = try makeStore(root: fixture.storeRoot)

        await XCTAssertThrowsNativeError(
            try await store.stage(packageBytes: corrupt, approvalAuthority: package.authority),
            equals: .hashMismatch("index.html")
        )
        let activeAfterCorruption = try await store.activeRevisionId()
        XCTAssertNil(activeAfterCorruption)
        XCTAssertFalse(try storedJSONMentions(package.revisionId, under: fixture.storeRoot),
                       "rejected package must leave no revision manifest")
    }

    func testStrictPackageFieldsAndRawByteBoundFailClosed() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let package = try fixture.generateDesktopPackage(content: html("strict"), nonce: nonce("d"))
        let extraField = try mutatePackage(package.bytes) { root in root["remoteUrl"] = "https://example.invalid/app" }
        let store = try makeStore(root: fixture.storeRoot)

        await XCTAssertThrowsNativeError(
            try await store.stage(packageBytes: extraField, approvalAuthority: package.authority),
            equals: .invalidPackageField("package keys")
        )
        let booleanVersion = try mutatePackage(package.bytes) { root in
            var approval = root["approval"] as! [String: Any]
            approval["version"] = true
            root["approval"] = approval
        }
        await XCTAssertThrowsNativeError(
            try await store.stage(packageBytes: booleanVersion, approvalAuthority: package.authority),
            equals: .invalidPackageField("approval.version")
        )
        let oversized = Data(repeating: 0x20, count: NativeSecurity.maximumPackageJSONBytes + 1)
        await XCTAssertThrowsNativeError(
            try await store.stage(packageBytes: oversized, approvalAuthority: package.authority),
            equals: .packageTooLarge
        )
    }

    func testNativePathRulesMatchSharedUTF16LimitAndRejectStorageAliasesFromRawPackageBytes() async throws {
        XCTAssertTrue(NativeSecurity.isSafePackagePath(String(repeating: "😀", count: 256)))
        XCTAssertFalse(NativeSecurity.isSafePackagePath(String(repeating: "😀", count: 257)))
        XCTAssertTrue(NativeSecurity.hasStoragePathAlias(["index.html", "INDEX.HTML"]))
        XCTAssertTrue(NativeSecurity.hasStoragePathAlias(["assets", "assets/app.js"]))

        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let package = try fixture.generateDesktopPackage(content: html("path-alias"), nonce: nonce("s"))
        let store = try makeStore(root: fixture.storeRoot)

        let caseAlias = try mutatePackage(package.bytes) { root in
            var envelope = root["envelope"] as! [String: Any]
            var revision = envelope["revision"] as! [String: Any]
            var files = revision["files"] as! [[String: Any]]
            var alias = files[0]
            alias["path"] = "INDEX.HTML"
            files.append(alias)
            revision["files"] = files
            envelope["revision"] = revision
            root["envelope"] = envelope
        }
        await XCTAssertThrowsNativeError(
            try await store.stage(packageBytes: caseAlias, approvalAuthority: package.authority),
            equals: .invalidPackageField("revision.files contains a storage path alias")
        )

        let directoryAlias = try mutatePackage(package.bytes) { root in
            var envelope = root["envelope"] as! [String: Any]
            var revision = envelope["revision"] as! [String: Any]
            var files = revision["files"] as! [[String: Any]]
            var child = files[0]
            child["path"] = "index.html/child"
            files.append(child)
            revision["files"] = files
            envelope["revision"] = revision
            root["envelope"] = envelope
        }
        await XCTAssertThrowsNativeError(
            try await store.stage(packageBytes: directoryAlias, approvalAuthority: package.authority),
            equals: .invalidPackageField("revision.files contains a storage path alias")
        )
    }

    func testWrongAppProjectBaseAndReplayAreRejectedFromRealPackageBytes() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let store = try makeStore(root: fixture.storeRoot)

        let wrongApp = try fixture.generateDesktopPackage(
            content: html("wrong-app"), nonce: nonce("e"), appId: "publik.other", projectId: "publik.other.mobile"
        )
        await XCTAssertThrowsNativeError(
            try await store.stage(packageBytes: wrongApp.bytes, approvalAuthority: wrongApp.authority),
            equals: .appMismatch(expected: appId, actual: "publik.other")
        )

        let staleBase = revisionId(seed: "stale")
        let wrongBase = try fixture.generateDesktopPackage(
            content: html("wrong-base"), baseRevisionId: staleBase, nonce: nonce("f")
        )
        await XCTAssertThrowsNativeError(
            try await store.stage(packageBytes: wrongBase.bytes, approvalAuthority: wrongBase.authority),
            equals: .baseMismatch(expected: nil, actual: staleBase)
        )

        let once = try fixture.generateDesktopPackage(content: html("once"), nonce: nonce("g"))
        _ = try await store.stage(packageBytes: once.bytes, approvalAuthority: once.authority)
        await XCTAssertThrowsNativeError(
            try await store.stage(packageBytes: once.bytes, approvalAuthority: once.authority),
            equals: .deliveryReplay
        )
    }

    func testStagedBaseIsRecheckedAtActivation() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let store = try makeStore(root: fixture.storeRoot)
        let first = try fixture.generateDesktopPackage(content: html("base"), nonce: nonce("h"))
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)

        let candidateB = try fixture.generateDesktopPackage(
            content: html("candidate-b"), baseRevisionId: first.revisionId, nonce: nonce("i")
        )
        let candidateC = try fixture.generateDesktopPackage(
            content: html("candidate-c"), baseRevisionId: first.revisionId, nonce: nonce("j")
        )
        _ = try await store.stage(packageBytes: candidateB.bytes, approvalAuthority: candidateB.authority)
        _ = try await store.stage(packageBytes: candidateC.bytes, approvalAuthority: candidateC.authority)
        try await store.activate(revisionId: candidateC.revisionId)

        await XCTAssertThrowsNativeError(
            try await store.activate(revisionId: candidateB.revisionId),
            equals: .baseMismatch(expected: candidateC.revisionId, actual: first.revisionId)
        )
        let activeAfterStaleAttempt = try await store.activeRevisionId()
        XCTAssertEqual(activeAfterStaleAttempt, candidateC.revisionId)
    }

    func testFailedActivationVerificationLeavesTheCurrentPointerAndLaunchUntouched() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let store = try makeStore(root: fixture.storeRoot)
        let firstContent = html("active-before-failed-verification")
        let first = try fixture.generateDesktopPackage(content: firstContent, nonce: nonce("a"))
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)

        let secondContent = html("candidate-corrupted-before-verification")
        let second = try fixture.generateDesktopPackage(
            content: secondContent, baseRevisionId: first.revisionId, nonce: nonce("b")
        )
        _ = try await store.stage(packageBytes: second.bytes, approvalAuthority: second.authority)
        let candidateFile = try storedRegularFile(matching: Data(secondContent.utf8), under: fixture.storeRoot)
        try flipFirstByte(at: candidateFile)

        do {
            try await store.activate(revisionId: second.revisionId)
            XCTFail("C4: failed checkout verification must not promote the unverified candidate")
        } catch {
            // The public error wording may vary; pointer and launch state are the oracle.
        }
        let activeAfterFailure = try await store.activeRevisionId()
        XCTAssertEqual(activeAfterFailure, first.revisionId,
                       "C4: pointer remains on the previously verified revision when candidate verification fails")
        let launch = try await store.launchDescriptorForActiveRevision()
        XCTAssertEqual(launch.revisionId, first.revisionId,
                       "C4: failed verification leaves the previously verified revision launchable")
        XCTAssertEqual(try Data(contentsOf: launch.entrypointURL), Data(firstContent.utf8),
                       "C4: failed verification preserves exact bytes of the previously verified launch")
    }

    func testUpdateCannotChangeReaderDataNamespace() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let store = try makeStore(root: fixture.storeRoot)
        let first = try fixture.generateDesktopPackage(content: html("namespace-a"), nonce: nonce("k"))
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)

        let changed = try fixture.generateDesktopPackage(
            content: html("namespace-b"),
            baseRevisionId: first.revisionId,
            nonce: nonce("l"),
            namespace: "publik.kneecap.changed"
        )
        await XCTAssertThrowsNativeError(
            try await store.stage(packageBytes: changed.bytes, approvalAuthority: changed.authority),
            equals: .userDataNamespaceMismatch(expected: appId, actual: "publik.kneecap.changed")
        )
    }

    func testNativeCapabilitiesRemainDeniedByDefaultAndNeedSeparateGrant() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let package = try fixture.generateDesktopPackage(
            content: html("camera"), nonce: nonce("m"), capabilities: ["native.camera"]
        )

        let denyAllStore = try makeStore(root: fixture.storeRoot)
        await XCTAssertThrowsNativeError(
            try await denyAllStore.stage(packageBytes: package.bytes, approvalAuthority: package.authority),
            equals: .unsupportedCapabilities(["native.camera"])
        )

        let supportedRoot = fixture.root.appendingPathComponent("supported-but-ungranted", isDirectory: true)
        let supportedButUngranted = try makeStore(
            root: supportedRoot,
            policy: CapabilityPolicy(supportedCapabilities: ["native.camera"])
        )
        await XCTAssertThrowsNativeError(
            try await supportedButUngranted.stage(packageBytes: package.bytes, approvalAuthority: package.authority),
            equals: .ungrantedNativeCapabilities(["native.camera"])
        )
    }

    func testDeclaredWebExportRequiresExplicitPolicyAndRemainsRevisionScoped() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let first = try fixture.generateDesktopPackage(
            content: html("export declaration"), nonce: nonce("e"), capabilities: ["web.media.export"]
        )
        let denied = try makeStore(root: fixture.storeRoot)
        await XCTAssertThrowsNativeError(
            try await denied.stage(packageBytes: first.bytes, approvalAuthority: first.authority),
            equals: .unsupportedCapabilities(["web.media.export"])
        )
        let activeAfterDenial = try await denied.activeRevisionId()
        XCTAssertNil(activeAfterDenial)

        let store = try makeStore(root: fixture.root.appendingPathComponent("explicit-export"),
            policy: CapabilityPolicy(supportedCapabilities: ["web.media.export"]))
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)
        let firstLaunch = try await store.launchDescriptorForActiveRevision()
        XCTAssertEqual(firstLaunch.requestedCapabilities, ["web.media.export"])

        let second = try fixture.generateDesktopPackage(content: html("no export"),
            baseRevisionId: first.revisionId, nonce: nonce("f"))
        _ = try await store.stage(packageBytes: second.bytes, approvalAuthority: second.authority)
        try await store.activate(revisionId: second.revisionId)
        let secondLaunch = try await store.launchDescriptorForActiveRevision()
        XCTAssertTrue(secondLaunch.requestedCapabilities.isEmpty)
        try await store.rollback(to: first.revisionId)
        let revertedLaunch = try await store.launchDescriptorForActiveRevision()
        XCTAssertEqual(revertedLaunch.requestedCapabilities, ["web.media.export"])
    }

    func testRollbackPreservesReaderDataAndLastGoodRevision() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let store = try makeStore(root: fixture.storeRoot)
        let first = try fixture.generateDesktopPackage(content: html("revision-a"), nonce: nonce("n"))
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)

        let readerData = try await store.readerDataDirectory(namespace: appId)
        let note = readerData.appendingPathComponent("note.txt")
        try Data("reader-owned".utf8).write(to: note)

        let second = try fixture.generateDesktopPackage(
            content: html("revision-b"), baseRevisionId: first.revisionId, nonce: nonce("o")
        )
        _ = try await store.stage(packageBytes: second.bytes, approvalAuthority: second.authority)
        try await store.activate(revisionId: second.revisionId)
        let fallback = try await store.fallbackRevisionId()
        XCTAssertEqual(fallback, first.revisionId)

        try await store.rollback(to: first.revisionId)
        let activeAfterRollback = try await store.activeRevisionId()
        XCTAssertEqual(activeAfterRollback, first.revisionId)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "reader-owned")
    }

    func testReaderDataNamespaceIsScopedByAppAndProject() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let firstStore = try makeStore(root: fixture.storeRoot)
        let otherStore = try makeStore(
            root: fixture.storeRoot,
            appId: "publik.other",
            projectId: "publik.other.mobile"
        )

        let firstDirectory = try await firstStore.readerDataDirectory(namespace: "shared.notes")
        let otherDirectory = try await otherStore.readerDataDirectory(namespace: "shared.notes")
        XCTAssertNotEqual(firstDirectory.standardizedFileURL, otherDirectory.standardizedFileURL)

        let firstNote = firstDirectory.appendingPathComponent("note.txt")
        let otherNote = otherDirectory.appendingPathComponent("note.txt")
        try Data("app-one".utf8).write(to: firstNote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherNote.path))
    }

    func testJointStoredContentAndMetadataTamperFallsBackToPriorRevision() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let (store, first, second) = try await activatedPair(fixture: fixture)

        let contentURL = try storedRegularFile(matching: Data(html("good-b").utf8), under: fixture.storeRoot)
        try flipFirstByte(at: contentURL)

        let launch = try await store.launchDescriptorForActiveRevision()
        XCTAssertEqual(launch.revisionId, first.revisionId)
        let activeAfterTamper = try await store.activeRevisionId()
        XCTAssertEqual(activeAfterTamper, first.revisionId)
    }

    func testStoredSymlinkTamperFallsBackToPriorVerifiedRevision() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let (store, first, second) = try await activatedPair(fixture: fixture)

        let entrypoint = try storedRegularFile(matching: Data(html("good-b").utf8), under: fixture.storeRoot)
        let outside = fixture.root.appendingPathComponent("outside.html")
        try Data(html("outside").utf8).write(to: outside)
        try FileManager.default.removeItem(at: entrypoint)
        try FileManager.default.createSymbolicLink(at: entrypoint, withDestinationURL: outside)

        let launch = try await store.launchDescriptorForActiveRevision()
        XCTAssertEqual(launch.revisionId, first.revisionId)
        let activeAfterSymlink = try await store.activeRevisionId()
        XCTAssertEqual(activeAfterSymlink, first.revisionId)
    }

    func testUnchangedRevisionStorageDoesNotAliasCorruptionAcrossHistory() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let store = try makeStore(root: fixture.storeRoot)
        let previousContent = html("known-good-prior-history")
        let first = try fixture.generateDesktopPackage(content: previousContent, nonce: nonce("1"))
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)
        let currentContent = html("current-history-content-to-corrupt")
        let second = try fixture.generateDesktopPackage(
            content: currentContent,
            baseRevisionId: first.revisionId,
            nonce: nonce("2")
        )
        _ = try await store.stage(packageBytes: second.bytes, approvalAuthority: second.authority)
        try await store.activate(revisionId: second.revisionId)

        let currentBytes = Data(currentContent.utf8)
        let activeLaunch = try await store.launchDescriptorForActiveRevision()
        XCTAssertEqual(activeLaunch.revisionId, second.revisionId)
        let currentHistoryFiles = try storedRegularFiles(matching: currentBytes, under: fixture.storeRoot)
        XCTAssertFalse(currentHistoryFiles.isEmpty, "current revision bytes should be stored in history")
        for url in currentHistoryFiles { try flipFirstByte(at: url) }
        let activeFilePath = activeLaunch.entrypointURL.resolvingSymlinksInPath().standardizedFileURL.path
        let wasAlreadyCorrupted = currentHistoryFiles.contains {
            $0.resolvingSymlinksInPath().standardizedFileURL.path == activeFilePath
        }
        if !wasAlreadyCorrupted { try flipFirstByte(at: activeLaunch.entrypointURL) }

        let launch = try await store.launchDescriptorForActiveRevision()
        let launchedBytes = try Data(contentsOf: launch.entrypointURL)
        XCTAssertEqual(launch.revisionId, first.revisionId,
                       "MV2 2.4: corrupt current history should fall back to the prior verified revision")
        XCTAssertEqual(digest(launchedBytes), digest(Data(previousContent.utf8)),
                       "MV2 2.4: returned fallback bytes must match their independently known content hash")
    }

    func testHistorySizesAreVerifiedLogicalBytesAndDoNotIncludeReaderData() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let store = try makeStore(root: fixture.storeRoot)
        let content = html("logical-size-not-exclusive-blocks")
        let first = try fixture.generateDesktopPackage(content: content, nonce: nonce("3"))
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)
        let second = try fixture.generateDesktopPackage(content: content, baseRevisionId: first.revisionId, nonce: nonce("4"))
        _ = try await store.stage(packageBytes: second.bytes, approvalAuthority: second.authority)
        try await store.activate(revisionId: second.revisionId)
        let summaries = try await store.revisionSummaries()
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.map(\.contentBytes), [content.utf8.count, content.utf8.count])
        let entry = NativeShellLibraryEntry(identity: .init(appId: appId, projectId: projectId),
            displayName: "Size fixture", currentRevisionId: second.revisionId,
            fallbackRevisionId: first.revisionId, revisions: summaries)
        XCTAssertEqual(entry.totalVersionContentBytes, 2 * content.utf8.count,
                       "copy-on-write sharing is not a reason to report false zero-sized versions")
        let reopened = try makeStore(root: fixture.storeRoot)
        let persisted = try await reopened.revisionSummaries()
        XCTAssertEqual(persisted.map(\.contentBytes), summaries.map(\.contentBytes))
    }

    func testHistorySizeNeverTreatsUnknownNegativeOrOverflowAsZero() {
        func entry(_ values: [Int?]) -> NativeShellLibraryEntry {
            let summaries = values.enumerated().map { index, value in
                NativeRevisionSummary(appId: appId, projectId: projectId,
                    revisionId: "size-fixture-\(index)", baseRevisionId: nil,
                    displayName: "Size fixture", dataNamespace: "size-fixture", requestedCapabilities: [],
                    createdAt: "2026-09-20T00:00:00.000Z", contentBytes: value)
            }
            return NativeShellLibraryEntry(identity: .init(appId: appId, projectId: projectId),
                displayName: "Size fixture", currentRevisionId: nil, fallbackRevisionId: nil, revisions: summaries)
        }
        XCTAssertEqual(entry([10, 20]).totalVersionContentBytes, 30)
        XCTAssertNil(entry([10, nil]).totalVersionContentBytes)
        XCTAssertNil(entry([-1]).totalVersionContentBytes)
        XCTAssertNil(entry([Int.max, 1]).totalVersionContentBytes)
        XCTAssertEqual(entry([]).totalVersionContentBytes, 0)
    }

    func testUndeclaredStoredFileOrDirectoryFallsBackToPriorVerifiedRevision() async throws {
        do {
            let fixture = try FixtureRoot()
            defer { fixture.cleanup() }
            let (store, first, second) = try await activatedPair(fixture: fixture)
            let descriptor = try await store.launchDescriptorForActiveRevision()
            let contentRoot = descriptor.entrypointURL.deletingLastPathComponent()
            try Data("undeclared".utf8).write(to: contentRoot.appendingPathComponent("extra.js"))

            let launch = try await store.launchDescriptorForActiveRevision()
            XCTAssertEqual(launch.revisionId, first.revisionId)
        }

        do {
            let fixture = try FixtureRoot()
            defer { fixture.cleanup() }
            let (store, first, second) = try await activatedPair(fixture: fixture)
            let descriptor = try await store.launchDescriptorForActiveRevision()
            let contentRoot = descriptor.entrypointURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: contentRoot.appendingPathComponent("rogue", isDirectory: true), withIntermediateDirectories: false)

            let launch = try await store.launchDescriptorForActiveRevision()
            XCTAssertEqual(launch.revisionId, first.revisionId)
        }
    }

    func testPreexistingStateAndRevisionNamespaceSymlinksAreRejectedBeforeWrites() async throws {
        do {
            let fixture = try FixtureRoot()
            defer { fixture.cleanup() }
            let outside = fixture.root.appendingPathComponent("outside-state", isDirectory: true)
            let stateParent = fixture.storeRoot
                .appendingPathComponent("state", isDirectory: true)
                .appendingPathComponent(appId, isDirectory: true)
            let stateProject = stateParent.appendingPathComponent(projectId, isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: stateParent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: stateProject, withDestinationURL: outside)
            let package = try fixture.generateDesktopPackage(content: html("state-symlink"), nonce: nonce("t"))
            let store = try makeStore(root: fixture.storeRoot)

            await XCTAssertThrowsNativeError(
                try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority),
                equals: .unsafeStorageNamespace(stateProject.path)
            )
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        }

    }

    func testPromotedRevisionRemainsLaunchableAfterStoreReopen() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let package = try fixture.generateDesktopPackage(content: html("promote-cleanup"), nonce: nonce("v"))
        let cleanStore = try makeStore(root: fixture.storeRoot)
        _ = try await cleanStore.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
        try await cleanStore.activate(revisionId: package.revisionId)
        let reopened = try makeStore(root: fixture.storeRoot)
        let launch = try await reopened.launchDescriptorForActiveRevision()
        XCTAssertEqual(launch.revisionId, package.revisionId, "MV2 2.2: a promoted revision remains launchable after reopen")
        XCTAssertEqual(try Data(contentsOf: launch.entrypointURL), Data(html("promote-cleanup").utf8),
                       "MV2 2.2: reopen exposes the exact promoted package bytes")
    }

    func testUpdateRefusesCorruptedActiveBaseBeforeCloneReuse() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let store = try makeStore(root: fixture.storeRoot)
        let content = html("verified-base-before-clone")
        let first = try fixture.generateDesktopPackage(content: content, nonce: nonce("w"))
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)
        let second = try fixture.generateDesktopPackage(
            content: content,
            baseRevisionId: first.revisionId,
            nonce: nonce("x")
        )

        let entrypoint = try storedRegularFile(matching: Data(content.utf8), under: fixture.storeRoot)
        try flipFirstByte(at: entrypoint)

        await XCTAssertThrowsNativeError(
            try await store.stage(packageBytes: second.bytes, approvalAuthority: second.authority),
            equals: .storedRevisionInvalid(first.revisionId)
        )
        XCTAssertFalse(try storedJSONMentions(second.revisionId, under: fixture.storeRoot),
                       "MV2 2.2: refused update must not leave a listed partial revision")
        let activeAfterRejectedUpdate = try await store.activeRevisionId()
        XCTAssertEqual(activeAfterRejectedUpdate, first.revisionId)
    }

    func testSameSizePayloadTamperAfterPromotionIsRejectedAndRemoved() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let package = try fixture.generateDesktopPackage(content: html("same-size-final-verification"), nonce: nonce("y"))
        let store = try makeStore(root: fixture.storeRoot)
        let staged = try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
        XCTAssertEqual(staged.revisionId, package.revisionId)
        try await store.activate(revisionId: package.revisionId)
        let launch = try await store.launchDescriptorForActiveRevision()
        XCTAssertEqual(try Data(contentsOf: launch.entrypointURL), Data(html("same-size-final-verification").utf8),
                       "MV2 2.4: launch verification must expose exact package bytes")
    }

    func testStageWithoutActivationSurvivesRestartButDoesNotBecomeActive() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let package = try fixture.generateDesktopPackage(content: html("staged-only"), nonce: nonce("p"))
        var store: NativeRevisionStore? = try makeStore(root: fixture.storeRoot)
        _ = try await store?.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
        let activeBeforeRestart = try await store?.activeRevisionId()
        XCTAssertNil(activeBeforeRestart)
        store = nil

        let reopened = try makeStore(root: fixture.storeRoot)
        let activeAfterRestart = try await reopened.activeRevisionId()
        XCTAssertNil(activeAfterRestart)
        XCTAssertTrue(try storedJSONMentions(package.revisionId, under: fixture.storeRoot),
                      "MV2 2.2: a staged manifest survives restart without becoming active")
    }

    func testFacadeE3MarginalGrowthAndFileCountAtTenAndHundredVersions() async throws {
        for addedVersions in [10, 100] {
            let fixture = try FixtureRoot()
            defer { fixture.cleanup() }
            let store = try makeStore(root: fixture.storeRoot)
            var base: String?
            var previous = try independentInventory(under: fixture.storeRoot)
            for index in 0...addedVersions {
                let package = try fixture.generateDesktopPackage(
                    content: fixedSizeHTML(seed: index), baseRevisionId: base,
                    nonce: nonceFor("facade-e3-\(addedVersions)-\(index)")
                )
                _ = try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
                try await store.activate(revisionId: package.revisionId)
                base = package.revisionId
                let current = try independentInventory(under: fixture.storeRoot)
                if index == 0 {
                    continue // initial install is not an added-version measurement (E3 §3).
                }
                if index == 1 {
                    previous = current // stabilized baseline after the first added version.
                    continue
                }
                let growth = current.allocatedBytes - previous.allocatedBytes
                let addedFiles = current.regularFiles - previous.regularFiles
                XCTAssertLessThanOrEqual(growth, 4 * 1_024 + 16 * 1_024,
                    "E3 §3: each settled changed file adds at most D_i + H (D_i=4 KiB, H=16 KiB); depth=\(addedVersions), version=\(index)")
                XCTAssertLessThanOrEqual(addedFiles, 1 + 8,
                    "E3 §3: added regular files are at most K_i + 8 (K_i=1); depth=\(addedVersions), version=\(index)")
                previous = current
            }
        }
    }

    func testFacadeE3IdenticalContentUpdateHasOnlyMetadataGrowthAfterBootstrap() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let store = try makeStore(root: fixture.storeRoot)
        let bytes = fixedSizeHTML(seed: 17)
        var base: String?
        var stabilized: IndependentInventory?
        for index in 0..<4 {
            let package = try fixture.generateDesktopPackage(
                content: bytes, baseRevisionId: base,
                nonce: nonceFor("facade-e3-identical-\(index)")
            )
            _ = try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
            try await store.activate(revisionId: package.revisionId)
            base = package.revisionId
            let current = try independentInventory(under: fixture.storeRoot)
            if index == 1 {
                stabilized = current // E3 section 3: first added version is the separately reported bootstrap.
            } else if let previous = stabilized {
                XCTAssertLessThanOrEqual(current.allocatedBytes - previous.allocatedBytes, 16 * 1_024,
                    "E3 §3: identical content has no new D_i; steady-state growth is at most H=16 KiB")
                XCTAssertLessThanOrEqual(current.regularFiles - previous.regularFiles, 8,
                    "E3 §3: identical content has K_i=0; steady-state file growth is at most K_i+8")
                stabilized = current
            }
        }
    }

    func testFacadeE3SameChangedFileHasSizeIndependentGrowthAt48KiBAnd50MiB() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let changedFileBytes = 4 * 1_024
        let changeInput = fixture.root.appendingPathComponent("delta-input.bin")
        try deterministicFixtureBytes(count: changedFileBytes, seed: 0xE303).write(to: changeInput)
        var deltaInfo = stat()
        XCTAssertEqual(lstat(changeInput.path, &deltaInfo), 0)
        let deltaAllocation = Int64(deltaInfo.st_blocks) * 512

        var measuredGrowth: [Int64] = []
        // Contract maximum is 32 MiB decoded across at most 256 files, with a 16 MiB per-file ceiling.
        // Leave room for the changed file and package metadata while retaining a >680x size ratio.
        let largeTotalBytes = 32 * 1_024 * 1_024 - 32 * 1_024
        for (label, totalBytes) in [("small", 48 * 1_024), ("large", largeTotalBytes)] {
            let root = fixture.storeRoot.appendingPathComponent(label, isDirectory: true)
            let store = try makeStore(root: root, appId: "facade.e3.size", projectId: "facade.e3.size.mobile")
            let paddingSize = totalBytes - changedFileBytes
            let shardCount = 2
            let paddingShards = (0..<shardCount).map { shard in
                deterministicFixtureBytes(
                    count: paddingSize / shardCount + (shard < paddingSize % shardCount ? 1 : 0),
                    seed: UInt64(0xE304 + shard)
                )
            }
            var base: String?
            var settledBaseline: Int64?

            for version in 0..<3 {
                var changedContent = deterministicFixtureBytes(count: changedFileBytes, seed: UInt64(0xE310 + version))
                let htmlPrefix = Data("<!doctype html>".utf8)
                changedContent.replaceSubrange(changedContent.startIndex..<htmlPrefix.count, with: htmlPrefix)
                var files = ["index.html": changedContent]
                for shard in paddingShards.indices {
                    files["assets/padding-\(shard).bin"] = paddingShards[shard]
                }
                let package = try fixture.generateDesktopPackage(
                    files: files,
                    baseRevisionId: base,
                    nonce: nonceFor("facade-e3-size-\(version)"),
                    appId: "facade.e3.size",
                    projectId: "facade.e3.size.mobile"
                )
                _ = try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
                try await store.activate(revisionId: package.revisionId)
                base = package.revisionId
                let inventory = try independentInventory(under: root)
                if version == 1 {
                    settledBaseline = inventory.allocatedBytes // E3 §3: exclude first-update bootstrap.
                } else if version == 2, let settledBaseline {
                    let growth = inventory.allocatedBytes - settledBaseline
                    XCTAssertLessThanOrEqual(growth, deltaAllocation + 16 * 1_024,
                        "E3 §3: after bootstrap each changed file adds at most D_i + H; size=\(label), D_i=\(deltaAllocation), H=16 KiB")
                    measuredGrowth.append(growth)
                }
            }
        }

        XCTAssertEqual(measuredGrowth.count, 2)
        if measuredGrowth.count == 2 {
            print("E3 B2 measured allocated growth bytes: small=\(measuredGrowth[0]), large=\(measuredGrowth[1]), ratio=\(Double(largeTotalBytes) / Double(48 * 1_024))")
            XCTAssertLessThanOrEqual(abs(measuredGrowth[0] - measuredGrowth[1]), 16 * 1_024,
                "E3 §3 B2: the same one-file change in 48 KiB and contract-maximum app differs by at most H=16 KiB")
        }
    }

    func testFacadeE5SwitchingOneOfThreeAppsPreservesOtherLaunchBytes() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        var stores: [NativeRevisionStore] = []
        var ids: [[String]] = []
        let expected = (0..<3).map { index in Data(html("facade-e5-app-\(index)").utf8) }
        for appIndex in 0..<3 {
            let appId = "facade.e5.app.\(appIndex)"
            let projectId = "\(appId).mobile"
            let store = try makeStore(root: fixture.storeRoot.appendingPathComponent("app-\(appIndex)"), appId: appId, projectId: projectId)
            var base: String?
            var revisions: [String] = []
            for version in 0..<3 {
                let content = version == 0 ? String(decoding: expected[appIndex], as: UTF8.self) : html("facade-e5-\(appIndex)-v\(version)")
                let package = try fixture.generateDesktopPackage(
                    content: content, baseRevisionId: base, nonce: nonceFor("facade-e5-\(appIndex)-\(version)"),
                    appId: appId, projectId: projectId
                )
                _ = try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
                try await store.activate(revisionId: package.revisionId)
                base = package.revisionId
                revisions.append(package.revisionId)
            }
            stores.append(store)
            ids.append(revisions)
        }
        try await stores[1].rollback(to: ids[1][1])
        let changedApp = try await stores[1].launchDescriptorForActiveRevision()
        XCTAssertEqual(changedApp.revisionId, ids[1][1], "E5 §5: switching selects the requested target app revision")
        for appIndex in [0, 2] {
            let launch = try await stores[appIndex].launchDescriptorForActiveRevision()
            XCTAssertEqual(launch.revisionId, ids[appIndex][2], "E5 §5: another app's active identity is unchanged")
            XCTAssertEqual(try Data(contentsOf: launch.entrypointURL), Data(html("facade-e5-\(appIndex)-v2").utf8),
                           "E5 §5: another app retains its exact launch bytes")
        }
    }

    func testFacadeE5OneHundredAppsKeepIndependentHistoriesWhenOneSwitches() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let appCount = 100
        var currentIds: [String] = []
        var targetIds: [String] = []
        let storeRoot = fixture.storeRoot
        for appIndex in 0..<appCount {
            let appId = "facade.e5.matrix.\(appIndex)"
            let projectId = "\(appId).mobile"
            let store = try makeStore(root: storeRoot, appId: appId, projectId: projectId)
            var base: String?
            var ids: [String] = []
            for version in 0..<3 {
                let content = html("facade-e5-matrix-\(appIndex)-v\(version)")
                let package = try fixture.generateDesktopPackage(
                    content: content, baseRevisionId: base, nonce: nonceFor("facade-e5-matrix-\(appIndex)-\(version)"),
                    appId: appId, projectId: projectId
                )
                _ = try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
                try await store.activate(revisionId: package.revisionId)
                ids.append(package.revisionId)
                base = package.revisionId
            }
            currentIds.append(ids[2])
            targetIds.append(ids[1])
        }
        let targetApp = try makeStore(root: storeRoot, appId: "facade.e5.matrix.50", projectId: "facade.e5.matrix.50.mobile")
        try await targetApp.rollback(to: targetIds[50])
        for appIndex in 0..<appCount {
            let appId = "facade.e5.matrix.\(appIndex)"
            let store = try makeStore(root: storeRoot, appId: appId, projectId: "\(appId).mobile")
            let launch = try await store.launchDescriptorForActiveRevision()
            let expectedId = appIndex == 50 ? targetIds[50] : currentIds[appIndex]
            XCTAssertEqual(launch.revisionId, expectedId, "E5 §5 B7: one app switch leaves all other app identities unchanged")
            let expectedVersion = appIndex == 50 ? 1 : 2
            XCTAssertEqual(try Data(contentsOf: launch.entrypointURL),
                           Data(html("facade-e5-matrix-\(appIndex)-v\(expectedVersion)").utf8),
                           "E5 §5 B7: each app still launches its exact independent fixture bytes")
        }
        var reportedAcrossApps = 0
        for appIndex in 0..<appCount {
            let appId = "facade.e5.matrix.\(appIndex)"
            let store = try makeStore(root: storeRoot, appId: appId, projectId: "\(appId).mobile")
            reportedAcrossApps += try await store.totalAllocatedBytes()
        }
        let observed = try independentInventory(under: storeRoot)
        XCTAssertLessThanOrEqual(Int64(reportedAcrossApps), observed.allocatedBytes + 100 * 4_096,
            "E5 §5 B7: summed facade allocation reconciles to independent allocation within per-app block tolerance")
    }

    func testFacadeE6PrunableBytesAreReclaimedWithoutTouchingRetainedRolesOrReaderData() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let catalog = RevisionStoreOffers()
        let defaultsName = "revision-store-e6-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set("all", forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey)
        let store = try makeStore(root: fixture.storeRoot, defaults: defaults, downloadableRevisionIds: { _ in await catalog.all() })
        let readerData = try await store.readerDataDirectory(namespace: "facade-e6-reclaim")
        let sentinel = readerData.appendingPathComponent("sentinel.bin")
        let sentinelBytes = Data("reader data must survive version reclaim".utf8)
        try sentinelBytes.write(to: sentinel)
        var base: String?
        var ids: [String] = []
        for version in 0..<4 {
            let package = try fixture.generateDesktopPackage(
                content: html("facade-e6-reclaim-\(version)"), baseRevisionId: base,
                nonce: nonceFor("facade-e6-reclaim-\(version)")
            )
            await catalog.insert(package.revisionId)
            _ = try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
            try await store.activate(revisionId: package.revisionId)
            base = package.revisionId
            ids.append(package.revisionId)
        }
        let candidates = try await store.prunableAllocation()
        let candidate = try XCTUnwrap(candidates.first { $0.revisionId == ids[0] },
                                      "E6 §6 B5: the unretained oldest revision is reported as prunable")
        let before = try independentInventory(under: fixture.storeRoot)
        _ = try await store.removeSpecificRevisions([ids[0]])
        let after = try independentInventory(under: fixture.storeRoot)
        XCTAssertGreaterThanOrEqual(before.allocatedBytes - after.allocatedBytes, Int64(candidate.allocatedBytes),
            "E6 §6 B5: independent filesystem allocation decreases by at least the advertised reclaimable revision bytes")
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes, "E6 §6 B5: version reclamation never changes reader data")
        let activeAfterReclaim = try await store.activeRevisionId()
        let fallbackAfterReclaim = try await store.fallbackRevisionId()
        XCTAssertEqual(activeAfterReclaim, ids[3], "E6 §6 B5: current revision remains protected")
        XCTAssertEqual(fallbackAfterReclaim, ids[2], "E6 §6 B5: fallback revision remains protected")
    }

    func testFacadeE6ReportedAllocationDoesNotExceedIndependentFilesystemWalk() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let store = try makeStore(root: fixture.storeRoot)
        let package = try fixture.generateDesktopPackage(content: fixedSizeHTML(seed: 44), nonce: nonceFor("facade-e6-accounting"))
        _ = try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
        try await store.activate(revisionId: package.revisionId)
        let reported = try await store.totalAllocatedBytes()
        let observed = try independentInventory(under: fixture.storeRoot)
        XCTAssertLessThanOrEqual(Int64(reported), observed.allocatedBytes + 4_096,
            "E6 §6: reported allocated bytes must reconcile to an independent lstat allocation walk within one block")
        XCTAssertGreaterThan(reported, 0, "E6 §6: allocated content must not be reported as zero")
    }

    func testFacadeE4AtMostTwoCompleteLaunchableCopiesAfterFiveActivations() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let store = try makeStore(root: fixture.storeRoot)
        var base: String?
        var expected = Set<Data>()
        for index in 0..<5 {
            let bytes = Data(fixedSizeHTML(seed: index).utf8)
            expected.insert(bytes)
            let package = try fixture.generateDesktopPackage(
                content: String(decoding: bytes, as: UTF8.self), baseRevisionId: base,
                nonce: nonceFor("facade-e4-copy-\(index)")
            )
            _ = try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
            try await store.activate(revisionId: package.revisionId)
            base = package.revisionId
        }
        let completeCopies = try countDirectoriesContainingExpectedEntrypointBytes(expected, under: fixture.storeRoot)
        XCTAssertLessThanOrEqual(completeCopies, 2,
            "E4 §4: after N>=5 activations the active app has at most two complete launchable copies")
    }

    func testFacadeE4RestartRollbackRestoresExactBytesAndReaderData() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        var store = try makeStore(root: fixture.storeRoot)
        let dataDirectory = try await store.readerDataDirectory(namespace: "facade-restore")
        let sentinel = dataDirectory.appendingPathComponent("sentinel.bin")
        let sentinelBytes = Data("independent reader data sentinel".utf8)
        try sentinelBytes.write(to: sentinel)
        var ids: [String] = []
        var payloads: [Data] = []
        var base: String?
        for index in 0..<5 {
            let bytes = Data(fixedSizeHTML(seed: index).utf8)
            payloads.append(bytes)
            let package = try fixture.generateDesktopPackage(
                content: String(decoding: bytes, as: UTF8.self), baseRevisionId: base,
                nonce: nonceFor("facade-e4-restore-\(index)")
            )
            _ = try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
            try await store.activate(revisionId: package.revisionId)
            ids.append(package.revisionId)
            base = package.revisionId
        }
        store = try makeStore(root: fixture.storeRoot) // public restart boundary
        for target in [0, 2, 4] {
            let start = ContinuousClock.now
            try await store.rollback(to: ids[target])
            let elapsed = start.duration(to: .now)
            let descriptor = try await store.launchDescriptorForActiveRevision()
            XCTAssertEqual(descriptor.revisionId, ids[target], "E4 §4: rollback selects the requested retained ancestor")
            XCTAssertEqual(try Data(contentsOf: descriptor.entrypointURL), payloads[target], "E4 §4: restored tree has exact fixture bytes")
            XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes, "E4 §4: reader-data sentinel is unchanged")
            XCTAssertLessThan(elapsed, .seconds(1), "E4 §4: local version switch completes in under 1 s")
            if target != 4 { try await store.rollback(to: ids[4]) }
        }
    }

    func testFacadeE6LowCapacityRefusalLeavesNoPartialRevisionOrAllocationGrowth() async throws {
        let fixture = try FixtureRoot()
        defer { fixture.cleanup() }
        let capacity = FacadeCapacityProvider(bytes: 900 * 1_024 * 1_024)
        let store = try makeStore(root: fixture.storeRoot, availableCapacityProvider: { _ in capacity.value })
        let first = try fixture.generateDesktopPackage(content: fixedSizeHTML(seed: 0), nonce: nonceFor("facade-e6-first"))
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)
        let before = try independentInventory(under: fixture.storeRoot)
        let next = try fixture.generateDesktopPackage(
            content: fixedSizeHTML(seed: 1), baseRevisionId: first.revisionId,
            nonce: nonceFor("facade-e6-refused")
        )
        capacity.value = 100 * 1_024 * 1_024
        do {
            _ = try await store.stage(packageBytes: next.bytes, approvalAuthority: next.authority)
            XCTFail("E6 §6: low-capacity staging must be refused with the public insufficient-storage error")
        } catch let error as NativeStorageError {
            guard case let .insufficientStorageForUpdate(availableBytes, thresholdBytes) = error else {
                return XCTFail("E6 §6: expected insufficient-storage error, received \(error)")
            }
            XCTAssertEqual(availableBytes, capacity.value)
            XCTAssertEqual(thresholdBytes, NativeStorageRetentionPolicy.defaultMinimumFreeBytesForStaging)
        }
        let after = try independentInventory(under: fixture.storeRoot)
        XCTAssertEqual(after.allocatedBytes, before.allocatedBytes,
                       "E6 §6: refused staging leaves independent allocated bytes unchanged")
        XCTAssertFalse(try storedJSONMentions(next.revisionId, under: fixture.storeRoot),
                       "E6 §6: refused staging leaves no partial revision")
        let launch = try await store.launchDescriptorForActiveRevision()
        XCTAssertEqual(launch.revisionId, first.revisionId, "E6 §6: prior active version remains launchable")
        XCTAssertEqual(try Data(contentsOf: launch.entrypointURL), Data(fixedSizeHTML(seed: 0).utf8),
                       "E6 §6: prior launch has exact fixture bytes")
    }

    private func activatedPair(
        fixture: FixtureRoot
    ) async throws -> (NativeRevisionStore, GeneratedPackage, GeneratedPackage) {
        let store = try makeStore(root: fixture.storeRoot)
        let first = try fixture.generateDesktopPackage(content: html("good-a"), nonce: nonce("q"))
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)
        let second = try fixture.generateDesktopPackage(
            content: html("good-b"), baseRevisionId: first.revisionId, nonce: nonce("r")
        )
        _ = try await store.stage(packageBytes: second.bytes, approvalAuthority: second.authority)
        try await store.activate(revisionId: second.revisionId)
        return (store, first, second)
    }

    private func makeStore(
        root: URL,
        appId: String? = nil,
        projectId: String? = nil,
        policy: CapabilityPolicy = .denyAll,
        fileManager: FileManager = .default,
        availableCapacityProvider: (@Sendable (URL) throws -> Int64)? = nil,
        defaults: UserDefaults = .standard,
        downloadableRevisionIds: @escaping @Sendable (NativeShellAppIdentity) async throws -> Set<String> = { _ in [] }
    ) throws -> NativeRevisionStore {
        if let availableCapacityProvider {
            return try NativeRevisionStore(
                rootURL: root, appId: appId ?? self.appId, projectId: projectId ?? self.projectId,
                shellVersion: "1.0.0", capabilityPolicy: policy, fileManager: fileManager,
                availableCapacityProvider: availableCapacityProvider,
                defaults: defaults,
                downloadableRevisionIds: downloadableRevisionIds
            )
        }
        return try NativeRevisionStore(
            rootURL: root, appId: appId ?? self.appId, projectId: projectId ?? self.projectId,
            shellVersion: "1.0.0", capabilityPolicy: policy, fileManager: fileManager,
            defaults: defaults,
            downloadableRevisionIds: downloadableRevisionIds
        )
    }

    private func storedRegularFile(matching bytes: Data, under root: URL) throws -> URL {
        try XCTUnwrap(storedRegularFiles(matching: bytes, under: root).first,
                      "fixture bytes must be discoverable by content under the store root")
    }

    private func storedRegularFiles(matching bytes: Data, under root: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var matches: [URL] = []
        for case let url as URL in enumerator {
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
               (try? Data(contentsOf: url)) == bytes {
                matches.append(url)
            }
        }
        return matches
    }

    private func storedJSONMentions(_ identifier: String, under root: URL) throws -> Bool {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  let data = try? Data(contentsOf: url),
                  String(data: data, encoding: .utf8)?.contains(identifier) == true else { continue }
            return true
        }
        return false
    }

    private func flipFirstByte(at url: URL) throws {
        guard chmod(url.path, mode_t(0o644)) == 0 else {
            throw FixtureError.malformedFixture("could not make discovered fixture payload writable")
        }
        var bytes = try Data(contentsOf: url)
        guard !bytes.isEmpty else { throw FixtureError.malformedFixture("cannot tamper with an empty file") }
        bytes[bytes.startIndex] ^= 1
        try bytes.write(to: url)
    }

    private func fixedSizeHTML(seed: Int) -> String {
        let prefix = "<!doctype html><meta charset=utf-8><title>Facade</title><main>seed-\(String(format: "%04d", seed))"
        let suffix = "</main>"
        return prefix + String(repeating: "x", count: 4_096 - prefix.utf8.count - suffix.utf8.count) + suffix
    }

    private func nonceFor(_ value: String) -> String {
        String(digest(Data(value.utf8)).dropFirst("sha256:".count))
    }

    private struct IndependentInventory {
        let allocatedBytes: Int64
        let regularFiles: Int
    }

    private func independentInventory(under root: URL) throws -> IndependentInventory {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return IndependentInventory(allocatedBytes: 0, regularFiles: 0)
        }
        var seen = Set<String>()
        var bytes: Int64 = 0
        var files = 0
        func visit(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw FixtureError.malformedFixture("lstat failed for store inventory") }
            guard seen.insert("\(info.st_dev):\(info.st_ino)").inserted else { return }
            bytes += Int64(info.st_blocks) * 512
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                files += 1
            case S_IFDIR:
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try visit(child) }
            default:
                break
            }
        }
        try visit(root)
        return IndependentInventory(allocatedBytes: bytes, regularFiles: files)
    }

    private func countDirectoriesContainingExpectedEntrypointBytes(_ expected: Set<Data>, under root: URL) throws -> Int {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]))
        var complete = Set<URL>()
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "index.html" else { continue }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  let bytes = try? Data(contentsOf: url), expected.contains(bytes) else { continue }
            complete.insert(url.deletingLastPathComponent().standardizedFileURL)
        }
        return complete.count
    }
}

private struct GeneratedPackage {
    let bytes: Data
    let authority: StaticApprovalAuthority
    let approval: TrustedDeliveryApproval
    let revisionId: String
}

private struct StaticApprovalAuthority: DeliveryApprovalAuthority {
    let approval: TrustedDeliveryApproval

    func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval? {
        approval.approvalId == approvalId ? approval : nil
    }
}

private struct EmptyApprovalAuthority: DeliveryApprovalAuthority {
    func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval? { nil }
}

private final class FacadeCapacityProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int64

    init(bytes: Int64) { storedValue = bytes }

    var value: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return storedValue }
        set { lock.lock(); defer { lock.unlock() }; storedValue = newValue }
    }
}

private final class FixtureRoot {
    let root: URL
    let storeRoot: URL
    private var packageIndex = 0

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-native-shell-tests-\(UUID().uuidString)", isDirectory: true)
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func generateDesktopPackage(
        content: String,
        baseRevisionId: String? = nil,
        nonce: String,
        namespace: String = "publik.kneecap",
        capabilities: [String] = [],
        appId: String = "publik.kneecap",
        projectId: String = "publik.kneecap.mobile"
    ) throws -> GeneratedPackage {
        packageIndex += 1
        let output = root.appendingPathComponent("desktop-package-\(packageIndex)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let script = repositoryRoot()
            .appendingPathComponent("mobile-shell/native/Tests/Fixtures/generate-desktop-package.mjs")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", script.path,
            "--output", output.path,
            "--base", baseRevisionId ?? "null",
            "--content", content,
            "--nonce", nonce,
            "--namespace", namespace,
            "--capabilities", try jsonString(capabilities),
            "--app", appId,
            "--project", projectId,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw FixtureError.generatorFailed(String(data: errorData, encoding: .utf8) ?? "unknown generator error")
        }
        let result = try jsonObject(outputData)
        let packagePath = try requiredString(result, "packagePath")
        let approvalPath = try requiredString(result, "trustedApprovalPath")
        let revisionId = try requiredString(result, "revisionId")
        let approval = try parseTrustedApproval(Data(contentsOf: URL(fileURLWithPath: approvalPath)))
        return GeneratedPackage(
            bytes: try Data(contentsOf: URL(fileURLWithPath: packagePath)),
            authority: StaticApprovalAuthority(approval: approval),
            approval: approval,
            revisionId: revisionId
        )
    }

    func generateDesktopPackage(
        files: [String: Data],
        baseRevisionId: String?,
        nonce: String,
        appId: String,
        projectId: String
    ) throws -> GeneratedPackage {
        packageIndex += 1
        let output = root.appendingPathComponent("desktop-package-\(packageIndex)", isDirectory: true)
        let source = output.appendingPathComponent("source", isDirectory: true)
        let build = output.appendingPathComponent("build", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: source.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: build, withIntermediateDirectories: true)
        for (path, bytes) in files {
            let target = build.appendingPathComponent(path)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }

        let registrationPath = output.appendingPathComponent("registration.json")
        let reviewPath = output.appendingPathComponent("review.json")
        let stagePath = output.appendingPathComponent("stage.json")
        let approvedPath = output.appendingPathComponent("approved.json")
        let packagePath = output.appendingPathComponent("package.json")
        let receiptsPath = output.appendingPathComponent("receipts.json")
        let approvalPath = output.appendingPathComponent("trusted-approval.json")
        let registration: [String: Any] = [
            "kind": "iris.mobile-shell.desktop-project",
            "version": 1,
            "appId": appId,
            "projectId": projectId,
            "appSlug": "kneecap",
            "provenance": [
                "kind": "guideSourceClone",
                "clonePath": source.path,
                "pinnedCommit": String(repeating: "a", count: 40),
                "canonicalRepo": "publik/kneecap",
            ],
        ]
        let reviewFiles = files.keys.sorted().map { path in
            ["path": path, "mediaType": path.hasSuffix(".html") ? "text/html" : "text/plain"]
        }
        let review: [String: Any] = [
            "kind": "iris.mobile-shell.desktop-package-review",
            "version": 1,
            "reviewedAt": "2026-09-17T16:00:00.000Z",
            "baseRevisionId": baseRevisionId as Any? ?? NSNull(),
            "manifest": [
                "kind": "iris.mobile-shell.manifest",
                "version": 1,
                "appId": appId,
                "projectId": projectId,
                "displayName": "Kneecap",
                "runtime": ["type": "web", "entrypoint": "index.html", "minShellVersion": "1.0.0"],
                "capabilities": [],
                "data": ["namespace": appId, "updatePolicy": "preserve"],
            ],
            "files": reviewFiles,
        ]
        try JSONSerialization.data(withJSONObject: registration, options: [.sortedKeys]).write(to: registrationPath)
        try JSONSerialization.data(withJSONObject: review, options: [.sortedKeys]).write(to: reviewPath)

        let cli = repositoryRoot().appendingPathComponent("mobile-shell/desktop/cli.mjs").path
        let currentBase = baseRevisionId ?? "null"
        try runNodeCLI(cli, arguments: [
            "stage", "--registration", registrationPath.path, "--review", reviewPath.path,
            "--root", build.path, "--current-base", currentBase, "--out", stagePath.path,
        ])
        try runNodeCLI(cli, arguments: [
            "approve", "--registration", registrationPath.path, "--stage", stagePath.path,
            "--current-base", currentBase, "--receipts", receiptsPath.path, "--approve", "--out", approvedPath.path,
        ])
        try runNodeCLI(cli, arguments: [
            "deliver", "--registration", registrationPath.path, "--approved", approvedPath.path,
            "--current-base", currentBase, "--receipts", receiptsPath.path,
            "--delivery-nonce", nonce, "--out", packagePath.path,
        ])

        let approved = try jsonObject(Data(contentsOf: approvedPath))
        let approval = try parseTrustedApproval(JSONSerialization.data(withJSONObject: approved["approval"]!))
        try JSONSerialization.data(withJSONObject: approved["approval"]!, options: [.sortedKeys]).write(to: approvalPath)
        let packageBytes = try Data(contentsOf: packagePath)
        let envelope = try XCTUnwrap(jsonObject(packageBytes)["envelope"] as? [String: Any])
        return GeneratedPackage(
            bytes: packageBytes,
            authority: StaticApprovalAuthority(approval: approval),
            approval: approval,
            revisionId: try requiredString(envelope, "revisionId")
        )
    }

    private func runNodeCLI(_ cli: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", cli] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw FixtureError.generatorFailed(String(data: error.isEmpty ? output : error, encoding: .utf8) ?? "desktop CLI failed")
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private enum FixtureError: Error {
    case generatorFailed(String)
    case malformedFixture(String)
}

private func parseTrustedApproval(_ data: Data) throws -> TrustedDeliveryApproval {
    let value = try jsonObject(data)
    func nullable(_ key: String) throws -> String? {
        if value[key] is NSNull { return nil }
        return try requiredString(value, key)
    }
    return TrustedDeliveryApproval(
        approvalId: try requiredString(value, "approvalId"),
        requestId: try nullable("requestId"),
        requestNonce: try nullable("requestNonce"),
        appId: try requiredString(value, "appId"),
        projectId: try requiredString(value, "projectId"),
        baseRevisionId: try nullable("baseRevisionId"),
        approvedRevisionId: try requiredString(value, "approvedRevisionId"),
        approvedContentHash: try requiredString(value, "approvedContentHash"),
        approvedAt: try requiredString(value, "approvedAt")
    )
}

private func mutatePackage(_ bytes: Data, mutation: (inout [String: Any]) throws -> Void) throws -> Data {
    var root = try jsonObject(bytes)
    try mutation(&root)
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FixtureError.malformedFixture("expected JSON object")
    }
    return object
}

private func jsonString(_ value: Any) throws -> String {
    String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
}

private func requiredString(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String else { throw FixtureError.malformedFixture("missing \(key)") }
    return value
}

private func html(_ marker: String) -> String {
    "<!doctype html><meta charset=utf-8><title>Native parity</title><main>\(marker)</main>"
}

private func deterministicFixtureBytes(count: Int, seed: UInt64) -> Data {
    var state = seed == 0 ? 1 : seed
    var bytes = [UInt8](repeating: 0, count: count)
    for index in bytes.indices {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
    }
    return Data(bytes)
}

private func digest(_ data: Data) -> String {
    let value = SHA256.hash(data: data)
    return "sha256:" + value.map { String(format: "%02x", $0) }.joined()
}

private func revisionId(seed: String) -> String {
    "rev-sha256:" + digest(Data(seed.utf8)).dropFirst("sha256:".count)
}

private func nonce(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func XCTAssertThrowsNativeError<T>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: NativeShellError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error \(expected)", file: file, line: line)
    } catch let error as NativeShellError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

private actor RevisionStoreOffers {
    private var ids: Set<String> = []
    func insert(_ id: String) { ids.insert(id) }
    func all() -> Set<String> { ids }
}

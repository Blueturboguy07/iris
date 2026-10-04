import Foundation
import XCTest
@testable import IrisMobileShellCore

final class NativeShellLibraryCoordinatorTests: XCTestCase {
    private let appId = "iris.coordinator-test"
    private let projectId = "iris.coordinator-test.mobile"

    func testPresentationGenerationRejectsLateOperationAfterNewerIntent() {
        var generation = NativeShellPresentationGeneration()
        let operationA = generation.advance()
        XCTAssertTrue(generation.isCurrent(operationA))
        let visibleReviewB = generation.advance()
        XCTAssertFalse(generation.isCurrent(operationA))
        XCTAssertTrue(generation.isCurrent(visibleReviewB))
    }

    func testReviewHasNoEffectsThenLocalApproveStagesActivateRevertAndPreservesReaderData() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let first = try fixture.generatePackage(
            content: html("first"),
            nonce: nonce("a"),
            appId: appId,
            projectId: projectId,
            namespace: "iris.coordinator-test.data"
        )

        let firstReview = try await coordinator.reviewImport(packageBytes: first.bytes)
        XCTAssertEqual(firstReview.identity, NativeShellAppIdentity(appId: appId, projectId: projectId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeRoot.appendingPathComponent("content").path))

        let stagedFirst = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: firstReview.reviewToken,
            packageSHA256: firstReview.packageSHA256
        )
        XCTAssertEqual(stagedFirst.revisionId, first.revisionId)
        var library = try await coordinator.refreshLibrary()
        XCTAssertEqual(library.count, 1)
        XCTAssertNil(library[0].currentRevisionId)
        XCTAssertEqual(library[0].stagedRevisions.map(\.revisionId), [first.revisionId])

        try await coordinator.activate(identity: firstReview.identity, revisionId: first.revisionId)
        let dataDirectory = try await coordinator.readerDataDirectory(
            identity: firstReview.identity,
            namespace: "iris.coordinator-test.data"
        )
        let note = dataDirectory.appendingPathComponent("note.txt")
        try Data("reader-owned".utf8).write(to: note)

        let second = try fixture.generatePackage(
            content: html("second"),
            baseRevisionId: first.revisionId,
            nonce: nonce("b"),
            appId: appId,
            projectId: projectId,
            namespace: "iris.coordinator-test.data"
        )
        let secondReview = try await coordinator.reviewImport(
            packageBytes: second.bytes,
            expectedIdentity: firstReview.identity
        )
        _ = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: secondReview.reviewToken,
            packageSHA256: secondReview.packageSHA256
        )
        try await coordinator.activate(identity: firstReview.identity, revisionId: second.revisionId)

        library = try await coordinator.refreshLibrary()
        XCTAssertEqual(library[0].currentRevisionId, second.revisionId)
        XCTAssertEqual(library[0].fallbackRevisionId, first.revisionId)
        try await coordinator.revert(identity: firstReview.identity, to: first.revisionId)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "reader-owned")
        library = try await coordinator.refreshLibrary()
        XCTAssertEqual(library[0].currentRevisionId, first.revisionId)
    }

    func testBundledDemoPairUsesRealBaseAndOpensActivateUpdateRevert() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let demoV1URL = coordinatorRepositoryRoot()
            .appendingPathComponent("mobile-shell/native/IrisMobileShellApp/Resources/SafeDemo.irisapp")
        let demoV2URL = coordinatorRepositoryRoot()
            .appendingPathComponent("mobile-shell/native/IrisMobileShellApp/Resources/SafeDemoUpdate.irisapp")
        let v1Bytes = try Data(contentsOf: demoV1URL)
        let v2Bytes = try Data(contentsOf: demoV2URL)
        let validator = DeliveryPackageV1Validator()
        let v1Inspection = try validator.inspect(packageBytes: v1Bytes)
        let v2Inspection = try validator.inspect(packageBytes: v2Bytes)
        XCTAssertEqual(v1Inspection.appId, "iris.native-demo")
        XCTAssertEqual(v1Inspection.projectId, "iris.native-demo.shell")
        XCTAssertEqual(v1Inspection.requestedCapabilities, [])
        XCTAssertEqual(v2Inspection.requestedCapabilities, [])
        XCTAssertEqual(v2Inspection.baseRevisionId, v1Inspection.revisionId)

        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let review = try await coordinator.reviewImport(packageBytes: v1Bytes)
        XCTAssertEqual(review.unsupportedCapabilities, [])
        _ = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: review.reviewToken,
            packageSHA256: review.packageSHA256
        )
        try await coordinator.activate(identity: review.identity, revisionId: review.revisionId)
        let launchV1 = try await coordinator.launchActive(identity: review.identity)
        XCTAssertEqual(launchV1.launchedRevisionId, v1Inspection.revisionId)
        XCTAssertTrue(try String(contentsOf: launchV1.launch.entrypointURL, encoding: .utf8).contains("VERSION 1"))

        let reviewV2 = try await coordinator.reviewImport(
            packageBytes: v2Bytes,
            expectedIdentity: review.identity
        )
        _ = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: reviewV2.reviewToken,
            packageSHA256: reviewV2.packageSHA256
        )
        try await coordinator.activate(identity: review.identity, revisionId: reviewV2.revisionId)
        let launchV2 = try await coordinator.launchActive(identity: review.identity)
        XCTAssertEqual(launchV2.launchedRevisionId, v2Inspection.revisionId)
        XCTAssertTrue(try String(contentsOf: launchV2.launch.entrypointURL, encoding: .utf8).contains("VERSION 2"))

        try await coordinator.revert(identity: review.identity, to: review.revisionId)
        let reverted = try await coordinator.launchActive(identity: review.identity)
        XCTAssertEqual(reverted.launchedRevisionId, v1Inspection.revisionId)
    }

    func testLocalUserReviewAuthorityIsOneUseAndDoesNotBecomeDesktopIdentity() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let package = try fixture.generatePackage(
            content: html("one-use"),
            nonce: nonce("c"),
            appId: appId,
            projectId: projectId
        )
        let validator = DeliveryPackageV1Validator()
        let inspection = try validator.inspect(packageBytes: package.bytes)
        let authority = LocalUserReviewApprovalAuthority(inspection: inspection)

        let validated = try validator.validate(packageBytes: package.bytes, approvalAuthority: authority)
        XCTAssertEqual(validated.revisionId, package.revisionId)
        XCTAssertThrowsError(try validator.validate(packageBytes: package.bytes, approvalAuthority: authority)) { error in
            XCTAssertEqual(error as? NativeShellError, .untrustedDeliveryApproval(inspection.embeddedApproval.approvalId))
        }
    }

    func testCancelReviewLeavesNoEffectsAndCannotApproveCanceledToken() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let package = try fixture.generatePackage(
            content: html("cancel"), nonce: nonce("d"), appId: appId, projectId: projectId
        )
        let review = try await coordinator.reviewImport(packageBytes: package.bytes)
        await coordinator.cancelReview()
        let pendingAfterCancel = await coordinator.pendingPackageReview()
        XCTAssertNil(pendingAfterCancel)
        await XCTAssertThrowsLibraryError(
            try await coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: review.reviewToken,
                packageSHA256: review.packageSHA256
            ),
            equals: .noPendingReview
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeRoot.appendingPathComponent("content").path))
    }

    func testWrongIdentityAndTamperedPackageAreRejectedBeforeReviewEffects() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let package = try fixture.generatePackage(
            content: html("identity"), nonce: nonce("e"), appId: appId, projectId: projectId
        )
        let wrongExpected = NativeShellAppIdentity(appId: "iris.other", projectId: "iris.other.mobile")
        await XCTAssertThrowsLibraryError(
            try await coordinator.reviewImport(packageBytes: package.bytes, expectedIdentity: wrongExpected),
            equals: .reviewIdentityMismatch(
                expected: wrongExpected,
                actual: NativeShellAppIdentity(appId: appId, projectId: projectId)
            )
        )

        let tampered = try mutatePackage(package.bytes) { root in
            var files = root["files"] as! [[String: Any]]
            var decoded = Data(base64Encoded: files[0]["contentBase64"] as! String)!
            decoded[decoded.startIndex] ^= 0xff
            files[0]["contentBase64"] = decoded.base64EncodedString()
            root["files"] = files
        }
        await XCTAssertThrowsNativeError(
            try await coordinator.reviewImport(packageBytes: tampered),
            equals: .hashMismatch("index.html")
        )
        let pendingAfterTamper = await coordinator.pendingPackageReview()
        XCTAssertNil(pendingAfterTamper)
    }

    func testUnsupportedNativeCapabilityIsVisibleAtReviewAndRejectedAtStage() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let package = try fixture.generatePackage(
            content: html("camera"),
            nonce: nonce("f"),
            capabilities: ["native.camera"],
            appId: appId,
            projectId: projectId
        )
        let review = try await coordinator.reviewImport(packageBytes: package.bytes)
        XCTAssertEqual(review.unsupportedCapabilities, ["native.camera"])
        await XCTAssertThrowsNativeError(
            try await coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: review.reviewToken,
                packageSHA256: review.packageSHA256
            ),
            equals: .unsupportedCapabilities(["native.camera"])
        )
    }

    func testStaleBaseBetweenReviewAndStageIsRejected() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let first = try fixture.generatePackage(
            content: html("base"), nonce: nonce("g"), appId: appId, projectId: projectId
        )
        let firstReview = try await coordinator.reviewImport(packageBytes: first.bytes)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: firstReview.reviewToken,
            packageSHA256: firstReview.packageSHA256
        )
        try await coordinator.activate(identity: identity, revisionId: first.revisionId)

        let staleCandidate = try fixture.generatePackage(
            content: html("stale"), baseRevisionId: first.revisionId, nonce: nonce("h"), appId: appId, projectId: projectId
        )
        let staleReview = try await coordinator.reviewImport(packageBytes: staleCandidate.bytes)
        let winner = try fixture.generatePackage(
            content: html("winner"), baseRevisionId: first.revisionId, nonce: nonce("i"), appId: appId, projectId: projectId
        )
        let directStore = try NativeRevisionStore(
            rootURL: fixture.storeRoot,
            appId: appId,
            projectId: projectId,
            shellVersion: "1.0.0"
        )
        _ = try await directStore.stage(packageBytes: winner.bytes, approvalAuthority: winner.authority)
        try await directStore.activate(revisionId: winner.revisionId)

        await XCTAssertThrowsNativeError(
            try await coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: staleReview.reviewToken,
                packageSHA256: staleReview.packageSHA256
            ),
            equals: .baseMismatch(expected: winner.revisionId, actual: first.revisionId)
        )
    }

    func testReviewReplacementRequiresExactVisibleTokenAndInvalidReplacementClearsOldReview() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let first = try fixture.generatePackage(content: html("A"), nonce: nonce("j"), appId: appId, projectId: projectId)
        let second = try fixture.generatePackage(content: html("B"), nonce: nonce("k"), appId: appId, projectId: projectId)

        let reviewA = try await coordinator.reviewImport(packageBytes: first.bytes)
        let reviewB = try await coordinator.reviewImport(packageBytes: second.bytes)
        await XCTAssertThrowsLibraryError(
            try await coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: reviewA.reviewToken,
                packageSHA256: reviewA.packageSHA256
            ),
            equals: .reviewTokenMismatch
        )
        let pendingB = await coordinator.pendingPackageReview()
        XCTAssertEqual(pendingB?.reviewToken, reviewB.reviewToken)

        let malformed = Data("not-json".utf8)
        await XCTAssertThrowsNativeError(
            try await coordinator.reviewImport(packageBytes: malformed),
            equals: .invalidPackageJSON
        )
        let pendingAfterMalformed = await coordinator.pendingPackageReview()
        XCTAssertNil(pendingAfterMalformed)
        await XCTAssertThrowsLibraryError(
            try await coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: reviewB.reviewToken,
                packageSHA256: reviewB.packageSHA256
            ),
            equals: .noPendingReview
        )
    }

    func testOlderClientReviewSequenceCannotOverwriteNewerPendingReview() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let older = try fixture.generatePackage(content: html("older"), nonce: nonce("n"), appId: appId, projectId: projectId)
        let newer = try fixture.generatePackage(content: html("newer"), nonce: nonce("o"), appId: appId, projectId: projectId)

        let reviewB = try await coordinator.reviewImport(
            packageBytes: newer.bytes,
            clientReviewSequence: 2
        )
        await XCTAssertThrowsLibraryError(
            try await coordinator.reviewImport(
                packageBytes: older.bytes,
                clientReviewSequence: 1
            ),
            equals: .reviewSuperseded
        )
        let pending = await coordinator.pendingPackageReview()
        XCTAssertEqual(pending?.reviewToken, reviewB.reviewToken)
        XCTAssertEqual(pending?.revisionId, newer.revisionId)
    }

    func testInFlightReviewCannotBeDoubleApprovedAndLateCompletionPreservesNewReview() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let first = try fixture.generatePackage(content: html("A"), nonce: nonce("l"), appId: appId, projectId: projectId)
        let second = try fixture.generatePackage(content: html("B"), nonce: nonce("m"), appId: appId, projectId: projectId)
        let reviewA = try await coordinator.reviewImport(packageBytes: first.bytes)
        let blockingAuthority = BlockingApprovalAuthority(approval: first.approval)

        let stageA = Task {
            try await coordinator.stagePendingReview(
                reviewToken: reviewA.reviewToken,
                packageSHA256: reviewA.packageSHA256,
                using: blockingAuthority
            )
        }
        XCTAssertEqual(blockingAuthority.entered.wait(timeout: .now() + 5), .success)

        let reviewB = try await coordinator.reviewImport(packageBytes: second.bytes)
        await XCTAssertThrowsLibraryError(
            try await coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: reviewA.reviewToken,
                packageSHA256: reviewA.packageSHA256
            ),
            equals: .reviewAlreadyStaging
        )

        blockingAuthority.release.signal()
        let outcomeA = try await stageA.value
        XCTAssertEqual(outcomeA.revisionId, first.revisionId)
        let pendingAfterLateA = await coordinator.pendingPackageReview()
        XCTAssertEqual(pendingAfterLateA?.reviewToken, reviewB.reviewToken)
    }
}

private struct GeneratedCoordinatorPackage {
    let bytes: Data
    let approval: TrustedDeliveryApproval
    let authority: CoordinatorApprovalAuthority
    let revisionId: String
}

private struct CoordinatorApprovalAuthority: DeliveryApprovalAuthority {
    let approval: TrustedDeliveryApproval

    func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval? {
        approval.approvalId == approvalId ? approval : nil
    }
}

private final class BlockingApprovalAuthority: DeliveryApprovalAuthority, @unchecked Sendable {
    let approval: TrustedDeliveryApproval
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    init(approval: TrustedDeliveryApproval) {
        self.approval = approval
    }

    func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval? {
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
        return approval.approvalId == approvalId ? approval : nil
    }
}

private final class CoordinatorFixture {
    let root: URL
    let storeRoot: URL
    private var packageIndex = 0

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-native-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func generatePackage(
        content: String,
        baseRevisionId: String? = nil,
        nonce: String,
        capabilities: [String] = [],
        appId: String,
        projectId: String,
        namespace: String? = nil
    ) throws -> GeneratedCoordinatorPackage {
        packageIndex += 1
        let output = root.appendingPathComponent("package-\(packageIndex)", isDirectory: true)
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
            "--namespace", namespace ?? appId,
            "--capabilities", try jsonString(capabilities),
            "--app", appId,
            "--project", projectId,
            "--display-name", "Coordinator Test",
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
            throw CoordinatorFixtureError.generatorFailed(String(data: errorData, encoding: .utf8) ?? "generator failed")
        }
        let result = try jsonObject(outputData)
        let packagePath = try requiredString(result, "packagePath")
        let approvalPath = try requiredString(result, "trustedApprovalPath")
        let revisionId = try requiredString(result, "revisionId")
        let approval = try parseTrustedApproval(Data(contentsOf: URL(fileURLWithPath: approvalPath)))
        return GeneratedCoordinatorPackage(
            bytes: try Data(contentsOf: URL(fileURLWithPath: packagePath)),
            approval: approval,
            authority: CoordinatorApprovalAuthority(approval: approval),
            revisionId: revisionId
        )
    }

    private func repositoryRoot() -> URL {
        coordinatorRepositoryRoot()
    }
}

private enum CoordinatorFixtureError: Error {
    case generatorFailed(String)
    case malformed(String)
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
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CoordinatorFixtureError.malformed("expected object")
    }
    return value
}

private func jsonString(_ value: Any) throws -> String {
    String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
}

private func requiredString(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String else {
        throw CoordinatorFixtureError.malformed("missing \(key)")
    }
    return value
}

private func html(_ marker: String) -> String {
    "<!doctype html><meta charset=utf-8><title>Coordinator</title><main>\(marker)</main>"
}

private func nonce(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func coordinatorRepositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func XCTAssertThrowsNativeError<T>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: NativeShellError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as NativeShellError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

private func XCTAssertThrowsLibraryError<T>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: NativeShellLibraryError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as NativeShellLibraryError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

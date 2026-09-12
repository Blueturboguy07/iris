//
//  GuideSessionControllerStaleWorkTests.swift
//  leanring-buddyTests
//
//  Controller-level regressions for guide work that can finish after the
//  reader has moved on. These tests use an in-process URLProtocol and never
//  construct or accept a UI surface.
//

import Foundation
import Testing
#if IRIS_HARNESS_STANDALONE
@testable import IrisHarnessNative
#else
@testable import Iris
#endif

@MainActor
@Suite(.serialized)
struct GuideSessionControllerStaleWorkTests {

    @Test("a primary action captured for an earlier step is ignored after the guide advances")
    func staleRenderedStepActionDoesNotAdvanceTheNewStep() async throws {
        StaleGuideURLProtocol.reset(blockFirstRequest: false)
        let fixture = try Self.makeFixture(slug: "stale-action")
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        await fixture.controller.openLatestVersionOfGuide(slug: "stale-action")
        let stepIdTheButtonWasRenderedFor = try #require(fixture.controller.currentStep?.id)

        fixture.controller.advanceToTheNextStep()
        #expect(fixture.controller.currentStep?.id == "second-step")

        fixture.controller.performPrimaryAction(
            expectedCurrentStepId: stepIdTheButtonWasRenderedFor
        )

        #expect(
            fixture.controller.currentStep?.id == "second-step",
            "a tap from the old card must not run the new step's primary action"
        )
        #expect(!fixture.controller.readerHasFinishedTheGuide)
    }

    @Test("a stale primary tap cannot release the back-navigation watch latch")
    func stalePrimaryTapCannotReleaseBackNavigationLatch() async throws {
        StaleGuideURLProtocol.reset(blockFirstRequest: false)
        let watchLoop = WatchLoop(
            localSignalSource: CompletedToolWatchSignals(),
            drivesItsOwnTickTimer: false
        )
        let fixture = try Self.makeFixture(
            slug: "stale-navigation-latch",
            watchLoop: watchLoop
        )
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

        await fixture.controller.openLatestVersionOfGuide(slug: "stale-navigation-latch")
        #expect(watchLoop.isWatchingAStep)
        fixture.controller.advanceToTheNextStep()
        let staleStepID = try #require(fixture.controller.currentStep?.id)
        fixture.controller.returnToThePreviousStep()
        #expect(fixture.controller.currentStep?.id == "first-step")
        #expect(watchLoop.isWatchingAStep)

        // The old second-step card is still able to deliver a tap. The guard
        // must run before the current-step action clears the deliberate-Back
        // latch; the completed local watch signal below would otherwise move
        // the reader forward immediately.
        fixture.controller.performPrimaryAction(expectedCurrentStepId: staleStepID)
        await watchLoop.performOneWatchTick()

        #expect(
            fixture.controller.currentStep?.id == "first-step",
            "a stale tap must not let a satisfied watch advance a step the reader returned to"
        )
    }

    @Test("a guide response that returns after close cannot reopen the closed session")
    func staleGuideResponseAfterCloseIsIgnored() async throws {
        StaleGuideURLProtocol.reset(blockFirstRequest: true)
        let fixture = try Self.makeFixture(slug: "stale-response")
        defer {
            StaleGuideURLProtocol.releaseFirstRequest()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }

        let openingTask = Task {
            await fixture.controller.openLatestVersionOfGuide(slug: "stale-response")
        }
        #expect(await Self.pump { StaleGuideURLProtocol.requestCount >= 1 })

        fixture.controller.closeTheGuide()
        StaleGuideURLProtocol.releaseFirstRequest()
        await openingTask.value

        #expect(fixture.controller.loadState == .noGuideIsOpen)
        #expect(fixture.controller.guideBeingFollowed == nil)
        #expect(fixture.controller.selectedBranch == nil)
    }

    @Test("a guide error that returns after close cannot replace the closed session")
    func staleGuideErrorAfterCloseIsIgnored() async throws {
        StaleGuideURLProtocol.reset(blockFirstRequest: true, failFirstRequest: true)
        let fixture = try Self.makeFixture(slug: "stale-error")
        defer {
            StaleGuideURLProtocol.releaseFirstRequest()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }

        let openingTask = Task {
            await fixture.controller.openLatestVersionOfGuide(slug: "stale-error")
        }
        #expect(await Self.pump { StaleGuideURLProtocol.requestCount >= 1 })

        fixture.controller.closeTheGuide()
        StaleGuideURLProtocol.releaseFirstRequest()
        await openingTask.value

        #expect(fixture.controller.loadState == .noGuideIsOpen)
        #expect(fixture.controller.guideBeingFollowed == nil)
    }

    @Test("a prerequisite result that returns after close cannot create a setup detour")
    func stalePrerequisiteResultAfterCloseIsIgnored() async throws {
        StaleGuideURLProtocol.reset(blockFirstRequest: false)
        let suspendedToolCheck = SuspendedToolCheck()
        let fixture = try Self.makeFixture(slug: "stale-prerequisite") { _ in
            await suspendedToolCheck.check()
        }
        defer {
            suspendedToolCheck.release()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }

        let openingTask = Task {
            await fixture.controller.openLatestVersionOfGuide(slug: "stale-prerequisite")
        }
        #expect(await Self.pump { suspendedToolCheck.didStart })

        fixture.controller.closeTheGuide()
        suspendedToolCheck.release()
        await openingTask.value

        #expect(fixture.controller.loadState == .noGuideIsOpen)
        #expect(fixture.controller.guideBeingFollowed == nil)
        #expect(fixture.controller.setupRecoveryState == nil)
    }

    private struct Fixture {
        let controller: GuideSessionController
        let defaults: UserDefaults
        let suiteName: String
    }

    private static func makeFixture(
        slug: String,
        watchLoop: WatchLoop? = nil,
        checkToolVersion: @escaping GuideToolVersionChecker = { toolName in
            ToolVersion(tool: toolName, available: true, version: "1.0")
        }
    ) throws -> Fixture {
        let suiteName = "iris.guide.stale-work.\(slug).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StaleGuideURLProtocol.self]
        let guideService = GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: configuration),
            userDefaults: defaults
        )
        let controller = GuideSessionController(
            guideService: guideService,
            watchLoop: watchLoop,
            checkToolVersion: checkToolVersion
        )
        return Fixture(controller: controller, defaults: defaults, suiteName: suiteName)
    }

    private static func pump(
        within seconds: Double = 3,
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class CompletedToolWatchSignals: WatchLoopLocalSignalSource {
    func frontmostApplicationBundleIdentifier() -> String? { nil }
    func frontmostApplicationName() -> String? { nil }
    func frontmostWindowTitle() -> String? { nil }
    func focusedWindowRectangleAndDisplaySizeInPoints() -> (window: CGRect, display: CGSize)? { nil }
    func hostOfTheURLInTheFrontmostWindow() -> String? { nil }
    func isToolInstalled(named toolName: String) async -> Bool {
        _ = toolName
        return true
    }
    func gitWorkingTreeHasACommit(atRepositoryPath repositoryPath: String) async -> Bool {
        _ = repositoryPath
        return false
    }
    func isAccessibilityElementPresent(matchingRoleLabel roleLabel: String) -> Bool {
        _ = roleLabel
        return false
    }
    func isSecureEventInputActive() -> Bool { false }
}

private final class SuspendedToolCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ToolVersion, Never>?
    private(set) var didStart = false

    func check() async -> ToolVersion {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.didStart = true
            self.continuation = continuation
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: ToolVersion(tool: "node", available: false, version: ""))
    }
}

private final class StaleGuideURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var firstRequestIsBlocked = false
    nonisolated(unsafe) private static var firstRequestShouldFail = false
    nonisolated(unsafe) private static var firstRequestRelease = DispatchSemaphore(value: 0)
    nonisolated(unsafe) private(set) static var requestCount = 0

    static func reset(blockFirstRequest: Bool, failFirstRequest: Bool = false) {
        lock.lock()
        firstRequestIsBlocked = blockFirstRequest
        firstRequestShouldFail = failFirstRequest
        firstRequestRelease = DispatchSemaphore(value: 0)
        requestCount = 0
        lock.unlock()
    }

    static func releaseFirstRequest() {
        firstRequestRelease.signal()
    }

    private static func nextRequestNumber() -> Int {
        lock.lock()
        requestCount += 1
        let requestNumber = requestCount
        lock.unlock()
        return requestNumber
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/api/iris/guides/") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let requestNumber = Self.nextRequestNumber()
        if requestNumber == 1 {
            let shouldBlock = Self.lockedFirstRequestIsBlocked
            if shouldBlock { Self.firstRequestRelease.wait() }
            if Self.lockedFirstRequestShouldFail {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
        }

        let responseBody = Data(Self.guideJSON(forSlug: requestURL.lastPathComponent).utf8)
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static var lockedFirstRequestIsBlocked: Bool {
        lock.lock()
        let shouldBlock = firstRequestIsBlocked
        lock.unlock()
        return shouldBlock
    }

    private static var lockedFirstRequestShouldFail: Bool {
        lock.lock()
        let shouldFail = firstRequestShouldFail
        lock.unlock()
        return shouldFail
    }

    override func stopLoading() {}

    private static func guideJSON(forSlug slug: String) -> String {
        let setupSteps: String = slug == "stale-prerequisite"
            ? """
              {"id":"install-node","kind":"terminal","title":"Install Node","body":"Install Node.","tool":"node","command":"install-node"}
            """
            : ""
        let navigationLatchFirstStepProperties = slug == "stale-navigation-latch"
            ? ",\"href\":\"not-a-reviewed-link\",\"watch\":{\"expect\":[{\"type\":\"toolVersion\",\"tool\":\"node\"}],\"sensitive\":true}"
            : ""
        return """
        {
          "appSlug": "\(slug)",
          "appName": "Stale Work",
          "version": 1,
          "status": "pilot",
          "sourceOwner": "test",
          "sourceRepo": "stale-work",
          "sourceCommit": null,
          "outputType": "credential",
          "estimatedMinutes": 1,
          "readmeSectionIds": [],
          "branches": [{
            "platform": "macos",
            "target": null,
            "label": "macOS",
            "shell": "terminal",
            "setupSteps": [\(setupSteps)],
            "steps": [
              {"id":"first-step","kind":"permission","title":"First step","body":"First."\(navigationLatchFirstStepProperties)},
              {"id":"second-step","kind":"permission","title":"Second step","body":"Second."}
            ],
            "unsupported": null
          }]
        }
        """
    }
}

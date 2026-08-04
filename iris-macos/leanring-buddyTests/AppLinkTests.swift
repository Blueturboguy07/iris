//
//  AppLinkTests.swift
//  leanring-buddyTests
//
//  Covers the app link: framing, discovery, and what Iris is willing to do with
//  an answer it could not authenticate.
//
//  Nothing here opens a socket. The framing is pure, discovery reads a
//  directory the test built in its own temporary location, and liveness is a
//  stub — otherwise the suite would depend on which processes happen to be
//  running on the machine executing it. The socket itself is exercised for real
//  against a real app by `packages/app-link` and by cue's own suite.
//

import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

struct AppLinkFramingTests {

    @Test func decodesOneMessagePerLine() throws {
        var decoder = AppLinkFrameDecoder()
        let frame = try AppLinkFrameEncoder.encode(id: 1, method: "describe", parameters: [:])
        let messages = try decoder.push(frame)

        #expect(messages.count == 1)
        #expect(messages[0]["method"] as? String == "describe")
        #expect(messages[0]["id"] as? Int == 1)
        #expect(messages[0]["jsonrpc"] as? String == "2.0")
    }

    /// A stream arrives in whatever pieces the kernel felt like. This is the
    /// single easiest thing to get wrong in a line-framed protocol.
    @Test func reassemblesAMessageSplitAcrossReads() throws {
        var decoder = AppLinkFrameDecoder()
        let frame = try AppLinkFrameEncoder.encode(id: 7, method: "get_state", parameters: [:])

        #expect(try decoder.push(frame.prefix(9)).isEmpty)
        let messages = try decoder.push(frame.dropFirst(9))
        #expect(messages.count == 1)
        #expect(messages[0]["id"] as? Int == 7)
    }

    @Test func returnsEveryMessageWhenSeveralArriveAtOnce() throws {
        var decoder = AppLinkFrameDecoder()
        var chunk = try AppLinkFrameEncoder.encode(id: 1, method: "a", parameters: [:])
        chunk.append(try AppLinkFrameEncoder.encode(id: 2, method: "b", parameters: [:]))
        #expect(try decoder.push(chunk).count == 2)
    }

    @Test func rejectsSomethingThatIsNotJSON() throws {
        var decoder = AppLinkFrameDecoder()
        #expect(throws: AppLinkFrameDecoder.DecodeFailure.notJSON) {
            _ = try decoder.push(Data("{not json}\n".utf8))
        }
    }

    /// The reason the cap exists: a peer that sends bytes and never a newline
    /// would otherwise grow this buffer without limit.
    @Test func refusesToBufferAnUnterminatedFrameForever() throws {
        var decoder = AppLinkFrameDecoder(maximumFrameBytes: 64)
        #expect(throws: AppLinkFrameDecoder.DecodeFailure.frameTooLarge) {
            _ = try decoder.push(Data(repeating: 0x41, count: 512))
        }
    }
}

struct AppLinkDiscoveryTests {

    /// Everything is alive.
    private struct AlwaysRunning: ProcessLivenessChecking {
        func isRunning(_ pid: pid_t) -> Bool { true }
    }

    /// Only the PIDs it was told about.
    private struct RunningOnly: ProcessLivenessChecking {
        let alive: Set<pid_t>
        func isRunning(_ pid: pid_t) -> Bool { alive.contains(pid) }
    }

    private func makeRunDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("app-link-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeInstanceFile(
        in directory: URL,
        appId: String,
        pid: pid_t,
        protocolVersion: String = AppLinkProtocol.version,
        instanceId: String = UUID().uuidString
    ) throws {
        let record: [String: Any] = [
            "schema": 1,
            "appId": appId,
            "appSlug": appId.components(separatedBy: ".").last ?? appId,
            "appName": appId,
            "appVersion": "1.2.3",
            "protocolVersion": protocolVersion,
            "socketPath": directory.appendingPathComponent("\(appId).sock").path,
            "pid": Int(pid),
            "instanceId": instanceId,
            "token": "a-token",
            "startedAt": "2026-08-04T00:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: directory.appendingPathComponent("\(appId).json"))
    }

    @Test func readsARunningApp() throws {
        let directory = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeInstanceFile(in: directory, appId: "com.cue.overlay", pid: 4242)

        let instances = AppLinkDiscovery.runningInstances(in: directory, liveness: AlwaysRunning())
        #expect(instances.count == 1)
        #expect(instances[0].appId == "com.cue.overlay")
        #expect(instances[0].appSlug == "overlay")
        #expect(instances[0].appVersion == "1.2.3")
        #expect(instances[0].processIdentifier == 4242)
        #expect(instances[0].speaksAKnownProtocol)
    }

    /// The point of writing the PID down: a file left behind by a crash must
    /// not look like a running app forever.
    @Test func dropsAndDeletesAnEntryWhoseProcessIsGone() throws {
        let directory = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeInstanceFile(in: directory, appId: "com.cue.overlay", pid: 100)
        try writeInstanceFile(in: directory, appId: "com.dead.app", pid: 200)

        let instances = AppLinkDiscovery.runningInstances(in: directory, liveness: RunningOnly(alive: [100]))
        #expect(instances.map(\.appId) == ["com.cue.overlay"])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("com.dead.app.json").path))
    }

    @Test func ignoresAHalfWrittenFileRatherThanFailingDiscovery() throws {
        let directory = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeInstanceFile(in: directory, appId: "com.cue.overlay", pid: 100)
        try Data("{\"appId\": \"com.brok".utf8).write(to: directory.appendingPathComponent("com.broken.app.json"))

        #expect(AppLinkDiscovery.runningInstances(in: directory, liveness: AlwaysRunning()).count == 1)
    }

    @Test func reportsAnEmptyListWhenNothingIsRunning() throws {
        let directory = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(AppLinkDiscovery.runningInstances(in: directory, liveness: AlwaysRunning()).isEmpty)
    }

    /// An unknown protocol version is a reason to stop rather than to try
    /// anyway and misread whatever comes back.
    @Test func marksAnAppSpeakingAnotherProtocolVersion() throws {
        let directory = try makeRunDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeInstanceFile(in: directory, appId: "com.future.app", pid: 100, protocolVersion: "99")

        let instance = try #require(AppLinkDiscovery.runningInstance(appId: "com.future.app", in: directory, liveness: AlwaysRunning()))
        #expect(!instance.speaksAKnownProtocol)
    }
}

struct AppLinkReportTests {

    private func makeReport(
        verification: AppLinkPeerVerification,
        lastError: AppLinkEvent? = nil,
        events: [AppLinkEvent] = [],
        state: String? = nil
    ) -> AppLinkReport {
        let instance = AppLinkInstance(
            appId: "com.cue.overlay",
            appSlug: "cue",
            appName: "cue",
            appVersion: "0.2.1",
            socketPath: "/tmp/cue.sock",
            processIdentifier: 100,
            instanceId: "instance-1",
            token: "a-token"
        )
        return AppLinkReport(
            instance: instance,
            verification: verification,
            session: AppLinkSession(
                protocolVersion: AppLinkProtocol.version,
                instanceId: "instance-1",
                appId: "com.cue.overlay",
                appSlug: "cue",
                appName: "cue",
                appVersion: "0.2.1",
                grantedScopes: ["read"],
                deniedScopes: []
            ),
            diagnostics: AppLinkDiagnostics(
                appId: "com.cue.overlay",
                appSlug: "cue",
                appVersion: "0.2.1",
                generatedAt: "2026-08-04T00:00:00Z",
                osVersion: "24.6.0",
                runtime: "node 20",
                lastError: lastError,
                events: events,
                stateSummary: state,
                isTrustworthy: verification == .codeSignature
            )
        )
    }

    /// The property that keeps the public breaks tally honest. Anything running
    /// under this account can open a socket and claim to be an app; showing
    /// what it said is fine, and letting it write a public number is not.
    @Test func refusesToSubmitAnAnswerFromAnUnverifiedPeer() {
        #expect(!makeReport(verification: .none).mayBeSubmitted)
        #expect(!makeReport(verification: .token).mayBeSubmitted)
        #expect(makeReport(verification: .codeSignature).mayBeSubmitted)
    }

    @Test func summarizesTheFailureForTheAssistant() throws {
        let report = makeReport(
            verification: .codeSignature,
            lastError: AppLinkEvent(
                sequence: 4,
                timestamp: "2026-08-04T00:00:00Z",
                level: "error",
                message: "no access to a speech model",
                frame: "handleSttError"
            ),
            events: [
                AppLinkEvent(sequence: 3, timestamp: "2026-08-04T00:00:00Z", level: "warn", message: "another application holds the leetcode shortcut")
            ],
            state: "{\"transcriptionDisabled\":true}"
        )

        let summary = try #require(report.summaryForAssistant)
        #expect(summary.contains("cue 0.2.1 is running."))
        #expect(summary.contains("transcriptionDisabled"))
        #expect(summary.contains("no access to a speech model in handleSttError"))
        #expect(summary.contains("another application holds the leetcode shortcut"))
    }

    @Test func saysNothingWhenThereIsNothingToSay() {
        let report = AppLinkReport(
            instance: AppLinkInstance(
                appId: "com.cue.overlay",
                appName: "cue",
                socketPath: "/tmp/cue.sock",
                processIdentifier: 100,
                instanceId: "instance-1",
                token: "a-token"
            ),
            verification: .codeSignature,
            session: AppLinkSession(
                protocolVersion: AppLinkProtocol.version,
                instanceId: "instance-1",
                appId: "com.cue.overlay",
                appSlug: nil,
                appName: "cue",
                appVersion: nil,
                grantedScopes: [],
                deniedScopes: ["read"]
            ),
            diagnostics: nil
        )
        #expect(report.summaryForAssistant == nil)
        #expect(!report.session.canRead)
    }
}

struct AppLinkEventParsingTests {

    @Test func readsTheConventionsEventShape() throws {
        let event = try #require(AppLinkEvent(json: [
            "seq": 12,
            "ts": "2026-08-04T04:11:07Z",
            "level": "error",
            "msg": "ScreenCaptureKit timed out after 5000ms",
            "frame": "CaptureService.grab",
            "code": "SCK_TIMEOUT",
            "event": "capture_failed",
        ]))

        #expect(event.sequence == 12)
        #expect(event.level == "error")
        #expect(event.isFailure)
        #expect(event.frame == "CaptureService.grab")
        #expect(event.code == "SCK_TIMEOUT")
    }

    /// `msg` is the one required field; everything else improves grouping.
    @Test func refusesAnEventWithNoMessage() {
        #expect(AppLinkEvent(json: ["level": "error", "frame": "X.y"]) == nil)
    }

    @Test func treatsAWarningAsSomethingOtherThanAFailure() throws {
        let event = try #require(AppLinkEvent(json: ["msg": "slow frame", "level": "warn"]))
        #expect(!event.isFailure)
    }
}

struct AppLinkPeerVerifierTests {

    /// Both halves matter. Without `anchor apple generic` a self-signed
    /// certificate carrying our OU would satisfy the requirement, which is the
    /// whole point of pinning to Apple's root.
    @Test func requirementNamesBothAppleAndOurTeam() {
        let requirement = AppLinkPeerVerifier.designatedRequirement()
        #expect(requirement.contains("anchor apple generic"))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"R5R3ZS54LV\""))
    }

    /// A descriptor that is not a socket has no peer, and the answer to "who is
    /// that" must be "nobody" rather than a crash or an optimistic guess.
    @Test func reportsNoVerificationForSomethingThatIsNotAConnectedSocket() {
        #expect(AppLinkPeerVerifier.verify(descriptor: -1) == .none)
    }
}

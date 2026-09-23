import Foundation
import CoreGraphics
import Darwin
import Testing
@testable import Iris

@Suite("Codex screen help and Stop")
@MainActor
struct CodexChatScreenHelpTests {
    @Test func codexPromptKeepsPointingAndHandoffsWithoutPromisingActionTools() {
        let prompt = CodexChatResponder.chatPromptText(
            systemPrompt: CompanionManager.codexScreenHelpSystemPrompt,
            conversationHistory: [],
            userPrompt: "Describe the visible window",
            imageLabels: ["Fixture display"]
        ).lowercased()

        #expect(prompt.contains("[point:x,y:label]"))
        #expect(prompt.contains("install and customize"))
        #expect(!prompt.contains("run_a_command_in_the_terminal"))
        #expect(!prompt.contains("put_text_on_the_clipboard"))
        #expect(!prompt.contains("open_an_install_guide"))
        #expect(prompt.contains("image 1: fixture display"))
        #expect(!CodexChatResponder.supportsChatActionTools)
    }

    @Test func codexDiagnosticsExposeOnlyAllowlistedCategories() {
        #expect(CodexChatResponder.failureDiagnosticClass(for: CancellationError()) == "cancelled")
        #expect(CodexChatResponder.failureDiagnosticClass(
            for: MaintainModelProviderError.requestFailed("private prompt and stderr")
        ) == "codex_provider")

        struct PrivateError: Error {}
        #expect(CodexChatResponder.failureDiagnosticClass(for: PrivateError()) == "other")
    }

    @Test func dispatchedCodexRouteKeepsCategoricalLoggingAfterProviderPickerChanges() {
        var selectedProvider: AssistantProviderPreference? = .codex
        let dispatchedRoute = CompanionManager.ChatResponseRoute(resolvedProvider: selectedProvider)

        // The reader may change the picker before this already-dispatched
        // request fails. Diagnostics must still follow the route that ran.
        selectedProvider = .anthropicKey
        let nextRequestRoute = CompanionManager.ChatResponseRoute(resolvedProvider: selectedProvider)

        #expect(dispatchedRoute == .codex)
        #expect(!dispatchedRoute.logsFailureDetails)
        #expect(nextRequestRoute == .http)
        #expect(nextRequestRoute.logsFailureDetails)
    }

    @Test func selectedCodexImageStagingFailsClosedOnAnyWriteError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-codex-image-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try CodexExecImageStager.stage(
                [Data([1]), Data([2])],
                in: directory,
                requireAllImages: true,
                write: { data, url in
                    if url.lastPathComponent == "attachment-1.png" { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: url)
                }
            )
            Issue.record("Expected image staging to fail instead of sending a partial request")
        } catch let error as MaintainModelProviderError {
            guard case .requestFailed(let message) = error else {
                Issue.record("Unexpected provider error: \(error)")
                return
            }
            #expect(message.contains("no request was sent"))
        }
    }

    @Test func cancellationBeforeLaunchPreventsTheFakeCliFromStarting() async throws {
        let (directory, binaryPath) = try makeFakeCLI(contents: "exit 0\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")

        let cancellation = CodexExecCancellation()
        cancellation.cancel()
        do {
            _ = try await CodexMaintainProvider.runCodexExec(
                codexBinaryPath: binaryPath,
                promptText: "fixture-only",
                attachedImagePNGDataList: [],
                model: nil,
                webSearchEnabled: false,
                timeoutSeconds: 1,
                cancellation: cancellation
            )
            Issue.record("A canceled route must not launch the CLI")
        } catch is CancellationError {
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func requestCancellationTerminatesOnlyItsRunningFakeCli() async throws {
        let (directory, binaryPath) = try makeFakeCLI(contents: "while :; do :; done\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let requestTask = Task<Void, Error> {
            try await CodexChatResponder.withRequestCancellation { cancellation in
                _ = try await CodexMaintainProvider.runCodexExec(
                    codexBinaryPath: binaryPath,
                    promptText: "fixture-only",
                    attachedImagePNGDataList: [],
                    model: nil,
                    webSearchEnabled: false,
                    timeoutSeconds: 10,
                    cancellation: cancellation
                )
            }
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))

        let cancellationStartedAt = Date()
        requestTask.cancel()
        do {
            try await requestTask.value
            Issue.record("The owned fake CLI should be canceled")
        } catch is CancellationError {
            #expect(Date().timeIntervalSince(cancellationStartedAt) < 1.5)
        }
    }

    @Test func requestCancellationDoesNotLeaveItsOwnedFakeCliDescendantRunning() async throws {
        let (directory, binaryPath) = try makeFakeCLI(contentsForDirectory: { directory in
            let childPIDPath = directory.appendingPathComponent("child.pid").path
            let parentPIDPath = directory.appendingPathComponent("parent.pid").path
            return """
            /bin/sleep 60 &
            child_pid=$!
            printf '%s\\n' "$child_pid" > '\(childPIDPath)'
            printf '%s\\n' "$$" > '\(parentPIDPath)'
            while :; do /bin/sleep 1; done
            """
        })
        var ownedChild: OwnedFakeCLIChild?
        defer {
            if let ownedChild {
                terminateOnlyOwnedFakeCLIChild(ownedChild)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let childPIDURL = directory.appendingPathComponent("child.pid")
        let parentPIDURL = directory.appendingPathComponent("parent.pid")
        let requestTask = Task<Void, Error> {
            try await CodexChatResponder.withRequestCancellation { cancellation in
                _ = try await CodexMaintainProvider.runCodexExec(
                    codexBinaryPath: binaryPath,
                    promptText: "fixture-only",
                    attachedImagePNGDataList: [],
                    model: nil,
                    webSearchEnabled: false,
                    timeoutSeconds: 10,
                    cancellation: cancellation
                )
            }
        }

        var capturedChild: OwnedFakeCLIChild?
        for _ in 0..<200 where capturedChild == nil {
            if let childPIDText = try? String(contentsOf: childPIDURL, encoding: .utf8),
               let parentPIDText = try? String(contentsOf: parentPIDURL, encoding: .utf8),
               let childPID = Int32(childPIDText.trimmingCharacters(in: .whitespacesAndNewlines)),
               let parentPID = Int32(parentPIDText.trimmingCharacters(in: .whitespacesAndNewlines)),
               let childSnapshot = fakeCLIProcessSnapshot(processIdentifier: childPID),
               let parentSnapshot = fakeCLIProcessSnapshot(processIdentifier: parentPID),
               childSnapshot.parentProcessIdentifier == parentPID {
                capturedChild = OwnedFakeCLIChild(
                    processIdentifier: childPID,
                    processGroupIdentifier: childSnapshot.processGroupIdentifier,
                    startTime: childSnapshot.startTime,
                    command: childSnapshot.command
                )
                #expect(childSnapshot.processGroupIdentifier == parentSnapshot.processGroupIdentifier)
                #expect(childSnapshot.command.hasSuffix("sleep 60"))
            } else {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        guard let capturedChild else {
            requestTask.cancel()
            _ = try? await requestTask.value
            Issue.record("The fake CLI did not publish an owned child identity")
            return
        }
        ownedChild = capturedChild

        requestTask.cancel()
        do {
            try await requestTask.value
            Issue.record("The owned fake CLI request should be canceled")
        } catch is CancellationError {
            // Expected: the Ask task cancellation completed.
        }

        var survivingSnapshot = fakeCLIProcessSnapshot(processIdentifier: capturedChild.processIdentifier)
        for _ in 0..<100 {
            let isSameRunningChild = survivingSnapshot.map {
                $0.state.first != "Z"
                    && $0.processGroupIdentifier == capturedChild.processGroupIdentifier
                    && $0.startTime == capturedChild.startTime
                    && $0.command == capturedChild.command
            } ?? false
            if !isSameRunningChild { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            survivingSnapshot = fakeCLIProcessSnapshot(processIdentifier: capturedChild.processIdentifier)
        }
        let descendantStillRunning = survivingSnapshot.map {
            $0.state.first != "Z"
                && $0.processGroupIdentifier == capturedChild.processGroupIdentifier
                && $0.startTime == capturedChild.startTime
                && $0.command == capturedChild.command
        } ?? false
        #expect(
            !descendantStillRunning,
            "Cancellation left fixture child pid=\(capturedChild.processIdentifier), pgid=\(capturedChild.processGroupIdentifier), start=\(capturedChild.startTime), command=\(capturedChild.command)"
        )
    }

    @Test func requestCancellationEscalatesForItsTermIgnoringFakeCliDescendant() async throws {
        let (directory, binaryPath) = try makeFakeCLI(contentsForDirectory: { directory in
            let childPIDPath = directory.appendingPathComponent("child.pid").path
            let parentPIDPath = directory.appendingPathComponent("parent.pid").path
            return """
            /bin/sh -c 'trap "" TERM; exec /bin/sleep 60' &
            child_pid=$!
            printf '%s\\n' "$child_pid" > '\(childPIDPath)'
            printf '%s\\n' "$$" > '\(parentPIDPath)'
            while :; do /bin/sleep 1; done
            """
        })
        var ownedChild: OwnedFakeCLIChild?
        defer {
            if let ownedChild { terminateOnlyOwnedFakeCLIChild(ownedChild) }
            try? FileManager.default.removeItem(at: directory)
        }

        let childPIDURL = directory.appendingPathComponent("child.pid")
        let parentPIDURL = directory.appendingPathComponent("parent.pid")
        let requestTask = Task<Void, Error> {
            try await CodexChatResponder.withRequestCancellation { cancellation in
                _ = try await CodexMaintainProvider.runCodexExec(
                    codexBinaryPath: binaryPath,
                    promptText: "fixture-only",
                    attachedImagePNGDataList: [],
                    model: nil,
                    webSearchEnabled: false,
                    timeoutSeconds: 8,
                    cancellation: cancellation
                )
            }
        }

        var capturedChild: OwnedFakeCLIChild?
        for _ in 0..<200 where capturedChild == nil {
            if let childPIDText = try? String(contentsOf: childPIDURL, encoding: .utf8),
               let parentPIDText = try? String(contentsOf: parentPIDURL, encoding: .utf8),
               let childPID = Int32(childPIDText.trimmingCharacters(in: .whitespacesAndNewlines)),
               let parentPID = Int32(parentPIDText.trimmingCharacters(in: .whitespacesAndNewlines)),
               let childSnapshot = fakeCLIProcessSnapshot(processIdentifier: childPID),
               let parentSnapshot = fakeCLIProcessSnapshot(processIdentifier: parentPID),
               childSnapshot.parentProcessIdentifier == parentPID,
               childSnapshot.command.hasSuffix("sleep 60") {
                capturedChild = OwnedFakeCLIChild(
                    processIdentifier: childPID,
                    processGroupIdentifier: childSnapshot.processGroupIdentifier,
                    startTime: childSnapshot.startTime,
                    command: childSnapshot.command
                )
                #expect(childSnapshot.processGroupIdentifier == parentSnapshot.processGroupIdentifier)
            } else {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        guard let capturedChild else {
            requestTask.cancel()
            _ = try? await requestTask.value
            Issue.record("The fake CLI did not publish an owned TERM-ignoring child identity")
            return
        }
        ownedChild = capturedChild

        let cancellationStartedAt = Date()
        requestTask.cancel()
        do {
            try await requestTask.value
            Issue.record("Cancellation should finish after escalating against the owned TERM-ignoring child")
        } catch is CancellationError {
            #expect(Date().timeIntervalSince(cancellationStartedAt) < 1.5)
        }

        var remaining = fakeCLIProcessSnapshot(processIdentifier: capturedChild.processIdentifier)
        for _ in 0..<350 {
            let isSameRunningChild = remaining.map {
                $0.state.first != "Z"
                    && $0.processGroupIdentifier == capturedChild.processGroupIdentifier
                    && $0.startTime == capturedChild.startTime
                    && $0.command == capturedChild.command
            } ?? false
            if !isSameRunningChild { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            remaining = fakeCLIProcessSnapshot(processIdentifier: capturedChild.processIdentifier)
        }
        #expect(
            remaining == nil || remaining?.state.first == "Z"
                || remaining?.processGroupIdentifier != capturedChild.processGroupIdentifier
                || remaining?.startTime != capturedChild.startTime
                || remaining?.command != capturedChild.command,
            "The exact TERM-ignoring fixture child survived cancellation"
        )
    }

    @Test func processGroupSignalPolicyRefusesUnknownReusedAndUnboundedMembership() {
        let leader = CodexExecProcessIdentity(
            processIdentifier: 41001,
            userIdentifier: 501,
            processGroupIdentifier: 41001,
            startSeconds: 10,
            startMicroseconds: 20
        )
        let child = CodexExecProcessIdentity(
            processIdentifier: 41002,
            userIdentifier: 501,
            processGroupIdentifier: 41001,
            startSeconds: 11,
            startMicroseconds: 21
        )
        let recorded: Set<CodexExecProcessIdentity> = [leader, child]

        #expect(CodexExecProcessGroupSignalPolicy.maySignalOwnedGroup(
            leader: leader,
            callerProcessGroupIdentifier: 30000,
            recordedMembers: recorded,
            currentMembers: [leader, child],
            enumerationWasComplete: true
        ))
        #expect(CodexExecProcessGroupSignalPolicy.maySignalOwnedGroup(
            leader: leader,
            callerProcessGroupIdentifier: 30000,
            recordedMembers: recorded,
            currentMembers: [child],
            enumerationWasComplete: true
        ))

        let unknown = CodexExecProcessIdentity(
            processIdentifier: 41003,
            userIdentifier: 501,
            processGroupIdentifier: 41001,
            startSeconds: 12,
            startMicroseconds: 22
        )
        let reusedPID = CodexExecProcessIdentity(
            processIdentifier: child.processIdentifier,
            userIdentifier: child.userIdentifier,
            processGroupIdentifier: child.processGroupIdentifier,
            startSeconds: child.startSeconds + 1,
            startMicroseconds: child.startMicroseconds
        )
        #expect(!CodexExecProcessGroupSignalPolicy.maySignalOwnedGroup(
            leader: leader,
            callerProcessGroupIdentifier: 30000,
            recordedMembers: recorded,
            currentMembers: [leader, unknown],
            enumerationWasComplete: true
        ))
        #expect(!CodexExecProcessGroupSignalPolicy.maySignalOwnedGroup(
            leader: leader,
            callerProcessGroupIdentifier: 30000,
            recordedMembers: recorded,
            currentMembers: [leader, reusedPID],
            enumerationWasComplete: true
        ))
        #expect(!CodexExecProcessGroupSignalPolicy.maySignalOwnedGroup(
            leader: leader,
            callerProcessGroupIdentifier: 30000,
            recordedMembers: recorded,
            currentMembers: [leader, child],
            enumerationWasComplete: false
        ))
        #expect(!CodexExecProcessGroupSignalPolicy.maySignalOwnedGroup(
            leader: leader,
            callerProcessGroupIdentifier: leader.processGroupIdentifier,
            recordedMembers: recorded,
            currentMembers: [leader, child],
            enumerationWasComplete: true
        ))
    }

    @Test func inheritedOutputPipeHasItsOwnBoundAndDoesNotBlockMainActor() async throws {
        let (directory, binaryPath) = try makeFakeCLI(contents: """
        printf '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"partial\"}}\\n'
        (sleep 1) &
        exit 0
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        var mainActorPulses = 0
        let pulseTask = Task { @MainActor in
            while !Task.isCancelled {
                mainActorPulses += 1
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let startedAt = Date()
        do {
            _ = try await CodexMaintainProvider.runCodexExec(
                codexBinaryPath: binaryPath,
                promptText: "fixture-only",
                attachedImagePNGDataList: [],
                model: nil,
                webSearchEnabled: false,
                timeoutSeconds: 0.2,
                emptyReplyRetryWaitSecondsOverride: 0
            )
            Issue.record("Partial JSONL must not be accepted when a pipe drain times out")
        } catch let error as MaintainModelProviderError {
            guard case .requestFailed(let message) = error else {
                pulseTask.cancel()
                Issue.record("Unexpected provider error: \(error)")
                return
            }
            #expect(message.contains("output pipes did not close"))
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        pulseTask.cancel()
        #expect(elapsed < 0.8)
        #expect(mainActorPulses >= 3)
    }

    @Test func ordinaryStdoutAndStderrDrainConcurrently() async throws {
        let (directory, binaryPath) = try makeFakeCLI(contents: """
        head -c 131072 /dev/zero | tr '\\000' o
        head -c 131072 /dev/zero | tr '\\000' e >&2
        output_path=''
        previous=''
        for argument in "$@"; do
            if [ "$previous" = "--output-last-message" ]; then output_path="$argument"; break; fi
            previous="$argument"
        done
        printf 'complete response' > "$output_path"
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let response = try await CodexMaintainProvider.runCodexExec(
            codexBinaryPath: binaryPath,
            promptText: "fixture-only",
            attachedImagePNGDataList: [],
            model: nil,
            webSearchEnabled: false,
            timeoutSeconds: 3
        )
        #expect(response == "complete response")
    }

    @Test func stopInvalidatesLateAskAndPreservesDraftHistoryAndOtherFlows() async throws {
        let fixture = try makeIsolatedManagerFixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.testHarnessSeedConversationExchange(question: "Earlier question", answer: "Earlier answer")
        let draft = OverlayEyeInputBarDraft(text: "unsent follow-up", editKind: .feature)
        manager.inputBarDraftStore.remember(draft)

        let editPhaseBeforeStop = manager.onDemandEditCoordinator.phase
        let guideLoadStateBeforeStop = manager.guideSessionController.loadState
        let historyCountBeforeStop = manager.testHarnessConversationHistoryCount
        let transcriptCountBeforeStop = manager.chatTranscriptStore.recentExchanges(limit: 10).count
        let responseGenerationBeforeStop = manager.assistantResponseGenerationCount
        let askTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let responseID = manager.testHarnessInstallPendingAskResponse(task: askTask, withPointingTarget: true)

        manager.stopCurrentAskResponse()
        let identifierAfterFirstStop = manager.testHarnessChatResponseIdentifier
        manager.stopCurrentAskResponse()
        await askTask.value

        #expect(!manager.chatResponseIsPending)
        #expect(askTask.isCancelled)
        #expect(identifierAfterFirstStop != responseID)
        #expect(manager.testHarnessChatResponseIdentifier == identifierAfterFirstStop)
        #expect(!manager.testHarnessAcceptsChatResponse(responseID))
        #expect(manager.detectedElementScreenLocation == nil)
        #expect(manager.detectedElementDisplayFrame == nil)
        #expect(manager.detectedElementBubbleText == nil)
        #expect(manager.assistantState == .idle)
        #expect(manager.testHarnessConversationHistoryCount == historyCountBeforeStop)
        #expect(manager.chatTranscriptStore.recentExchanges(limit: 10).count == transcriptCountBeforeStop)
        #expect(manager.inputBarDraftStore.draft == draft)
        #expect(manager.onDemandEditCoordinator.phase == editPhaseBeforeStop)
        #expect(manager.guideSessionController.loadState == guideLoadStateBeforeStop)
        #expect(manager.assistantResponseGenerationCount == responseGenerationBeforeStop)
    }

    @Test func stopWithoutPendingAskIsAnInertNoOp() throws {
        let fixture = try makeIsolatedManagerFixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let responseID = manager.testHarnessChatResponseIdentifier
        let point = CGPoint(x: 42, y: 84)
        manager.detectedElementScreenLocation = point
        manager.detectedElementBubbleText = "owned by another surface"

        manager.stopCurrentAskResponse()

        #expect(!manager.chatResponseIsPending)
        #expect(manager.testHarnessChatResponseIdentifier == responseID)
        #expect(manager.detectedElementScreenLocation == point)
        #expect(manager.detectedElementBubbleText == "owned by another surface")
    }

    @Test func newChatCancelsPendingAskAndClearsItsWorkingEyeWithoutErasingTranscript() async throws {
        let fixture = try makeIsolatedManagerFixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.testHarnessSeedConversationExchange(question: "Earlier question", answer: "Earlier answer")
        let transcriptCountBeforeNewChat = manager.chatTranscriptStore.recentExchanges(limit: 10).count
        let responseGenerationBeforeNewChat = manager.assistantResponseGenerationCount
        let editPhaseBeforeNewChat = manager.onDemandEditCoordinator.phase
        let askTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let pendingIdentifier = manager.testHarnessInstallPendingAskResponse(
            task: askTask, withPointingTarget: true, state: .thinking
        )

        manager.startANewChat()
        await askTask.value

        #expect(askTask.isCancelled)
        #expect(!manager.chatResponseIsPending)
        #expect(!manager.testHarnessAcceptsChatResponse(pendingIdentifier))
        #expect(manager.assistantState == .idle)
        #expect(manager.detectedElementScreenLocation == nil)
        #expect(manager.detectedElementDisplayFrame == nil)
        #expect(manager.detectedElementBubbleText == nil)
        #expect(manager.testHarnessConversationHistoryCount == 0)
        #expect(manager.chatTranscriptStore.recentExchanges(limit: 10).count == transcriptCountBeforeNewChat)
        #expect(manager.assistantResponseGenerationCount == responseGenerationBeforeNewChat)
        #expect(manager.onDemandEditCoordinator.phase == editPhaseBeforeNewChat)
    }

    @Test func newChatPreservesGuideOwnedPointingWhileCancellingPendingAsk() async throws {
        let fixture = try makeIsolatedManagerFixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        await manager.guideSessionController.openGuide(
            slug: "lunara",
            requestedVersion: 2,
            branchKeyFromDeepLink: "macos:android",
            stepIndexFromDeepLink: nil
        )
        #expect(manager.guideSessionController.loadState == .guideIsOpen)
        let guideStepBeforeNewChat = manager.guideSessionController.currentStepIndex
        let guidePoint = CGPoint(x: 88, y: 144)
        manager.detectedElementScreenLocation = guidePoint
        manager.detectedElementDisplayFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        manager.detectedElementBubbleText = "guide-owned target"
        let askTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let pendingIdentifier = manager.testHarnessInstallPendingAskResponse(task: askTask, state: .thinking)

        manager.startANewChat()
        await askTask.value

        #expect(askTask.isCancelled)
        #expect(!manager.chatResponseIsPending)
        #expect(!manager.testHarnessAcceptsChatResponse(pendingIdentifier))
        #expect(manager.assistantState == .idle)
        #expect(manager.detectedElementScreenLocation == guidePoint)
        #expect(manager.detectedElementBubbleText == "guide-owned target")
        #expect(manager.guideSessionController.loadState == .guideIsOpen)
        #expect(manager.guideSessionController.currentStepIndex == guideStepBeforeNewChat)
    }

    @Test func stopWhileRealGuideIsOpenClearsAskSpinnerButPreservesGuidePointing() async throws {
        let fixture = try makeIsolatedManagerFixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager

        await manager.guideSessionController.openGuide(
            slug: "lunara",
            requestedVersion: 2,
            branchKeyFromDeepLink: "macos:android",
            stepIndexFromDeepLink: nil
        )
        #expect(manager.guideSessionController.loadState == .guideIsOpen)
        #expect(manager.guideSessionController.guideBeingFollowed?.appSlug == "lunara")
        let guideStepBeforeStop = manager.guideSessionController.currentStepIndex

        let guidePoint = CGPoint(x: 88, y: 144)
        manager.detectedElementScreenLocation = guidePoint
        manager.detectedElementDisplayFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        manager.detectedElementBubbleText = "guide-owned target"
        for askState in [CompanionAssistantState.capturing, .thinking] {
            let askTask = Task<Void, Never> {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
            manager.testHarnessInstallPendingAskResponse(task: askTask, state: askState)

            manager.stopCurrentAskResponse()
            await askTask.value

            #expect(!manager.chatResponseIsPending)
            #expect(manager.assistantState == .idle)
            #expect(manager.detectedElementScreenLocation == guidePoint)
            #expect(manager.detectedElementBubbleText == "guide-owned target")
            #expect(manager.guideSessionController.loadState == .guideIsOpen)
            #expect(manager.guideSessionController.guideBeingFollowed?.appSlug == "lunara")
            #expect(manager.guideSessionController.currentStepIndex == guideStepBeforeStop)
        }

        let guidePointingTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        manager.testHarnessInstallPendingAskResponse(
            task: guidePointingTask,
            withPointingTarget: true,
            state: .pointing
        )
        manager.detectedElementScreenLocation = guidePoint
        manager.detectedElementBubbleText = "guide-owned target"
        manager.stopCurrentAskResponse()
        await guidePointingTask.value

        #expect(manager.assistantState == .pointing)
        #expect(manager.detectedElementScreenLocation == guidePoint)
        #expect(manager.detectedElementBubbleText == "guide-owned target")
        #expect(manager.guideSessionController.loadState == .guideIsOpen)
    }

    private struct IsolatedManagerFixture {
        let manager: CompanionManager
        let defaults: UserDefaults
        let defaultsSuiteName: String
        let transcriptDirectory: URL

        func cleanUp() {
            try? FileManager.default.removeItem(at: transcriptDirectory)
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
    }

    private struct FakeCLIProcessSnapshot {
        let state: String
        let parentProcessIdentifier: Int32
        let processGroupIdentifier: Int32
        let startTime: String
        let command: String
    }

    private struct OwnedFakeCLIChild {
        let processIdentifier: Int32
        let processGroupIdentifier: Int32
        let startTime: String
        let command: String
    }

    private func fakeCLIProcessSnapshot(processIdentifier: Int32) -> FakeCLIProcessSnapshot? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = [
            "-p", String(processIdentifier),
            "-o", "state=,ppid=,pgid=,lstart=,command="
        ]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }
        let fields = output.split(whereSeparator: \.isWhitespace).map(String.init)
        // `lstart` is the fixed five-field form: weekday, month, day, time, year.
        guard fields.count >= 9,
              let parentProcessIdentifier = Int32(fields[1]),
              let processGroupIdentifier = Int32(fields[2]) else { return nil }
        return FakeCLIProcessSnapshot(
            state: fields[0],
            parentProcessIdentifier: parentProcessIdentifier,
            processGroupIdentifier: processGroupIdentifier,
            startTime: fields[3...7].joined(separator: " "),
            command: fields.dropFirst(8).joined(separator: " ")
        )
    }

    private func terminateOnlyOwnedFakeCLIChild(_ child: OwnedFakeCLIChild) {
        guard let snapshot = fakeCLIProcessSnapshot(processIdentifier: child.processIdentifier),
              snapshot.state.first != "Z",
              snapshot.processGroupIdentifier == child.processGroupIdentifier,
              snapshot.startTime == child.startTime,
              snapshot.command == child.command,
              snapshot.command.hasSuffix("sleep 60") else { return }

        _ = kill(child.processIdentifier, SIGTERM)
        for _ in 0..<25 {
            guard let current = fakeCLIProcessSnapshot(processIdentifier: child.processIdentifier),
                  current.state.first != "Z",
                  current.processGroupIdentifier == child.processGroupIdentifier,
                  current.startTime == child.startTime,
                  current.command == child.command else { return }
            usleep(10_000)
        }
        guard let remaining = fakeCLIProcessSnapshot(processIdentifier: child.processIdentifier),
              remaining.state.first != "Z",
              remaining.processGroupIdentifier == child.processGroupIdentifier,
              remaining.startTime == child.startTime,
              remaining.command == child.command,
              remaining.command.hasSuffix("sleep 60") else { return }
        _ = kill(child.processIdentifier, SIGKILL)
    }

    private func makeIsolatedManagerFixture() throws -> IsolatedManagerFixture {
        let suiteName = "com.publik.iris.codex-screen-help-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileReadUnknown)
        }
        let transcriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-codex-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubbedGuideURLProtocol.self]
        let guideService = GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: sessionConfiguration),
            userDefaults: defaults
        )
        let manager = CompanionManager(
            accountService: AccountService(inertForTesting: ()),
            publikAPIAccount: PublikAPIAccount(inertForTesting: defaults),
            chatTranscriptStore: ChatTranscriptStore(directoryURL: transcriptDirectory),
            spendLedger: AssistantSpendLedger(userDefaults: defaults),
            gitHubForkService: GitHubForkService(
                clientId: nil,
                urlSession: URLSession(configuration: .ephemeral)
            ),
            preferences: defaults,
            guideServiceForTesting: guideService,
            guideWatchLoopForTesting: WatchLoop(
                preferencesStore: defaults,
                drivesItsOwnTickTimer: false
            ),
            editPatchQueueForTesting: PatchQueue(
                baseDirectoryURL: transcriptDirectory.appendingPathComponent("patch-queue")
            ),
            observeGuideAppActivations: false
        )
        return IsolatedManagerFixture(
            manager: manager,
            defaults: defaults,
            defaultsSuiteName: suiteName,
            transcriptDirectory: transcriptDirectory
        )
    }

    private func makeFakeCLI(contents: String) throws -> (URL, String) {
        try makeFakeCLI(contentsForDirectory: { _ in contents })
    }

    private func makeFakeCLI(contentsForDirectory: (URL) -> String) throws -> (URL, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-codex-fake-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binaryURL = directory.appendingPathComponent("codex")
        let markerPath = directory.appendingPathComponent("started").path
        let script = "#!/bin/sh\nprintf started > '\(markerPath)'\n" + contentsForDirectory(directory)
        try Data(script.utf8).write(to: binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binaryURL.path)
        return (directory, binaryURL.path)
    }
}

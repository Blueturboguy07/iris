import Foundation
import Testing
#if canImport(Iris)
@testable import Iris
#else
@testable import IrisUsability
#endif

@MainActor
struct ChatTranscriptResetTests {
    private func withTemporaryTranscript(
        _ body: (URL) throws -> Void
    ) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-chat-reset-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try body(directoryURL)
    }

    @Test func newChatStaysBlankAfterReopeningTheStoreWithoutDeletingHistory() throws {
        try withTemporaryTranscript { directoryURL in
            let originalStore = ChatTranscriptStore(directoryURL: directoryURL)
            originalStore.recordExchange(question: "Earlier question", answer: "Earlier answer")
            originalStore.startANewConversation()

            #expect(originalStore.mostRecentExchangeInCurrentConversation == nil)
            #expect(originalStore.recentExchangesInCurrentConversation(limit: 10).isEmpty)
            #expect(originalStore.mostRecentExchange?.question == "Earlier question")

            let reopenedStore = ChatTranscriptStore(directoryURL: directoryURL)
            #expect(reopenedStore.mostRecentExchangeInCurrentConversation == nil)
            #expect(reopenedStore.recentExchangesInCurrentConversation(limit: 10).isEmpty)
            #expect(reopenedStore.recentExchanges(limit: 30).count == 1)
        }
    }

    @Test func newAnswersResumeOnlyTheNewConversationAcrossRelaunch() throws {
        try withTemporaryTranscript { directoryURL in
            let originalStore = ChatTranscriptStore(directoryURL: directoryURL)
            originalStore.recordExchange(question: "Archived question", answer: "Archived answer")
            originalStore.startANewConversation()
            originalStore.recordExchange(question: "New question", answer: "New answer")

            let reopenedStore = ChatTranscriptStore(directoryURL: directoryURL)
            #expect(reopenedStore.mostRecentExchangeInCurrentConversation?.question == "New question")
            #expect(reopenedStore.recentExchangesInCurrentConversation(limit: 10).map(\.question)
                == ["New question"])
            #expect(reopenedStore.recentExchanges(limit: 30).map(\.question)
                == ["Archived question", "New question"])
        }
    }

    @Test func severalResetsKeepOneBoundaryAndTheFullBoundedArchive() throws {
        try withTemporaryTranscript { directoryURL in
            let originalStore = ChatTranscriptStore(directoryURL: directoryURL)
            originalStore.recordExchange(question: "First question", answer: "First answer")
            originalStore.startANewConversation()
            originalStore.recordExchange(question: "Second question", answer: "Second answer")
            originalStore.startANewConversation()
            originalStore.startANewConversation()

            let fileContents = try String(contentsOf: originalStore.fileURL, encoding: .utf8)
            #expect(fileContents.components(separatedBy: "beginsNewConversation").count == 2)
            let reopenedStore = ChatTranscriptStore(directoryURL: directoryURL)
            #expect(reopenedStore.mostRecentExchangeInCurrentConversation == nil)
            #expect(reopenedStore.recentExchanges(limit: 30).count == 2)
        }
    }

    @Test func legacyTranscriptWithoutBoundaryStillResumesNormally() throws {
        try withTemporaryTranscript { directoryURL in
            let originalStore = ChatTranscriptStore(directoryURL: directoryURL)
            originalStore.recordExchange(question: "Legacy question", answer: "Legacy answer")
            let fileContents = try String(contentsOf: originalStore.fileURL, encoding: .utf8)
            #expect(!fileContents.contains("beginsNewConversation"))

            let reopenedStore = ChatTranscriptStore(directoryURL: directoryURL)
            #expect(reopenedStore.mostRecentExchangeInCurrentConversation?.question == "Legacy question")
            #expect(reopenedStore.recentExchangesInCurrentConversation(limit: 10).count == 1)
        }
    }

    @Test func markerIsMetadataNotAnEmptyExchange() throws {
        try withTemporaryTranscript { directoryURL in
            let store = ChatTranscriptStore(directoryURL: directoryURL)
            store.startANewConversation()
            #expect(ChatTranscriptStore.decodedExchange(
                fromLine: #"{"beginsNewConversation":true}"#
            ) == nil)
            #expect(ChatTranscriptStore.readExchanges(fromFileAtURL: store.fileURL).isEmpty)
            #expect(ChatTranscriptStore(directoryURL: directoryURL)
                .mostRecentExchangeInCurrentConversation == nil)
        }
    }

    @Test func pruningArchivedRowsPreservesTheActiveBoundary() throws {
        try withTemporaryTranscript { directoryURL in
            let store = ChatTranscriptStore(directoryURL: directoryURL)
            for exchangeNumber in 0..<ChatTranscriptStore.maximumKeptExchanges {
                store.recordExchange(question: "Archived \(exchangeNumber)", answer: "Fixture answer")
            }
            store.startANewConversation()
            store.recordExchange(question: "Current one", answer: "Fixture answer")
            store.recordExchange(question: "Current two", answer: "Fixture answer")

            let reopenedStore = ChatTranscriptStore(directoryURL: directoryURL)
            #expect(reopenedStore.recentExchanges(limit: 1_000).count == 300)
            #expect(reopenedStore.recentExchangesInCurrentConversation(limit: 10).map(\.question)
                == ["Current one", "Current two"])
        }
    }

    @Test func pruningTheWholeOldConversationDoesNotHideNewAnswers() throws {
        try withTemporaryTranscript { directoryURL in
            let store = ChatTranscriptStore(directoryURL: directoryURL)
            store.recordExchange(question: "Archived", answer: "Fixture answer")
            store.startANewConversation()
            for exchangeNumber in 0...ChatTranscriptStore.maximumKeptExchanges {
                store.recordExchange(question: "Current \(exchangeNumber)", answer: "Fixture answer")
            }

            let reopenedStore = ChatTranscriptStore(directoryURL: directoryURL)
            #expect(reopenedStore.recentExchangesInCurrentConversation(limit: 1_000).count == 300)
            #expect(reopenedStore.recentExchangesInCurrentConversation(limit: 1_000).first?.question
                == "Current 1")
            #expect(reopenedStore.mostRecentExchangeInCurrentConversation?.question == "Current 300")
        }
    }

    @Test func corruptLinesDoNotMoveTheBoundaryIntoTheWrongConversation() throws {
        try withTemporaryTranscript { directoryURL in
            let fileURL = directoryURL.appendingPathComponent(ChatTranscriptStore.transcriptFileName)
            let archivedLine = try #require(ChatTranscriptStore.encodedLine(for:
                ChatTranscriptExchange(question: "Archived", answer: "Fixture answer")))
            let currentLine = try #require(ChatTranscriptStore.encodedLine(for:
                ChatTranscriptExchange(question: "Current", answer: "Fixture answer")))
            let fixture = [
                archivedLine, "not-json", #"{ "beginsNewConversation" : true }"#,
                "also-not-json", currentLine
            ].joined(separator: "\n")
            try fixture.write(to: fileURL, atomically: true, encoding: .utf8)

            let reopenedStore = ChatTranscriptStore(directoryURL: directoryURL)
            #expect(reopenedStore.recentExchanges(limit: 30).count == 2)
            #expect(reopenedStore.recentExchangesInCurrentConversation(limit: 10).map(\.question)
                == ["Current"])
        }
    }

    @Test func failedResetPersistenceStillClearsThisSessionAndReportsDegradedStorage() throws {
        try withTemporaryTranscript { directoryURL in
            let store = ChatTranscriptStore(directoryURL: directoryURL)
            store.recordExchange(question: "Archived", answer: "Fixture answer")
            try FileManager.default.removeItem(at: store.fileURL)
            try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
            store.startANewConversation()

            #expect(!store.theTranscriptIsBeingSavedToDisk)
            #expect(store.mostRecentExchangeInCurrentConversation == nil)
            #expect(store.mostRecentExchange?.question == "Archived")
        }
    }

    @Test func zeroAndNegativeLimitsNeverReturnCurrentHistory() throws {
        try withTemporaryTranscript { directoryURL in
            let store = ChatTranscriptStore(directoryURL: directoryURL)
            store.recordExchange(question: "Question", answer: "Answer")
            #expect(store.recentExchangesInCurrentConversation(limit: 0).isEmpty)
            #expect(store.recentExchangesInCurrentConversation(limit: -1).isEmpty)
        }
    }

    @Test func clearingHistoryRemovesArchiveAndBoundaryAcrossStoreRecreation() throws {
        try withTemporaryTranscript { directoryURL in
            let originalStore = ChatTranscriptStore(directoryURL: directoryURL)
            originalStore.recordExchange(question: "Archived question", answer: "Archived answer")
            originalStore.startANewConversation()
            originalStore.recordExchange(question: "Current question", answer: "Current answer")

            #expect(originalStore.clearAllHistory() == .persisted)
            #expect(originalStore.mostRecentExchange == nil)
            #expect(originalStore.mostRecentExchangeInCurrentConversation == nil)
            #expect(originalStore.recentExchanges(limit: 30).isEmpty)

            let fileContents = try String(contentsOf: originalStore.fileURL, encoding: .utf8)
            #expect(fileContents.isEmpty)

            let reopenedStore = ChatTranscriptStore(directoryURL: directoryURL)
            #expect(reopenedStore.mostRecentExchange == nil)
            #expect(reopenedStore.recentExchangesInCurrentConversation(limit: 10).isEmpty)
        }
    }

    @Test func failedHistoryClearIsInMemoryOnlyAndLeavesTheFailureVisible() throws {
        try withTemporaryTranscript { directoryURL in
            let store = ChatTranscriptStore(directoryURL: directoryURL)
            store.recordExchange(question: "Saved question", answer: "Saved answer")
            try FileManager.default.removeItem(at: store.fileURL)
            try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)

            #expect(store.clearAllHistory() == .inMemoryOnly)
            #expect(store.mostRecentExchange == nil)
            #expect(store.recentExchanges(limit: 30).isEmpty)
            #expect(!store.theTranscriptIsBeingSavedToDisk)

            let reopenedStore = ChatTranscriptStore(directoryURL: directoryURL)
            #expect(reopenedStore.mostRecentExchange == nil)
        }
    }

    #if canImport(Iris)
    @Test func theBarsActualRestorePathHonorsNewChatAcrossStoreRecreation() throws {
        try withTemporaryTranscript { directoryURL in
            let originalStore = ChatTranscriptStore(directoryURL: directoryURL)
            originalStore.recordExchange(question: "Archived question", answer: "Archived answer")
            originalStore.startANewConversation()

            let reopenedStore = ChatTranscriptStore(directoryURL: directoryURL)
            let restoredExchange = OverlayEyeInputBarPanelManager
                .exchangeShowingTheLastThingThatWasSaid(fromTranscriptStore: reopenedStore)
            #expect(restoredExchange.phase == .composingTheFirstQuestion)
            #expect(restoredExchange.whatIrisSaidBack == nil)
            #expect(!restoredExchange.wasRestoredFromAnEarlierSitting)
        }
    }
    #endif
}

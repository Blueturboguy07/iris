import Foundation
import Testing
@testable import Iris

@Suite("Screen-help conversation boundary")
@MainActor
struct ChatTranscriptConversationBoundaryTests {
    private func withTemporaryTranscript(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-chat-boundary-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func newChatReopensBlankAfterRestartWithoutDeletingArchivedAnswer() throws {
        try withTemporaryTranscript { directory in
            let original = ChatTranscriptStore(directoryURL: directory)
            original.recordExchange(question: "Earlier question", answer: "Earlier answer")
            original.startANewConversation()

            #expect(original.mostRecentExchangeInCurrentConversation == nil)
            #expect(original.mostRecentExchange?.question == "Earlier question")
            let restarted = ChatTranscriptStore(directoryURL: directory)
            #expect(restarted.recentExchanges(limit: 10).map(\.question) == ["Earlier question"])
            #expect(restarted.recentExchangesInCurrentConversation(limit: 10).isEmpty)
            #expect(restarted.mostRecentExchangeInCurrentConversation == nil)
        }
    }

    @Test func newAnswerAfterBoundaryRestartsOnlyItsConversation() throws {
        try withTemporaryTranscript { directory in
            let original = ChatTranscriptStore(directoryURL: directory)
            original.recordExchange(question: "Archived", answer: "Old answer")
            original.startANewConversation()
            original.recordExchange(question: "Current", answer: "New answer")

            let restarted = ChatTranscriptStore(directoryURL: directory)
            #expect(restarted.recentExchanges(limit: 10).map(\.question)
                == ["Archived", "Current"])
            #expect(restarted.recentExchangesInCurrentConversation(limit: 10).map(\.question)
                == ["Current"])
            #expect(restarted.mostRecentExchangeInCurrentConversation?.answer == "New answer")
        }
    }

    @Test func repeatedNewChatWritesOneMetadataMarkerAndKeepsArchive() throws {
        try withTemporaryTranscript { directory in
            let original = ChatTranscriptStore(directoryURL: directory)
            original.recordExchange(question: "First", answer: "First answer")
            original.startANewConversation()
            original.recordExchange(question: "Second", answer: "Second answer")
            original.startANewConversation()
            original.startANewConversation()

            let fileContents = try String(contentsOf: original.fileURL, encoding: .utf8)
            #expect(fileContents.components(separatedBy: "beginsNewConversation").count == 2)
            #expect(ChatTranscriptStore.decodedExchange(
                fromLine: #"{"beginsNewConversation":true}"#
            ) == nil)
            let restarted = ChatTranscriptStore(directoryURL: directory)
            #expect(restarted.recentExchanges(limit: 10).count == 2)
            #expect(restarted.mostRecentExchangeInCurrentConversation == nil)
        }
    }

    @Test func legacyTranscriptWithoutBoundaryStillResumes() throws {
        try withTemporaryTranscript { directory in
            let original = ChatTranscriptStore(directoryURL: directory)
            original.recordExchange(question: "Legacy question", answer: "Legacy answer")
            let fileContents = try String(contentsOf: original.fileURL, encoding: .utf8)
            #expect(!fileContents.contains("beginsNewConversation"))

            let restarted = ChatTranscriptStore(directoryURL: directory)
            #expect(restarted.mostRecentExchangeInCurrentConversation?.question == "Legacy question")
            #expect(restarted.recentExchangesInCurrentConversation(limit: 10).count == 1)
        }
    }

    @Test func pruningArchivedRowsDoesNotMoveNewConversationIntoTheArchive() throws {
        try withTemporaryTranscript { directory in
            let store = ChatTranscriptStore(directoryURL: directory)
            for number in 0..<ChatTranscriptStore.maximumKeptExchanges {
                store.recordExchange(question: "Archived \(number)", answer: "Fixture answer")
            }
            store.startANewConversation()
            store.recordExchange(question: "Current one", answer: "Fixture answer")
            store.recordExchange(question: "Current two", answer: "Fixture answer")

            let restarted = ChatTranscriptStore(directoryURL: directory)
            #expect(restarted.recentExchanges(limit: 1_000).count
                == ChatTranscriptStore.maximumKeptExchanges)
            #expect(restarted.recentExchangesInCurrentConversation(limit: 10).map(\.question)
                == ["Current one", "Current two"])
        }
    }
}

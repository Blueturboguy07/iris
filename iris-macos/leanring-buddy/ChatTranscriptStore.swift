//
//  ChatTranscriptStore.swift
//  leanring-buddy
//
//  PRIVACY, PLAINLY: THIS IS THE FIRST THING IN IRIS THAT WRITES THE READER'S
//  CHAT TO DISK. Every completed exchange in the bar under the eye — the words
//  the reader typed, the words Iris said back, and when — is saved as one line
//  of JSON in a file on their own Mac
//  (`~/Library/Application Support/Iris/chat-transcript.jsonl`). Before this
//  file existed the conversation lived only in memory and was gone at quit.
//
//  What is NOT saved, and must never be added here:
//    - screenshots, or anything derived from them. Chat sends a picture of the
//      reader's screens to the model; not one pixel of it reaches this file.
//    - credentials of any kind. No API key, no OAuth token, no access token.
//    - the machine facts, live app status, and guide context that `sendUserMessage`
//      staples onto the prompt. The store keeps the reader's OWN sentence, not
//      the assembled prompt.
//    - anything about who the reader is, and any network destination.
//  Two strings and a date. If a future change wants a third thing in here, that
//  is a privacy decision and not a storage one.
//  A non-text reset marker separates the current conversation from the archive.
//  It stores no additional reader content, identity, or machine information.
//
//  Nothing here ever leaves the machine. The transcript is read back by exactly
//  two callers: `CompanionManager`, to warm the model's conversation window at
//  launch, and the bar under the eye, to reopen showing the last exchange
//  instead of pretending nothing was ever asked.
//
//  DURABILITY IS NEVER ALLOWED TO BREAK A CHAT TURN. Following
//  `OnDemandEditRunLog`, every filesystem miss is swallowed: an unreadable file
//  is an empty transcript, an unwritable file means the store degrades to an
//  in-memory transcript that still serves this session, and neither is ever an
//  error a chat turn can see. The reader asking Iris a question must not be
//  able to fail because a folder is read-only.
//

import Foundation
#if canImport(IrisEnvironment)
import IrisEnvironment
#endif

/// ONE completed question-and-answer between the reader and Iris.
///
/// Decoding is tolerant on purpose (`decodeIfPresent` with a default for every
/// field), for the same reason `OnDemandEditMemoryRecord` is: a line written by
/// an older or newer Iris must still read back as a usable exchange, because a
/// transcript that fails to parse is a transcript that silently stops working.
struct ChatTranscriptExchange: Codable, Equatable, Sendable {

    /// What the reader typed (or the suggestion chip they tapped), exactly as
    /// they sent it — never the prompt Iris assembled around it.
    var question: String

    /// What Iris said back, with the `[POINT:…]` tag already stripped by the
    /// caller, so the transcript holds the sentence the reader actually read.
    var answer: String

    /// When the reader asked. Kept so a transcript can be read in order and so
    /// a human opening the file can tell how old the conversation is.
    var askedAt: Date

    init(question: String, answer: String, askedAt: Date = Date()) {
        self.question = question
        self.answer = answer
        self.askedAt = askedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        answer = try container.decodeIfPresent(String.self, forKey: .answer) ?? ""
        askedAt = try container.decodeIfPresent(Date.self, forKey: .askedAt)
            ?? Date(timeIntervalSince1970: 0)
    }

    /// A copy whose two free-text fields are short enough that one line stays a
    /// sensible size. One pathological exchange (a pasted stack trace as the
    /// question, a very long answer) must not be able to turn the transcript
    /// into a file that is slow to rewrite on every chat turn.
    func truncatedForStorage() -> ChatTranscriptExchange {
        ChatTranscriptExchange(
            question: Self.truncated(
                question, toCharacterCount: ChatTranscriptStore.maximumStoredQuestionCharacters),
            answer: Self.truncated(
                answer, toCharacterCount: ChatTranscriptStore.maximumStoredAnswerCharacters),
            askedAt: askedAt
        )
    }

    /// Cuts `text` to `characterCount`, marking the cut with an ellipsis so a
    /// later reader can tell a truncated sentence from a short one.
    static func truncated(_ text: String, toCharacterCount characterCount: Int) -> String {
        guard characterCount > 0 else { return "" }
        guard text.count > characterCount else { return text }
        return String(text.prefix(max(characterCount - 1, 1))) + "…"
    }
}

/// The result of clearing the saved transcript.
///
/// A clear always takes effect in the current process. When the atomic rewrite
/// cannot reach disk, the old file may still be present after a relaunch, so
/// that degraded result must stay visible to the caller rather than being
/// mistaken for a durable deletion.
enum ChatTranscriptClearOutcome: Equatable, Sendable {
    case persisted
    case inMemoryOnly
}

/// The reader's chat with Iris, kept on disk so it survives both dismissing the
/// bar and quitting the app.
///
/// WHY THIS EXISTS. The bar under the eye is destroyed on every dismissal and
/// rebuilt on every open, and the model's conversation window was a private
/// in-memory array that died with the process. That combination produced the
/// reported bug — "when I click off Iris it just gets rid of my chat and opens
/// a brand new one" — and, worse, an asymmetry: the model still remembered the
/// exchange the reader could no longer see. One durable transcript makes both
/// sides start from the same place.
///
/// WHY IT IS STILL NOT A CHAT HISTORY BROWSER. The bar hangs off a 64pt eye and
/// floats over whatever the reader is really doing. This store keeps a few
/// hundred exchanges so the model's window can be warmed and so the file is
/// worth having, but the bar only reopens on the current conversation's last exchange. There
/// is deliberately no scrollback, no search, and no way to page backwards.
@MainActor
final class ChatTranscriptStore {

    // Nonisolated so an init default argument (evaluated in a nonisolated
    // context under Swift 6) can read it — all of these are immutable
    // constants.

    /// The app-specific directory below `~/Library/Application Support`.
    /// `IrisTestEnvironment` keeps the normal fallback and test app isolated.
    nonisolated static let transcriptDirectoryURL: URL =
        IrisTestEnvironment.applicationSupportDirectory

    nonisolated static let transcriptFileName = "chat-transcript.jsonl"

    /// How many exchanges the transcript keeps. Oldest are pruned first. A few
    /// hundred is far more than the model window ever asks for; it exists so the
    /// file stays a bounded, cheap read rather than growing for the life of the
    /// install.
    nonisolated static let maximumKeptExchanges = 300

    /// Per-field character caps, so `maximumKeptExchanges` also bounds the file
    /// size rather than only the line count.
    nonisolated static let maximumStoredQuestionCharacters = 2_000
    nonisolated static let maximumStoredAnswerCharacters = 4_000

    /// Where the transcript lives, so a caller can say where it is.
    let fileURL: URL

    /// The whole transcript, oldest first. Held in memory as well as on disk so
    /// that a store which cannot write still answers every question correctly
    /// for the rest of this session.
    private var exchangesOldestFirst: [ChatTranscriptExchange] = []

    /// A reset divides the archive from the conversation the bar and model
    /// may resume. The marker is stored in the same atomic file as the text,
    /// so a quit between two separate writes cannot bring an old chat back.
    private var currentConversationStartIndex: Int?

    /// False once a write has failed. The store keeps working — it just stops
    /// claiming the conversation will survive a quit. The composer surfaces
    /// this degraded state rather than hiding it behind an invisible `try?`.
    private(set) var theTranscriptIsBeingSavedToDisk: Bool = true

    /// Reads whatever is already on disk. Never fails: an unreadable or absent
    /// file simply means the transcript starts empty.
    init(directoryURL: URL = ChatTranscriptStore.transcriptDirectoryURL) {
        fileURL = directoryURL.appendingPathComponent(Self.transcriptFileName)
        try? FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
        let savedTranscript = Self.readTranscript(fromFileAtURL: fileURL)
        exchangesOldestFirst = savedTranscript.exchanges
        currentConversationStartIndex = savedTranscript.currentConversationStartIndex
    }

    // MARK: - Reading

    /// The last archived exchange, including conversations ended by New chat.
    /// Used to decide whether the history browser has anything to show.
    var mostRecentExchange: ChatTranscriptExchange? {
        exchangesOldestFirst.last
    }

    /// Reopening the bar resumes only the conversation after the last reset.
    /// Archived exchanges remain available through `recentExchanges`.
    var mostRecentExchangeInCurrentConversation: ChatTranscriptExchange? {
        recentExchangesInCurrentConversation(limit: 1).last
    }

    func recentExchangesInCurrentConversation(limit: Int) -> [ChatTranscriptExchange] {
        guard limit > 0 else { return [] }
        return Array(exchangesOldestFirst
            .dropFirst(currentConversationStartIndex ?? 0)
            .suffix(limit))
    }

    /// The newest `limit` exchanges, oldest first — the order the model's
    /// conversation history wants them in.
    func recentExchanges(limit: Int) -> [ChatTranscriptExchange] {
        guard limit > 0 else { return [] }
        return Array(exchangesOldestFirst.suffix(limit))
    }

    // MARK: - Writing

    /// Starts a blank conversation without deleting the reader's archive.
    /// This is durable even if no further question is asked before quitting.
    func startANewConversation() {
        currentConversationStartIndex = exchangesOldestFirst.count
        writeWholeTranscriptToDisk()
    }

    /// Clears every saved exchange and the current-conversation boundary.
    ///
    /// The memory is cleared before the disk write so the live bar and model
    /// cannot keep showing a conversation the reader asked Iris to remove.
    /// `writeWholeTranscriptToDisk` is atomic, and its result is returned so a
    /// failed write can be disclosed without restoring or deleting anything
    /// outside this transcript file.
    @discardableResult
    func clearAllHistory() -> ChatTranscriptClearOutcome {
        exchangesOldestFirst = []
        currentConversationStartIndex = nil
        writeWholeTranscriptToDisk()
        return theTranscriptIsBeingSavedToDisk ? .persisted : .inMemoryOnly
    }

    /// Records one completed exchange and prunes the oldest away.
    ///
    /// Best-effort in the same sense as `OnDemandEditRunLog`: if the write
    /// fails, the exchange is still in memory and this session behaves exactly
    /// as before, but `theTranscriptIsBeingSavedToDisk` goes false. Saving a
    /// chat must never be able to fail a chat.
    func recordExchange(question: String, answer: String, askedAt: Date = Date()) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // An exchange with nothing on one side of it is not a conversation the
        // reader could resume, and storing it would reopen the bar on a blank.
        guard !trimmedQuestion.isEmpty, !trimmedAnswer.isEmpty else { return }

        let exchange = ChatTranscriptExchange(
            question: trimmedQuestion,
            answer: trimmedAnswer,
            askedAt: askedAt
        ).truncatedForStorage()

        exchangesOldestFirst.append(exchange)
        if exchangesOldestFirst.count > Self.maximumKeptExchanges {
            let numberOfPrunedExchanges = exchangesOldestFirst.count - Self.maximumKeptExchanges
            if let currentConversationStartIndex {
                self.currentConversationStartIndex = max(
                    0, currentConversationStartIndex - numberOfPrunedExchanges
                )
            }
            exchangesOldestFirst = Array(exchangesOldestFirst.suffix(Self.maximumKeptExchanges))
        }
        writeWholeTranscriptToDisk()
    }

    /// Rewrites the whole file rather than appending and trimming separately.
    ///
    /// The transcript is bounded and small (≤ 300 short lines), so a full
    /// atomic rewrite is both cheap and simpler than an append plus a separate
    /// prune: there is exactly one code path, and it always leaves the file in
    /// a valid state — never a half-written line the next launch has to guess
    /// about.
    private func writeWholeTranscriptToDisk() {
        var encodedLines = exchangesOldestFirst.compactMap(Self.encodedLine(for:))
        if let currentConversationStartIndex {
            encodedLines.insert(
                Self.conversationBoundaryLine,
                at: min(currentConversationStartIndex, encodedLines.count)
            )
        }
        let fileBody = encodedLines.isEmpty ? "" : encodedLines.joined(separator: "\n") + "\n"
        do {
            try fileBody.write(to: fileURL, atomically: true, encoding: .utf8)
            theTranscriptIsBeingSavedToDisk = true
        } catch {
            // Deliberately silent to the reader: an unwritable folder is not
            // something to interrupt a conversation about. The flag is here so
            // anything that wants to know can ask.
            theTranscriptIsBeingSavedToDisk = false
        }
    }

    // MARK: - The file format

    /// One exchange as one line of JSON, or nil if it cannot be encoded. Keys
    /// are sorted so the same exchange always encodes to the same bytes, which
    /// keeps the rewrite above diff-friendly and tests deterministic.
    nonisolated static func encodedLine(for exchange: ChatTranscriptExchange) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encodedData = try? encoder.encode(exchange),
              let encodedLine = String(data: encodedData, encoding: .utf8) else {
            return nil
        }
        // JSON already escapes real newlines; this is belt-and-braces so the
        // "one exchange per line" invariant cannot be broken by any input.
        return encodedLine.replacingOccurrences(of: "\n", with: " ")
    }

    nonisolated static func decodedExchange(fromLine line: String) -> ChatTranscriptExchange? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let lineData = line.data(using: .utf8) else { return nil }
        guard !lineBeginsANewConversation(line) else { return nil }
        return try? decoder.decode(ChatTranscriptExchange.self, from: lineData)
    }

    nonisolated private static let conversationBoundaryLine = #"{"beginsNewConversation":true}"#

    nonisolated private struct ConversationBoundary: Decodable {
        let beginsNewConversation: Bool
    }

    nonisolated private static func lineBeginsANewConversation(_ line: String) -> Bool {
        guard let lineData = line.data(using: .utf8),
              let boundary = try? JSONDecoder().decode(ConversationBoundary.self, from: lineData)
        else { return false }
        return boundary.beginsNewConversation
    }

    /// Every exchange currently in the file, oldest first, capped at
    /// `maximumKeptExchanges`. A missing or unreadable file is an empty
    /// transcript, never an error. An undecodable line is skipped rather than
    /// fatal — one corrupt line must not blind Iris to the rest of the chat.
    nonisolated static func readExchanges(fromFileAtURL fileURL: URL) -> [ChatTranscriptExchange] {
        readTranscript(fromFileAtURL: fileURL).exchanges
    }

    nonisolated private static func readTranscript(
        fromFileAtURL fileURL: URL
    ) -> (exchanges: [ChatTranscriptExchange], currentConversationStartIndex: Int?) {
        guard let fileContents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return ([], nil)
        }
        var exchanges: [ChatTranscriptExchange] = []
        var currentConversationStartIndex: Int?
        for line in fileContents.components(separatedBy: "\n") {
            if lineBeginsANewConversation(line) {
                currentConversationStartIndex = exchanges.count
            } else if let exchange = decodedExchange(fromLine: line) {
                exchanges.append(exchange)
            }
        }
        let numberOfPrunedExchanges = max(0, exchanges.count - maximumKeptExchanges)
        return (
            Array(exchanges.suffix(maximumKeptExchanges)),
            currentConversationStartIndex.map { max(0, $0 - numberOfPrunedExchanges) }
        )
    }
}

//
//  AppLink.swift
//  leanring-buddy
//
//  The wire format Iris uses to ask a publik catalog app what it is doing.
//
//  Newline-delimited JSON-RPC 2.0 — deliberately the same framing MCP's stdio
//  binding uses, because the 2026-07-28 spec says custom transports over a
//  reliable bidirectional byte stream should reuse it. The design and the
//  reasoning live in `docs/iris-app-integration-plan.md`; the app half of this
//  is `packages/app-link` in the publik repo, and the first app to speak it is
//  cue.
//
//  Everything in this file is pure. The socket is in `AppLinkConnection.swift`
//  and the discovery directory is in `AppLinkDiscovery.swift`, so the parts
//  most worth testing can be tested without either.
//

import Foundation

// MARK: - Protocol constants

nonisolated enum AppLinkProtocol {
    /// Bumped only for a breaking change. Both ends report theirs, and a client
    /// meeting a major it does not know should degrade rather than guess.
    static let version = "1"

    /// A single frame may not exceed this. Without a cap, a peer that sends
    /// bytes and never a newline is an unbounded allocation here — the cheapest
    /// denial of service there is against a line-framed protocol.
    static let maximumFrameBytes = 1 * 1024 * 1024

    /// Locally everything is instant. This is a stuck-app timeout, not a
    /// network one.
    static let requestTimeoutSeconds: Double = 5

    /// The one call that legitimately waits on a human reading a sheet.
    static let connectTimeoutSeconds: Double = 120
}

/// The implementation-defined half of the error space. -32000 to -32099 is
/// reserved for exactly this by JSON-RPC 2.0.
nonisolated enum AppLinkErrorCode: Int, Sendable {
    case parse = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParameters = -32602
    case internalError = -32603
    case notConnected = -32000
    case scopeDenied = -32001
    case consentDenied = -32002
    case rateLimited = -32003
}

nonisolated enum AppLinkError: Error, Equatable, Sendable {
    case socketCouldNotBeOpened(reason: String)
    case appIsNotRunning(appId: String)
    case connectionClosed
    case timedOut(method: String)
    case frameTooLarge
    case responseCouldNotBeDecoded(reason: String)
    /// The app answered, and said no. `code` is one of `AppLinkErrorCode`.
    case remote(code: Int, message: String)
    /// The instance file pointed at a process that is no longer the one that
    /// wrote it — a recycled PID, most likely.
    case instanceMismatch(expected: String, actual: String)

    var userFacingMessage: String {
        switch self {
        case .socketCouldNotBeOpened(let reason):
            return "Iris could not reach the app. \(reason)"
        case .appIsNotRunning(let appId):
            return "\(appId) is not running."
        case .connectionClosed:
            return "The app closed the connection."
        case .timedOut(let method):
            return "The app did not answer \(method) in time."
        case .frameTooLarge:
            return "The app sent more than Iris is willing to read in one message."
        case .responseCouldNotBeDecoded(let reason):
            return "Iris could not read the app's answer. \(reason)"
        case .remote(let code, let message):
            if code == AppLinkErrorCode.scopeDenied.rawValue {
                return "The app has not been given permission to answer this. \(message)"
            }
            return message
        case .instanceMismatch:
            return "Iris reached a different process than the one it was looking for."
        }
    }
}

// MARK: - Framing

/// Incremental newline-delimited JSON decoder.
///
/// Returns errors rather than throwing on a bad frame because the caller has to
/// decide what one means: a client may want to close the connection, and a
/// caller draining a buffer may prefer to keep what it already parsed.
nonisolated struct AppLinkFrameDecoder {
    enum DecodeFailure: Error, Equatable, Sendable {
        case frameTooLarge
        case notJSON
    }

    private var buffer = Data()
    private let maximumFrameBytes: Int

    init(maximumFrameBytes: Int = AppLinkProtocol.maximumFrameBytes) {
        self.maximumFrameBytes = maximumFrameBytes
    }

    /// Feed bytes, get whole messages back.
    mutating func push(_ chunk: Data) throws -> [[String: Any]] {
        buffer.append(chunk)

        var messages: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if line.count > maximumFrameBytes { throw DecodeFailure.frameTooLarge }
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }

            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let dictionary = object as? [String: Any]
            else {
                throw DecodeFailure.notJSON
            }
            messages.append(dictionary)
        }

        // The tail is a partial frame, and it still counts against the cap, or
        // a peer could stream forever as long as it never sent a newline.
        if buffer.count > maximumFrameBytes { throw DecodeFailure.frameTooLarge }
        return messages
    }
}

nonisolated enum AppLinkFrameEncoder {
    /// Serialize one request as a frame, newline included.
    static func encode(id: Int, method: String, parameters: [String: Any]) throws -> Data {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": parameters,
        ]
        // `.withoutEscapingSlashes` only; sorted keys would be wasted work and
        // fragmentsAllowed would let a non-object through.
        var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}

// MARK: - What an app tells us about itself

/// The answer to `connect`.
nonisolated struct AppLinkSession: Equatable, Sendable {
    let protocolVersion: String
    let instanceId: String
    let appId: String
    let appSlug: String?
    let appName: String
    let appVersion: String?
    /// Scopes the user has agreed to. Empty is normal and means "asked, told no"
    /// — or "did not ask".
    let grantedScopes: [String]
    let deniedScopes: [String]

    var canRead: Bool { grantedScopes.contains("read") }
    var canAct: Bool { grantedScopes.contains("action") }
}

/// One line out of an app's ring buffer. Same shape as
/// `docs/publik-sdk-convention.md`, because it is the same event.
nonisolated struct AppLinkEvent: Equatable, Sendable, Identifiable {
    let sequence: Int
    let timestamp: String
    let level: String
    let message: String
    /// The top stack frame or throwing function. The single most useful
    /// optional field, because it separates two unrelated failures that happen
    /// to share wording.
    let frame: String?
    let code: String?
    let event: String?

    var id: Int { sequence }

    var isFailure: Bool { level == "error" || level == "fatal" }

    init?(json: [String: Any]) {
        guard let message = json["msg"] as? String else { return nil }
        self.sequence = json["seq"] as? Int ?? 0
        self.timestamp = json["ts"] as? String ?? ""
        self.level = json["level"] as? String ?? "info"
        self.message = message
        self.frame = json["frame"] as? String
        self.code = json["code"] as? String
        self.event = json["event"] as? String
    }

    init(sequence: Int, timestamp: String, level: String, message: String, frame: String? = nil, code: String? = nil, event: String? = nil) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.frame = frame
        self.code = code
        self.event = event
    }
}

/// Everything an app will say about a failure, in one bundle.
///
/// `isTrustworthy` is the field that matters downstream: a diagnostics bundle
/// from a peer whose code signature could not be verified is fine to show the
/// user and must never be submitted anywhere, because otherwise anything
/// running as this user could write the breaks tally.
nonisolated struct AppLinkDiagnostics: Equatable, Sendable {
    let appId: String
    let appSlug: String?
    let appVersion: String?
    let generatedAt: String
    let osVersion: String?
    let runtime: String?
    let lastError: AppLinkEvent?
    let events: [AppLinkEvent]
    let stateSummary: String?
    let isTrustworthy: Bool

    init(
        appId: String,
        appSlug: String?,
        appVersion: String?,
        generatedAt: String,
        osVersion: String?,
        runtime: String?,
        lastError: AppLinkEvent?,
        events: [AppLinkEvent],
        stateSummary: String?,
        isTrustworthy: Bool
    ) {
        self.appId = appId
        self.appSlug = appSlug
        self.appVersion = appVersion
        self.generatedAt = generatedAt
        self.osVersion = osVersion
        self.runtime = runtime
        self.lastError = lastError
        self.events = events
        self.stateSummary = stateSummary
        self.isTrustworthy = isTrustworthy
    }

    /// Parse `capture_diagnostics`.
    init?(json: [String: Any], appId: String, verification: AppLinkPeerVerification) {
        let app = json["app"] as? [String: Any]
        self.appId = app?["id"] as? String ?? appId
        self.appSlug = app?["slug"] as? String
        self.appVersion = app?["version"] as? String
        self.generatedAt = json["generatedAt"] as? String ?? ""

        let environment = json["environment"] as? [String: Any]
        self.osVersion = environment?["osVersion"] as? String
        self.runtime = environment?["runtime"] as? String

        self.lastError = (json["lastError"] as? [String: Any]).flatMap(AppLinkEvent.init(json:))
        self.events = (json["events"] as? [[String: Any]] ?? []).compactMap(AppLinkEvent.init(json:))

        if
            let state = json["state"],
            let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        {
            self.stateSummary = text
        } else {
            self.stateSummary = nil
        }

        self.isTrustworthy = verification == .codeSignature
    }
}

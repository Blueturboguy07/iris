//
//  AppLinkConnection.swift
//  leanring-buddy
//
//  One connection to one running app: a Unix domain socket, newline-delimited
//  JSON-RPC over it, and a check on who is actually at the other end.
//
//  This uses POSIX sockets rather than Network.framework for one reason:
//  `NWConnection` does not hand back the file descriptor, and the descriptor is
//  the only way to reach `LOCAL_PEERTOKEN`. Without that there is no peer
//  identity at all, and the whole point of Iris being the Swift side of this is
//  that it *can* verify who it is talking to.
//

import Foundation
import Security

// MARK: - Peer identity

/// What could actually be proven about the process on the other end.
///
/// Ordered by strength, and used rather than ignored: a diagnostics bundle from
/// an unverified peer is fine to show the user and is never submitted anywhere,
/// because otherwise anything running under this account could impersonate an
/// app and write the public breaks tally.
nonisolated enum AppLinkPeerVerification: String, Equatable, Sendable {
    /// We know nothing beyond what the socket path implied.
    case none
    /// It knew the per-session token. Any process running as this user can read
    /// that token, so this is a consistency check, not a security boundary.
    case token
    /// Its running code satisfies a designated requirement naming our team.
    case codeSignature
}

nonisolated enum AppLinkPeerVerifier {
    /// The Developer ID team every publik binary is signed with.
    static let expectedTeamIdentifier = "R5R3ZS54LV"

    /// `anchor apple generic` pins the chain to Apple's Developer ID root, and
    /// the leaf OU is the team. Together they mean "signed by us, through
    /// Apple" — a self-signed certificate claiming the same OU does not match.
    static func designatedRequirement(teamIdentifier: String = expectedTeamIdentifier) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// `SOL_LOCAL` and `LOCAL_PEERTOKEN` from `<sys/un.h>`, which the Swift
    /// overlay does not surface.
    private static let solLocal: Int32 = 0
    private static let localPeerToken: Int32 = 0x006

    /// Verify the process at the other end of `descriptor`.
    ///
    /// The audit token — not the PID. A PID can be recycled between the moment
    /// it is read and the moment it is used, and the race is a real one: the
    /// classic exploit is to exit and have an attacker-controlled process land
    /// on the same number. The audit token identifies the peer unambiguously,
    /// which is why `SecCodeCopyGuestWithAttributes` takes one.
    static func verify(
        descriptor: Int32,
        teamIdentifier: String = expectedTeamIdentifier
    ) -> AppLinkPeerVerification {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let read = withUnsafeMutablePointer(to: &token) { pointer -> Int32 in
            getsockopt(descriptor, solLocal, localPeerToken, pointer, &length)
        }
        guard read == 0, length == socklen_t(MemoryLayout<audit_token_t>.size) else { return .none }

        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attributes: [String: Any] = [kSecGuestAttributeAudit as String: tokenData]

        var guest: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guest) == errSecSuccess,
            let peer = guest
        else {
            return .none
        }

        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(designatedRequirement(teamIdentifier: teamIdentifier) as CFString, [], &requirement) == errSecSuccess,
            let designated = requirement
        else {
            return .none
        }

        // Checks the signature *and* the requirement in one call, against the
        // code that is actually running rather than the bundle on disk.
        return SecCodeCheckValidity(peer, [], designated) == errSecSuccess ? .codeSignature : .none
    }
}

// MARK: - The connection

/// A live connection to one app. Not thread-safe by design: it is an actor's
/// business to own one of these, and `AppLinkService` does.
nonisolated final class AppLinkConnection {
    private let descriptor: Int32
    private var decoder = AppLinkFrameDecoder()
    private var nextRequestIdentifier = 1
    private(set) var peerVerification: AppLinkPeerVerification
    private(set) var session: AppLinkSession?
    private var isClosed = false

    let instance: AppLinkInstance

    private init(descriptor: Int32, instance: AppLinkInstance, verification: AppLinkPeerVerification) {
        self.descriptor = descriptor
        self.instance = instance
        self.peerVerification = verification
    }

    deinit {
        if !isClosed { Darwin.close(descriptor) }
    }

    /// Open the socket, verify the peer, and complete the handshake.
    ///
    /// `scopes` is what to ask the user for. Asking for nothing is legitimate
    /// and prompts nobody — `describe` is outside the scopes precisely so a
    /// caller can look before it asks.
    static func open(
        to instance: AppLinkInstance,
        clientIdentifier: String,
        clientName: String,
        clientVersion: String?,
        scopes: [String],
        teamIdentifier: String = AppLinkPeerVerifier.expectedTeamIdentifier
    ) throws -> AppLinkConnection {
        guard instance.speaksAKnownProtocol else {
            throw AppLinkError.socketCouldNotBeOpened(
                reason: "\(instance.appName) speaks app-link \(instance.protocolVersion) and Iris speaks \(AppLinkProtocol.version)."
            )
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AppLinkError.socketCouldNotBeOpened(reason: String(cString: strerror(errno)))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(instance.socketPath.utf8)
        // `sun_path` is 104 bytes on macOS including the terminator. The app
        // side falls back to a short directory when a path would not fit, and
        // records the real one in the instance file — so anything arriving here
        // too long is a corrupt file rather than a long username.
        // Read out into a local first: passing `&address.sun_path` to
        // withUnsafeMutablePointer while also reading it for the capacity is
        // two overlapping accesses, and Swift rejects it.
        let sunPathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < sunPathCapacity else {
            Darwin.close(descriptor)
            throw AppLinkError.socketCouldNotBeOpened(reason: "The app's socket path is too long to open.")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { destination in
                for (offset, byte) in pathBytes.enumerated() { destination[offset] = CChar(bitPattern: byte) }
                destination[pathBytes.count] = 0
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw AppLinkError.socketCouldNotBeOpened(reason: reason)
        }

        let verification = AppLinkPeerVerifier.verify(descriptor: descriptor, teamIdentifier: teamIdentifier)
        let connection = AppLinkConnection(descriptor: descriptor, instance: instance, verification: verification)

        do {
            let result = try connection.call(
                method: "connect",
                parameters: [
                    "token": instance.token,
                    "client": [
                        "id": clientIdentifier,
                        "name": clientName,
                        "version": clientVersion as Any,
                        "pid": Int(ProcessInfo.processInfo.processIdentifier),
                    ],
                    "scopes": scopes,
                ],
                timeoutSeconds: scopes.isEmpty ? AppLinkProtocol.requestTimeoutSeconds : AppLinkProtocol.connectTimeoutSeconds
            )

            let session = AppLinkSession(
                protocolVersion: result["protocolVersion"] as? String ?? "0",
                instanceId: result["instanceId"] as? String ?? "",
                appId: (result["app"] as? [String: Any])?["id"] as? String ?? instance.appId,
                appSlug: (result["app"] as? [String: Any])?["slug"] as? String ?? instance.appSlug,
                appName: (result["app"] as? [String: Any])?["name"] as? String ?? instance.appName,
                appVersion: (result["app"] as? [String: Any])?["version"] as? String ?? instance.appVersion,
                grantedScopes: result["granted"] as? [String] ?? [],
                deniedScopes: result["denied"] as? [String] ?? []
            )

            // The instance file named a process. If a recycled PID put someone
            // else behind that socket, this is where it surfaces — rather than
            // three calls later, in data that looks almost right.
            guard session.instanceId == instance.instanceId else {
                connection.close()
                throw AppLinkError.instanceMismatch(expected: instance.instanceId, actual: session.instanceId)
            }

            connection.session = session
            return connection
        } catch {
            connection.close()
            throw error
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(descriptor)
    }

    // MARK: Verbs

    func describe() throws -> [String: Any] {
        try call(method: "describe", parameters: [:])
    }

    func state() throws -> [String: Any] {
        let result = try call(method: "get_state", parameters: [:])
        return result["state"] as? [String: Any] ?? [:]
    }

    func recentEvents(limit: Int = 50, minimumLevel: String = "warn") throws -> [AppLinkEvent] {
        let result = try call(method: "get_recent_events", parameters: ["limit": limit, "minLevel": minimumLevel])
        return (result["events"] as? [[String: Any]] ?? []).compactMap(AppLinkEvent.init(json:))
    }

    func lastError() throws -> AppLinkEvent? {
        let result = try call(method: "get_last_error", parameters: [:])
        guard let json = result["event"] as? [String: Any] else { return nil }
        return AppLinkEvent(json: json)
    }

    func captureDiagnostics(limit: Int = 50) throws -> AppLinkDiagnostics {
        let result = try call(
            method: "capture_diagnostics",
            parameters: ["limit": limit],
            timeoutSeconds: 15
        )
        guard let diagnostics = AppLinkDiagnostics(json: result, appId: instance.appId, verification: peerVerification) else {
            throw AppLinkError.responseCouldNotBeDecoded(reason: "The diagnostics bundle was not in the expected shape.")
        }
        return diagnostics
    }

    @discardableResult
    func invokeAction(named name: String, arguments: [String: Any] = [:]) throws -> Any? {
        let result = try call(
            method: "invoke_action",
            parameters: ["name": name, "arguments": arguments],
            timeoutSeconds: 30
        )
        return result["result"]
    }

    // MARK: Request / response

    /// Blocking. Callers hold this off the main actor; `AppLinkService` does.
    private func call(
        method: String,
        parameters: [String: Any],
        timeoutSeconds: Double = AppLinkProtocol.requestTimeoutSeconds
    ) throws -> [String: Any] {
        guard !isClosed else { throw AppLinkError.connectionClosed }

        let identifier = nextRequestIdentifier
        nextRequestIdentifier += 1

        let frame: Data
        do {
            frame = try AppLinkFrameEncoder.encode(id: identifier, method: method, parameters: parameters)
        } catch {
            throw AppLinkError.responseCouldNotBeDecoded(reason: "Iris could not encode the request.")
        }
        try writeAll(frame)

        // One request at a time, so anything with a different id is a reply to
        // something already abandoned and is dropped rather than mismatched.
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AppLinkError.timedOut(method: method) }

            let chunk = try read(timeoutSeconds: remaining, method: method)
            let messages: [[String: Any]]
            do {
                messages = try decoder.push(chunk)
            } catch AppLinkFrameDecoder.DecodeFailure.frameTooLarge {
                close()
                throw AppLinkError.frameTooLarge
            } catch {
                close()
                throw AppLinkError.responseCouldNotBeDecoded(reason: "The app sent something that was not JSON.")
            }

            for message in messages {
                guard (message["id"] as? Int) == identifier else { continue }
                if let failure = message["error"] as? [String: Any] {
                    throw AppLinkError.remote(
                        code: failure["code"] as? Int ?? AppLinkErrorCode.internalError.rawValue,
                        message: failure["message"] as? String ?? "The app refused."
                    )
                }
                return message["result"] as? [String: Any] ?? [:]
            }
        }
    }

    private func writeAll(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                throw AppLinkError.connectionClosed
            }
        }
    }

    private func read(timeoutSeconds: Double, method: String) throws -> Data {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(1, min(timeoutSeconds * 1000, Double(Int32.max))))
        let ready = poll(&pollDescriptor, 1, milliseconds)
        if ready == 0 { throw AppLinkError.timedOut(method: method) }
        if ready < 0 {
            if errno == EINTR { return Data() }
            throw AppLinkError.connectionClosed
        }

        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 { return Data(buffer[0..<count]) }
        if count == 0 {
            close()
            throw AppLinkError.connectionClosed
        }
        if errno == EINTR || errno == EAGAIN { return Data() }
        close()
        throw AppLinkError.connectionClosed
    }
}

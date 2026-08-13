//
//  BreakSignatureService.swift
//  leanring-buddy
//
//  Turns a failure artifact into the identity maintain mode pools on: a
//  32-hex signature plus two fingerprint tiers, computed entirely on this
//  machine, before anything is asked of a user, a server, or a model.
//
//  The whole cost model leans on this file being right. A signature that
//  hashes volatile fields (addresses, line numbers, generic-instantiation
//  hexes) buckets every crash separately and the pool never gets a hit; a
//  signature that hashes too little merges different bugs. The normalizers
//  here follow the grouping lessons of the mature systems in this space:
//  strip what varies between two hits of the same bug, keep what varies
//  between two different bugs, and never re-bucket retroactively — which is
//  why `signatureAlgoVersion` rides along with every signature produced.
//
//  A macOS crash report (`.ips`) is two concatenated JSON blobs: line one is
//  the metadata header, the remainder is the crash body. Swift's runtime
//  traps (force-unwrap, array bounds, failed casts) arrive as EXC_BREAKPOINT
//  with the runtime's own reporting frames on top — the signature must walk
//  past those to the caller, or every Swift trap in an app buckets as
//  "_assertionFailure".
//

import CryptoKit
import Foundation

/// Which family of failure a signature identifies. Mirrors the server's
/// `signatures.signature_kind` check constraint exactly.
enum BreakSignatureKind: String, Sendable {
    case nativeCrash = "native-crash"
    case rustPanic = "rust-panic"
    case jsException = "js-exception"
    case hang
    case oom
    case launchFailure = "launch-failure"
    case logPattern = "log-pattern"
}

/// The stack an app is built on, from the catalog. Decides which normalizer
/// runs. Mirrors the server's `signatures.app_stack` check constraint.
enum BreakAppStack: String, Sendable {
    case tauri
    case electron
    case nextjs
    case swiftMacOS = "swift-macos"
    case other
}

/// One frame of the faulting stack, already reduced to what grouping needs.
struct BreakSignatureFrame: Equatable, Sendable {
    let module: String
    let function: String
    /// Basename only; the full path would embed the OS account name.
    let sourceFile: String?
    /// True when the frame resolves inside the app's own binary rather than
    /// a system library or a language runtime.
    let isApplicationFrame: Bool
}

/// Everything maintain mode knows about one failure's identity. The fields
/// map one-to-one onto the intake payload of `POST /api/iris/breaks`.
struct BreakSignature: Equatable, Sendable {
    /// sha256 of the normalized composite, truncated to 32 hex characters —
    /// the same shape `app_breaks.break_signature` already uses.
    let signatureId: String
    let appSlug: String
    let appStack: BreakAppStack
    let kind: BreakSignatureKind
    let algoVersion: Int
    /// Exception type + source file + function: the tier that means "the same
    /// crash at the same place".
    let fingerprintStrict: String
    /// Function (or template) only: absorbs "same bug, code moved a few
    /// lines" — the most common drift between app versions.
    let fingerprintLoose: String
    /// The frames a human reads when reviewing what got pooled.
    let topFrames: [BreakSignatureFrame]
    /// The pre-hash composite, kept for debugging bucketing decisions.
    let protoSignature: String
}

/// The parsed shape of one `.ips` crash report — only the fields grouping
/// and symbolication need, not the whole format.
struct ParsedCrashReport: Sendable {
    let appName: String
    let bundleIdentifier: String?
    let appVersion: String?
    let osVersion: String?
    let exceptionType: String?
    let exceptionSignal: String?
    let terminationIndicator: String?
    /// Frames of the thread that crashed, in order, innermost first.
    let faultingFrames: [RawCrashFrame]
    /// Per-image UUIDs — the symbolication join keys, one per loaded binary.
    let imageUUIDsByIndex: [Int: String]
    let imageNamesByIndex: [Int: String]

    struct RawCrashFrame: Sendable {
        let imageIndex: Int
        let symbol: String?
        let sourceFile: String?
    }
}

enum BreakSignatureError: Error {
    case notAnIPSFile
    case missingCrashBody
    case noFaultingThread
}

enum BreakSignatureService {

    /// Bumped only with a shadow-mode migration on the server. Never reuse a
    /// version number for a changed scheme.
    static let signatureAlgoVersion = 1

    // MARK: - Parsing the two-blob .ips format

    static func parseCrashReport(fromIPSText text: String) throws -> ParsedCrashReport {
        guard let firstLineEnd = text.firstIndex(of: "\n") else {
            throw BreakSignatureError.notAnIPSFile
        }
        let headerText = String(text[..<firstLineEnd])
        let bodyText = String(text[text.index(after: firstLineEnd)...])

        guard
            let headerData = headerText.data(using: .utf8),
            let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else {
            throw BreakSignatureError.notAnIPSFile
        }
        guard
            let bodyData = bodyText.data(using: .utf8),
            let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            throw BreakSignatureError.missingCrashBody
        }

        let exception = body["exception"] as? [String: Any]
        let termination = body["termination"] as? [String: Any]

        // The faulting thread is the one marked `triggered`; a report with
        // none (rare, but real) falls back to the first thread rather than
        // refusing to produce any identity at all.
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = threads.first(where: { ($0["triggered"] as? Bool) == true }) ?? threads.first
        guard let faulting else { throw BreakSignatureError.noFaultingThread }
        let frames = (faulting["frames"] as? [[String: Any]] ?? []).map { frame in
            ParsedCrashReport.RawCrashFrame(
                imageIndex: frame["imageIndex"] as? Int ?? -1,
                symbol: frame["symbol"] as? String,
                sourceFile: frame["sourceFile"] as? String
            )
        }

        var uuidsByIndex: [Int: String] = [:]
        var namesByIndex: [Int: String] = [:]
        for (index, image) in (body["usedImages"] as? [[String: Any]] ?? []).enumerated() {
            if let uuid = image["uuid"] as? String { uuidsByIndex[index] = uuid }
            if let name = image["name"] as? String { namesByIndex[index] = name }
        }

        return ParsedCrashReport(
            appName: header["app_name"] as? String ?? body["procName"] as? String ?? "unknown",
            bundleIdentifier: header["bundleID"] as? String,
            appVersion: header["app_version"] as? String,
            osVersion: (header["os_version"] as? String),
            exceptionType: exception?["type"] as? String,
            exceptionSignal: exception?["signal"] as? String,
            terminationIndicator: termination?["indicator"] as? String,
            faultingFrames: frames,
            imageUUIDsByIndex: uuidsByIndex,
            imageNamesByIndex: namesByIndex
        )
    }

    // MARK: - Native-crash signature

    /// Modules whose frames are reporting machinery or shared runtime, never
    /// the bug's identity. A crash with no frames outside these still gets an
    /// identity from the exception type alone — categorical beats nothing.
    private static let runtimeModulePrefixes = [
        "libswiftCore", "libswift", "libobjc", "libsystem", "libc++", "libdispatch",
        "dyld", "CoreFoundation", "Foundation", "AppKit", "HIToolbox", "SkyLight",
        "Electron Framework", "Chromium Embedded",
    ]

    /// Symbols the Swift runtime interposes when it *chooses* to crash
    /// (force-unwrap, bounds, casts). The signature walks past these to the
    /// caller, or every Swift trap buckets identically. The runtime's own
    /// reporting closures live in libswiftCore, so the module filter already
    /// removes them — an app's own closures must stay eligible.
    private static let swiftReportingSymbolPrefixes = [
        "_assertionFailure", "swift_reportError", "fatalError",
        "swift::fatalError", "_swift_stdlib_reportFatalError",
    ]

    static func nativeCrashSignature(
        fromParsedReport report: ParsedCrashReport,
        appSlug: String,
        appStack: BreakAppStack
    ) -> BreakSignature {
        let eligibleFrames = report.faultingFrames.compactMap { frame -> BreakSignatureFrame? in
            let module = report.imageNamesByIndex[frame.imageIndex] ?? "unknown"
            guard let symbol = frame.symbol, !symbol.isEmpty else { return nil }
            if runtimeModulePrefixes.contains(where: { module.hasPrefix($0) }) { return nil }
            if swiftReportingSymbolPrefixes.contains(where: { symbol.hasPrefix($0) }) { return nil }
            return BreakSignatureFrame(
                module: module,
                function: normalizeSymbol(symbol),
                sourceFile: frame.sourceFile.map { ($0 as NSString).lastPathComponent },
                isApplicationFrame: module == report.appName
            )
        }

        // Prefer the app's own frames; a crash entirely inside a framework
        // still gets an identity from whatever survived the runtime filter.
        let applicationFrames = eligibleFrames.filter { $0.isApplicationFrame }
        let signatureFrames = Array((applicationFrames.isEmpty ? eligibleFrames : applicationFrames).prefix(3))

        let exceptionType = report.exceptionType ?? "UNKNOWN_EXCEPTION"
        let frameComposite = signatureFrames
            .map { "\($0.module)!\($0.function)" }
            .joined(separator: "|")
        let composite = "\(appSlug)|\(appStack.rawValue)|\(exceptionType)|\(frameComposite)"

        let topFunction = signatureFrames.first?.function ?? "no-symbol"
        let topFile = signatureFrames.first?.sourceFile ?? "no-file"

        return BreakSignature(
            signatureId: truncatedSHA256(composite),
            appSlug: appSlug,
            appStack: appStack,
            kind: .nativeCrash,
            algoVersion: signatureAlgoVersion,
            fingerprintStrict: "\(exceptionType)|\(topFile)|\(topFunction)",
            fingerprintLoose: topFunction,
            topFrames: signatureFrames,
            protoSignature: composite
        )
    }

    // MARK: - Categorical signatures (no stack: the stack would be noise)

    static func hangSignature(appSlug: String, appStack: BreakAppStack, blockedTopFrame: String?) -> BreakSignature {
        let frame = blockedTopFrame.map(normalizeSymbol) ?? "main-thread"
        let composite = "\(appSlug)|\(appStack.rawValue)|hang|\(frame)"
        return BreakSignature(
            signatureId: truncatedSHA256(composite),
            appSlug: appSlug, appStack: appStack, kind: .hang,
            algoVersion: signatureAlgoVersion,
            fingerprintStrict: "hang|\(frame)", fingerprintLoose: frame,
            topFrames: [], protoSignature: composite
        )
    }

    static func launchFailureSignature(
        appSlug: String, appStack: BreakAppStack, daemon: String, normalizedReason: String
    ) -> BreakSignature {
        let reason = normalizeMessage(normalizedReason)
        let composite = "\(appSlug)|\(appStack.rawValue)|launch|\(daemon)|\(reason)"
        return BreakSignature(
            signatureId: truncatedSHA256(composite),
            appSlug: appSlug, appStack: appStack, kind: .launchFailure,
            algoVersion: signatureAlgoVersion,
            fingerprintStrict: "launch|\(daemon)|\(reason)", fingerprintLoose: "launch|\(daemon)",
            topFrames: [], protoSignature: composite
        )
    }

    // MARK: - Normalization

    /// Strips what varies between two hits of the same bug: hex addresses,
    /// Rust generic-instantiation disambiguators, template noise, and
    /// trailing offsets. Deliberately does NOT strip closure nesting or
    /// argument labels — those distinguish genuinely different call sites.
    static func normalizeSymbol(_ symbol: String) -> String {
        var normalized = symbol
        for pattern in [
            #"0x[0-9a-fA-F]+"#,          // addresses
            #"\+ [0-9]+$"#,              // trailing offsets
            #"::h[0-9a-f]{16}"#,         // Rust v0/legacy generic hashes
            #"\$[0-9a-f]{8,}"#,          // mangling residue
        ] {
            normalized = normalized.replacingOccurrences(
                of: pattern, with: "<x>", options: .regularExpression
            )
        }
        return normalized.trimmingCharacters(in: .whitespaces)
    }

    /// Message normalization for launch failures and log-derived signatures:
    /// paths, UUIDs, and numbers become placeholders so the message's shape,
    /// not its incidentals, is the identity. The patterns and their order
    /// MIRROR `lib/break-signature.ts` (`normalizeBreakMessage`) exactly —
    /// the web and the desktop must bucket the same message identically or
    /// the pool splits in two. Any change here changes there, with a test on
    /// both sides. Path replacement is also the mandatory redaction: every
    /// macOS path embeds the account name.
    static func normalizeMessage(_ message: String) -> String {
        var normalized = message.lowercased()
        for (pattern, replacement) in [
            (#"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, "<uuid>"),
            (#"0x[0-9a-f]+"#, "<addr>"),
            (#"\b[0-9a-f]{7,}\b"#, "<hex>"),
            // Windows paths before POSIX ones: the POSIX pattern would
            // otherwise eat the tail of "C:\Users\x\y" and leave a stray
            // drive letter behind.
            (#"[a-z]:\\[^\s"']*"#, "<path>"),
            (#"(?:/[^\s"'/]+){2,}/?"#, "<path>"),
            (#"\d+"#, "<n>"),
            (#"\s+"#, " "),
        ] {
            normalized = normalized.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression
            )
        }
        normalized = normalized.trimmingCharacters(in: .whitespaces)
        if normalized.count > 300 {
            normalized = String(normalized.prefix(300))
        }
        return normalized
    }

    private static func truncatedSHA256(_ composite: String) -> String {
        let digest = SHA256.hash(data: Data(composite.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).lowercased()
    }
}

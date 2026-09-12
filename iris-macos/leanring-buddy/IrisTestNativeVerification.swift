//
// A separate, operator-declared native verification lane. This is not the
// command sandbox and is never a fallback for model-authored commands.
//

import CryptoKit
import Darwin
import Foundation

nonisolated enum IrisTestNativeVerification {
    /// Production code must construct this from reviewed registry data. A
    /// model reply is not an accepted source for a plan.
    struct Plan: Codable, Equatable, Sendable {
        let executablePath: String
        let arguments: [String]
        let protectedFileSHA256: [String: String]
        let executableSHA256: String
        let deadlineSeconds: Double
    }

    enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case invalidPlan(String)
        case registrationRejected
        case integrityChanged(String)

        var errorDescription: String? {
            switch self {
            case .invalidPlan(let reason): return "Native verification plan rejected: \(reason)"
            case .registrationRejected:
                return "Native verification stopped because its registered project is no longer current."
            case .integrityChanged(let path): return "Native verification changed a protected file: \(path)"
            }
        }
    }

    /// Spawns the fixed executable and argv directly through a tiny fixed
    /// process-group launcher. No shell or inherited environment is used.
    static func validate(plan: Plan, repoRootPath: String, environment: [String: String]) throws {
        try verify(Prepared(plan, repoRootPath: repoRootPath, environment: environment))
    }

    static func run(
        plan: Plan,
        repoRootPath: String,
        environment: [String: String],
        registrationIsCurrent: @Sendable () -> Bool
    ) async throws -> MaintainCommandResult {
        let prepared = try Prepared(plan, repoRootPath: repoRootPath, environment: environment)
        try Task.checkCancellation()
        guard registrationIsCurrent() else { throw Error.registrationRejected }
        try verify(prepared)

        let control = ProcessControl()
        let result = await withTaskCancellationHandler(operation: {
            await execute(prepared, control: control)
        }, onCancel: {
            control.cancel()
        })

        // Do not turn cancellation or timeout into an excuse to skip the
        // post-run integrity and registration checks.
        try verify(prepared)
        guard registrationIsCurrent() else { throw Error.registrationRejected }
        try Task.checkCancellation()
        return result
    }

    private struct Guard: Sendable {
        let path: String
        let digest: String
    }

    private struct Prepared: Sendable {
        let executablePath: String
        let arguments: [String]
        let protectedFiles: [Guard]
        let executableDigest: String
        let repoRootPath: String
        let scratchPath: String
        let environment: [String: String]
        let deadline: TimeInterval

        init(_ plan: Plan, repoRootPath: String, environment: [String: String]) throws {
            guard repoRootPath.hasPrefix("/"),
                  let root = canonicalDirectory(repoRootPath),
                  root == URL(fileURLWithPath: repoRootPath).standardizedFileURL.path else {
                throw Error.invalidPlan("repository root must be an existing canonical absolute directory")
            }
            guard plan.deadlineSeconds.isFinite, plan.deadlineSeconds > 0,
                  plan.deadlineSeconds <= 900 else {
                throw Error.invalidPlan("deadline must be greater than zero and at most 900 seconds")
            }
            guard plan.executablePath.hasPrefix("/"), !hasNUL(plan.executablePath),
                  let executable = canonicalFile(plan.executablePath),
                  executable == URL(fileURLWithPath: plan.executablePath).standardizedFileURL.path,
                  FileManager.default.isExecutableFile(atPath: executable),
                  isDigest(plan.executableSHA256) else {
                throw Error.invalidPlan("executable must be canonical, executable and SHA256-pinned")
            }
            guard !plan.arguments.contains(where: hasNUL),
                  !plan.arguments.contains(where: sandboxDisablingArgument) else {
                throw Error.invalidPlan("NUL or sandbox-disabling arguments are refused")
            }
            guard let scratch = environment["TMPDIR"], environment["HOME"] == scratch,
                  scratch.hasPrefix("/"), let canonicalScratch = canonicalDirectory(scratch),
                  canonicalScratch == URL(fileURLWithPath: scratch).standardizedFileURL.path else {
                throw Error.invalidPlan("HOME and TMPDIR must name the same canonical scratch directory")
            }
            guard !plan.protectedFileSHA256.isEmpty else {
                throw Error.invalidPlan("at least one protected entry/config file is required")
            }
            let files = try plan.protectedFileSHA256.sorted { $0.key < $1.key }.map { path, digest in
                guard path.hasPrefix("/"), !hasNUL(path), isDigest(digest),
                      let canonical = canonicalFile(path),
                      canonical == URL(fileURLWithPath: path).standardizedFileURL.path,
                      canonical.hasPrefix(root + "/") else {
                    throw Error.invalidPlan("protected files must be canonical files inside the repository")
                }
                return Guard(path: canonical, digest: digest.lowercased())
            }
            guard Set(files.map(\.path)).count == files.count else {
                throw Error.invalidPlan("protected file paths must be unique")
            }
            self.executablePath = executable
            self.arguments = plan.arguments
            self.protectedFiles = files
            self.executableDigest = plan.executableSHA256.lowercased()
            self.repoRootPath = root
            self.scratchPath = canonicalScratch
            self.environment = environment
            self.deadline = plan.deadlineSeconds
        }
    }

    private static let launcher = "/usr/bin/perl"
    private static let groupScript =
        "setpgrp(0,0) or die 'process group failed'; exec @ARGV; die 'exec failed';"

    private static func execute(_ plan: Prepared, control: ProcessControl) async -> MaintainCommandResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<MaintainCommandResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launcher)
            process.arguments = ["-e", groupScript, "--", plan.executablePath] + plan.arguments
            process.environment = plan.environment
            process.currentDirectoryURL = URL(fileURLWithPath: plan.repoRootPath, isDirectory: true)
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let output = Output()
            let state = ExecutionState(continuation)
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
            pipe.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
            process.terminationHandler = { finished in
                ProcessControl.killGroup(finished)
                state.cancelTimeout()
                pipe.fileHandleForReading.readabilityHandler = nil
                drainAvailable(descriptor, into: output)
                let (tail, dropped) = output.tail()
                finished.terminationHandler = nil
                state.finish(MaintainCommandResult(
                    exitCode: finished.terminationStatus, outputTail: tail,
                    timedOut: state.timedOut, bytesDroppedBeforeTail: dropped
                ))
            }
            do {
                try process.run()
                control.attach(process)
                if control.wasCancelled { control.cancel(); return }
                let timeout = DispatchWorkItem {
                    if state.markTimedOut() { control.terminate() }
                }
                state.installTimeout(timeout)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + plan.deadline, execute: timeout
                )
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                state.cancelTimeout()
                state.finish(MaintainCommandResult(
                    exitCode: 127, outputTail: "failed to spawn native verification process",
                    timedOut: false, bytesDroppedBeforeTail: 0
                ))
            }
        }
    }

    private static func verify(_ plan: Prepared) throws {
        guard canonicalDirectory(plan.repoRootPath) == plan.repoRootPath,
              canonicalDirectory(plan.scratchPath) == plan.scratchPath,
              canonicalFile(plan.executablePath) == plan.executablePath,
              try digest(plan.executablePath) == plan.executableDigest,
              canonicalFile(plan.executablePath) == plan.executablePath else {
            throw Error.integrityChanged(plan.executablePath)
        }
        for file in plan.protectedFiles {
            guard canonicalFile(file.path) == file.path,
                  try digest(file.path) == file.digest,
                  canonicalFile(file.path) == file.path else {
                throw Error.integrityChanged(file.path)
            }
        }
    }

    private static func drainAvailable(_ descriptor: Int32, into output: Output) {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var drained = 0
        var interrupts = 0
        while drained < 262_144 {
            let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                output.append(Data(bytes: bytes, count: Int(count)))
                drained += Int(count)
            } else if count < 0 && errno == EINTR {
                interrupts += 1
                if interrupts >= 8 { return }
                continue
            } else {
                return
            }
        }
    }

    private static func digest(_ path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalDirectory(_ path: String) -> String? {
        MaintainSandbox.canonicalExistingDirectory(path)
    }

    private static func canonicalFile(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let result = String(cString: resolved)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: result, isDirectory: &directory),
              !directory.boolValue, FileManager.default.isReadableFile(atPath: result) else { return nil }
        return result
    }

    private static func hasNUL(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value == 0 }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 70)
                || ($0.value >= 97 && $0.value <= 102)
        }
    }

    private static func sandboxDisablingArgument(_ value: String) -> Bool {
        let argument = value.lowercased()
        return argument.contains("no-sandbox") || argument.contains("disable-sandbox")
            || (argument.contains("sandbox") && argument.contains("disable"))
            || argument == "--sandbox=false" || argument == "sandbox=false"
    }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancellationRequested }

    func attach(_ process: Process) {
        lock.lock()
        if cancellationRequested { lock.unlock(); Self.terminate(process); return }
        self.process = process
        lock.unlock()
    }

    func cancel() {
        lock.lock(); cancellationRequested = true; let process = self.process; lock.unlock()
        if let process { Self.terminate(process) }
    }

    func terminate() {
        lock.lock(); let process = self.process; lock.unlock()
        if let process { Self.terminate(process) }
    }

    private static func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
        killGroup(process)
    }

    fileprivate static func killGroup(_ process: Process) {
        let pid = process.processIdentifier
        if pid > 0 { _ = killpg(pid, SIGKILL) }
    }
}

private final class ExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MaintainCommandResult, Never>?
    private var finished = false
    private var timedOutValue = false
    private var timeout: DispatchWorkItem?

    init(_ continuation: CheckedContinuation<MaintainCommandResult, Never>) { self.continuation = continuation }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOutValue }

    func installTimeout(_ timeout: DispatchWorkItem) {
        lock.lock()
        if finished { lock.unlock(); timeout.cancel(); return }
        self.timeout = timeout
        lock.unlock()
    }

    func cancelTimeout() {
        lock.lock(); let timeout = self.timeout; self.timeout = nil; lock.unlock(); timeout?.cancel()
    }

    func markTimedOut() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        timedOutValue = true
        return true
    }

    func finish(_ result: MaintainCommandResult) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let timeout = self.timeout
        self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        continuation?.resume(returning: result)
    }
}

private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var dropped = 0

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > 262_144 {
            let kept = data.suffix(262_144)
            dropped += data.count - kept.count
            data = Data(kept)
        }
    }

    func tail() -> (String, Int) {
        lock.lock(); defer { lock.unlock() }
        let tail = data.suffix(65_536)
        return (String(decoding: tail, as: UTF8.self), dropped + data.count - tail.count)
    }
}

import CryptoKit
import Foundation
@testable import IrisHarnessNative

private enum NativeVerificationCheckError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

private final class RegistrationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var currentValue = true
    private var callsValue = 0
    var current: Bool { lock.lock(); defer { lock.unlock() }; return currentValue }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return callsValue }
    func check() -> Bool {
        lock.lock(); callsValue += 1; let value = currentValue; lock.unlock(); return value
    }
    func set(_ value: Bool) { lock.lock(); currentValue = value; lock.unlock() }
}

@main
struct IrisTestNativeVerificationChecks {
    static func main() async throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory
            .appendingPathComponent("iris-native-check-parent-" + UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("iris-native-check-" + UUID().uuidString)
        let scratch = root.appendingPathComponent("scratch")
        let protectedURL = root.appendingPathComponent("entry.json")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("{\"version\":1}\n".utf8).write(to: protectedURL)
        defer { try? fm.removeItem(at: parent) }

        let environment = ["HOME": scratch.path, "TMPDIR": scratch.path,
                           "PATH": "/usr/bin:/bin", "LANG": "C"]
        let printf = "/usr/bin/printf"
        let sleep = "/bin/sleep"
        let digest: (String) throws -> String = { path in
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let protectedDigest = try digest(protectedURL.path)
        let basePlan: (String, [String], Double) -> IrisTestNativeVerification.Plan = { executable, arguments, deadline in
            IrisTestNativeVerification.Plan(
                executablePath: executable,
                arguments: arguments,
                protectedFileSHA256: [protectedURL.path: protectedDigest],
                executableSHA256: (try? digest(executable)) ?? "",
                deadlineSeconds: deadline
            )
        }

        let roundTrip = basePlan(printf, ["%s", "literal; echo not-a-shell"], 5)
        let encoded = try JSONEncoder().encode(roundTrip)
        guard try JSONDecoder().decode(IrisTestNativeVerification.Plan.self, from: encoded) == roundTrip else {
            throw NativeVerificationCheckError.failed("Plan Codable/Equatable round trip failed")
        }
        print("PASS Plan Codable and explicit fields")

        let registration = RegistrationBox()
        let exact = try await IrisTestNativeVerification.run(
            plan: roundTrip, repoRootPath: root.path, environment: environment,
            registrationIsCurrent: { registration.check() }
        )
        guard exact.succeeded, exact.outputTail == "literal; echo not-a-shell",
              registration.calls == 2,
              String(decoding: try Data(contentsOf: protectedURL), as: UTF8.self) == "{\"version\":1}\n" else {
            throw NativeVerificationCheckError.failed("native argv, output, registration or guard check failed")
        }
        print("PASS exact no-shell argv, explicit environment, pre/post registry and hashes")

        let badArguments = ["--no-sandbox", "--disable-gpu-sandbox", "--disable-features=SandboxedRenderer"]
        for argument in badArguments {
            do {
                _ = try await IrisTestNativeVerification.run(
                    plan: basePlan(printf, [argument], 5), repoRootPath: root.path,
                    environment: environment, registrationIsCurrent: { true }
                )
                throw NativeVerificationCheckError.failed("sandbox-disabling argument was accepted: \(argument)")
            } catch IrisTestNativeVerification.Error.invalidPlan { }
        }
        do {
            _ = try await IrisTestNativeVerification.run(
                plan: basePlan(printf, ["%s", "x"], 5), repoRootPath: root.path,
                environment: ["HOME": scratch.path, "TMPDIR": root.path], registrationIsCurrent: { true }
            )
            throw NativeVerificationCheckError.failed("mismatched scratch environment was accepted")
        } catch IrisTestNativeVerification.Error.invalidPlan { }
        print("PASS sandbox-disabling args and scratch-environment rejection")

        registration.set(false)
        do {
            _ = try await IrisTestNativeVerification.run(
                plan: roundTrip, repoRootPath: root.path, environment: environment,
                registrationIsCurrent: { registration.check() }
            )
            throw NativeVerificationCheckError.failed("unregistered plan was launched")
        } catch IrisTestNativeVerification.Error.registrationRejected { }
        registration.set(true)

        try Data("changed-before-launch\n".utf8).write(to: protectedURL)
        do {
            _ = try await IrisTestNativeVerification.run(
                plan: roundTrip, repoRootPath: root.path, environment: environment,
                registrationIsCurrent: { true }
            )
            throw NativeVerificationCheckError.failed("prelaunch protected-file change was accepted")
        } catch IrisTestNativeVerification.Error.integrityChanged { }
        try Data("{\"version\":1}\n".utf8).write(to: protectedURL)
        print("PASS registration and prelaunch integrity rejection")

        let mutate = root.appendingPathComponent("mutate.sh")
        let mutation = "#!/bin/sh\nprintf changed-after-launch > \"\(protectedURL.path)\"\n"
        try Data(mutation.utf8).write(to: mutate)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mutate.path)
        do {
            _ = try await IrisTestNativeVerification.run(
                plan: basePlan(mutate.path, [], 5), repoRootPath: root.path,
                environment: environment, registrationIsCurrent: { true }
            )
            throw NativeVerificationCheckError.failed("postrun protected-file change was accepted")
        } catch IrisTestNativeVerification.Error.integrityChanged { }
        try Data("{\"version\":1}\n".utf8).write(to: protectedURL)
        print("PASS postrun integrity rejection")

        let timed = try await IrisTestNativeVerification.run(
            plan: basePlan(sleep, ["5"], 0.1), repoRootPath: root.path,
            environment: environment, registrationIsCurrent: { true }
        )
        guard timed.timedOut else { throw NativeVerificationCheckError.failed("timeout did not terminate process") }
        let cancellation = Task {
            try await IrisTestNativeVerification.run(
                plan: basePlan(sleep, ["5"], 10), repoRootPath: root.path,
                environment: environment, registrationIsCurrent: { true }
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancellation.cancel()
        do {
            _ = try await cancellation.value
            throw NativeVerificationCheckError.failed("cancellation did not throw")
        } catch is CancellationError { }
        print("PASS timeout and cancellation process-group cleanup")

        let bounded = try await IrisTestNativeVerification.run(
            plan: basePlan("/usr/bin/perl", ["-e", "print 'x' x 300000;"], 5), repoRootPath: root.path,
            environment: environment, registrationIsCurrent: { true }
        )
        guard bounded.outputTail.count <= 65_536, bounded.bytesDroppedBeforeTail > 0,
              bounded.outputTail.hasSuffix(String(repeating: "x", count: 100)) else {
            throw NativeVerificationCheckError.failed("native output was not bounded with dropped-byte accounting")
        }
        print("PASS bounded output and dropped-byte accounting")
        let childMarker = root.appendingPathComponent("surviving-child")
        let childProgram = "my $child = fork(); if ($child == 0) { select undef, undef, undef, 0.5; open my $out, '>', $ARGV[0]; print $out 'alive'; exit; } sleep 5;"
        let child = try await IrisTestNativeVerification.run(
            plan: basePlan("/usr/bin/perl", ["-e", childProgram, childMarker.path], 0.1),
            repoRootPath: root.path, environment: environment, registrationIsCurrent: { true })
        try await Task.sleep(nanoseconds: 650_000_000)
        guard child.timedOut, !fm.fileExists(atPath: childMarker.path) else {
            throw NativeVerificationCheckError.failed("a timed-out native descendant survived to write its marker")
        }
        print("PASS timed-out descendant cannot continue writing after its parent exits")
        print("NATIVE VERIFICATION CHECKS PASS: 8 groups")
    }
}

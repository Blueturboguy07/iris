//
//  maintain-test-harness / main.swift
//
//  An adversarial battery for maintain mode. It drives the REAL engine files
//  (BreakSignatureService, VerificationHarness, MaintainShellRunner,
//  MaintainSandbox) against real crash fixtures and real git repos with real
//  injected bugs, and reports pass/fail per scenario. The point is not to be
//  green — it is to map where the pipeline holds and where it breaks.
//
//  run.sh compiles this with the engine files, generates the repos, and runs
//  it: argv[1] = fixtures dir, argv[2] = repos base dir.
//

import Foundation

let fixturesDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./fixtures"
let reposBase = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/iris-harness-repos"

var passed = 0
var failed = 0
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition { passed += 1; print("  ✓ \(name)") }
    else { failed += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : "  — \(detail)")") }
}
func section(_ s: String) { print("\n\(s)") }

func ips(_ name: String) -> String {
    (try? String(contentsOfFile: "\(fixturesDir)/\(name)", encoding: .utf8)) ?? ""
}

await MainActor.run {
    // ============================ DETECTION ============================
    section("DETECTION — one signature per failure kind")

    // D1: native Swift trap — the identity is the CALLER, never the runtime.
    if let reportA = try? BreakSignatureService.parseCrashReport(fromIPSText: ips("swift-crash-A.ips")) {
        let sigA = BreakSignatureService.nativeCrashSignature(
            fromParsedReport: reportA, appSlug: "cue", appStack: .swiftMacOS)
        check("native crash: walks past the runtime to the caller",
              sigA.fingerprintLoose.contains("deep") && !sigA.protoSignature.contains("_assertionFailure"),
              "loose=\(sigA.fingerprintLoose)")
        check("native crash: 32-hex signature",
              sigA.signatureId.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil)
        check("native crash: loose fingerprint carries no line numbers (code can shift)",
              sigA.fingerprintLoose.range(of: "[0-9]{2,}", options: .regularExpression) == nil,
              "loose=\(sigA.fingerprintLoose)")

        // D2: a DIFFERENT bug must not collide with A.
        if let reportB = try? BreakSignatureService.parseCrashReport(fromIPSText: ips("swift-crash-different-bug.ips")) {
            let sigB = BreakSignatureService.nativeCrashSignature(
                fromParsedReport: reportB, appSlug: "cue", appStack: .swiftMacOS)
            check("different bug → different signature", sigA.signatureId != sigB.signatureId)
        } else { check("different-bug fixture parses", false, "missing fixture") }

        // D3: the SAME bug in a different app never shares a signature.
        let sigOtherApp = BreakSignatureService.nativeCrashSignature(
            fromParsedReport: reportA, appSlug: "lunara", appStack: .swiftMacOS)
        check("same crash, different app → different signature", sigA.signatureId != sigOtherApp.signatureId)
    } else {
        check("swift-crash-A.ips parses", false, "missing/failed fixture")
    }

    // D4: Rust panic (was a gap — no .ips, comes from stderr).
    let panicOld = "thread 'main' panicked at 'index out of bounds: the len is 3 but the index is 99', src/parser.rs:42:9"
    let panicNew = "thread 'main' panicked at src/parser.rs:88:9:\nindex out of bounds: the len is 3 but the index is 99"
    let rp1 = BreakSignatureService.rustPanicSignature(appSlug: "whimprflow", appStack: .tauri, panicStderr: panicOld)
    let rp2 = BreakSignatureService.rustPanicSignature(appSlug: "whimprflow", appStack: .tauri, panicStderr: panicNew)
    check("rust panic: produces a rust-panic signature", rp1.kind == .rustPanic, "kind=\(rp1.kind)")
    check("rust panic: same message at a shifted line → same loose fingerprint",
          rp1.fingerprintLoose == rp2.fingerprintLoose, "\(rp1.fingerprintLoose) vs \(rp2.fingerprintLoose)")
    check("rust panic: message is normalized (numbers stripped)",
          !rp1.fingerprintLoose.contains("99"), "loose=\(rp1.fingerprintLoose)")

    // D5: Electron renderer-gone (was a gap — categorical).
    let eg = BreakSignatureService.electronRendererGoneSignature(appSlug: "cue", reason: "oom")
    check("electron renderer-gone: js-exception kind, categorical", eg.kind == .jsException && eg.topFrames.isEmpty)

    // D6: OOM (was a gap — categorical, no stack).
    let oom = BreakSignatureService.outOfMemorySignature(appSlug: "cue", appStack: .electron)
    check("oom: oom kind, no stack", oom.kind == .oom && oom.protoSignature.hasSuffix("|oom"))

    // D7: hang — categorical, no volatile offset leaks in.
    let hang = BreakSignatureService.hangSignature(appSlug: "whimprflow", appStack: .tauri, blockedTopFrame: "AudioCapture::drain + 4816")
    check("hang: no volatile offset in the signature", !hang.protoSignature.contains("4816"), "proto=\(hang.protoSignature)")

    // D8: launch failure — daemon + normalized reason.
    let launch = BreakSignatureService.launchFailureSignature(
        appSlug: "cue", appStack: .electron, daemon: "amfid", normalizedReason: "code signature invalid for /Users/x/cue.app")
    check("launch failure: path normalized out of the reason", !launch.protoSignature.contains("/Users/x"))
}

// ============================ VERIFICATION ============================
// Real git repos built by run.sh, each left with a fix applied to the
// working tree (uncommitted). The harness judges each.
section("VERIFICATION — the gate on real repos with real injected bugs")

func verifyRepo(_ scenario: String, repro: String?, suite: String?) async -> VerificationOutcome? {
    let path = "\(reposBase)/\(scenario)"
    guard let runner = try? MaintainShellRunner(repoRootPath: path) else { return nil }
    let commands = VerificationCommands(buildCommand: "true", testCommand: suite, commandSubdirectory: nil)
    return await VerificationHarness.verifyAppliedPatch(runner: runner, commands: commands, reproCommand: repro)
}

// V1: a real fix, real repro. Every leg must hold.
if let v1 = await verifyRepo("v1-clean-fix", repro: "grep -q FIXED app.txt", suite: "grep -q OK health.txt") {
    await MainActor.run {
        check("clean fix: repro fails pre-patch", v1.reproFailedBeforePatch == true)
        check("clean fix: repro passes post-patch", v1.reproPassedAfterPatch == true)
        check("clean fix: repro fails again on revert (anti-tautology leg)", v1.reproFailedOnRevert == true)
        check("clean fix: full suite green + earns a VERIFIED fix", v1.earnsVerifiedFix, "blocked=\(v1.blockedStage ?? "none")")
    }
}

// V2: a tautological repro (always passes). Must be caught at leg 1.
if let v2 = await verifyRepo("v2-tautology", repro: "true", suite: "grep -q OK health.txt") {
    await MainActor.run {
        check("tautological repro: blocked at leg 1, not accepted",
              v2.blockedStage == "leg1-repro-passed-prepatch" && !v2.earnsVerifiedFix, "blocked=\(v2.blockedStage ?? "none")")
    }
}

// V3: fix makes the repro pass but breaks ANOTHER test (PASS_TO_PASS).
if let v3 = await verifyRepo("v3-breaks-suite", repro: "grep -q FIXED app.txt", suite: "grep -q OK health.txt") {
    await MainActor.run {
        check("breaks another test: suite fails → not a clean fix",
              v3.suitePassed == false && !v3.earnsCleanApply, "suite=\(String(describing: v3.suitePassed))")
    }
}

// V4: the "fix" deletes the failing test to go green (was a gap).
if let v4 = await verifyRepo("v4-deletes-test", repro: nil, suite: "true") {
    await MainActor.run {
        check("deletes a test to pass: blocked by diff-scope",
              v4.blockedStage == "diff-scope" && !v4.earnsCleanApply, "blocked=\(v4.blockedStage ?? "none")")
    }
}

// V5: the "fix" sprawls across 13 files (was a gap).
if let v5 = await verifyRepo("v5-sprawl", repro: nil, suite: "true") {
    await MainActor.run {
        check("sprawls across 13 files: blocked by diff-scope",
              v5.blockedStage == "diff-scope" && !v5.earnsCleanApply, "blocked=\(v5.blockedStage ?? "none")")
    }
}

// ============================ SANDBOX ============================
section("SANDBOX — Tier C's jail")
if MaintainSandbox.isAvailable {
    let path = "\(reposBase)/v1-clean-fix"
    if let runner = try? MaintainShellRunner(repoRootPath: path) {
        if let inside = await MainActor.run(body: { MaintainSandbox.jailedInvocation(forCommand: "echo x > jailed-inside.txt", repoRootPath: path) }) {
            let r = try? await runner.run(inside.invocation, deadline: 30)
            try? FileManager.default.removeItem(atPath: inside.profilePath)
            await MainActor.run { check("jail: write inside the repo is allowed", r?.succeeded == true) }
        }
        if let outside = await MainActor.run(body: { MaintainSandbox.jailedInvocation(forCommand: "echo x > /tmp/iris-harness-escape.txt", repoRootPath: path) }) {
            let r = try? await runner.run(outside.invocation, deadline: 30)
            try? FileManager.default.removeItem(atPath: outside.profilePath)
            await MainActor.run { check("jail: write OUTSIDE the repo is denied", r?.succeeded == false && !FileManager.default.fileExists(atPath: "/tmp/iris-harness-escape.txt")) }
        }
        if let net = await MainActor.run(body: { MaintainSandbox.jailedInvocation(forCommand: "curl -s -m 5 https://example.com > /dev/null", repoRootPath: path) }) {
            let r = try? await runner.run(net.invocation, deadline: 30)
            try? FileManager.default.removeItem(atPath: net.profilePath)
            await MainActor.run { check("jail: network is denied", r?.succeeded == false) }
        }
    }
} else {
    await MainActor.run { check("sandbox available", false, "sandbox-exec missing") }
}

print("\n========================================")
print("RESULT: \(passed) passed, \(failed) failed")
print("========================================")
exit(failed == 0 ? 0 : 1)

//
// Observability parity with the `irisTrace(...)` calls threaded through every
// Swift maintain-mode file (`VerificationHarness.swift`, `PatchQueue.swift`,
// and the rest of `iris-macos/leanring-buddy`'s maintain layer). Every module
// under `services/maintain/` calls this at the same decision points Swift
// traces — verification blocked, a patch queued, a replay superseded or
// conflicted — so the Windows build is diagnosable the same way the Mac build
// already is. This is parity of *observability*, not just of behavior: a
// support engineer reading Windows logs should recognize the same shape of
// narrative a Mac log tells.
//
// Deliberately not a logging library — one function, one prefix, `console.log`.
// If maintain mode ever needs structured logs or log levels, that is a
// different module; this one stays exactly as small as the thing it ports.
//

/// Traces one maintain-mode decision point. `message` should read like a
/// sentence a support engineer can follow without more context — the same
/// register Swift's `irisTrace("maintain: ...")` calls use.
export function maintainTrace(message: string): void {
  console.log(`[maintain] ${message}`);
}

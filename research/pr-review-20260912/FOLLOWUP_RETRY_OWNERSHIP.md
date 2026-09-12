# Follow-up: installer retry ownership

This is a follow-up to frozen review snapshot `e79b401`, not a rewrite of its test results or source manifest.

## What changed

A surfaced install step now acquires a single retry owner before refreshing its terminal environment. Repeated Retry taps and Continue cannot start another command during that refresh. Stop or navigation cancels ownership. Late callbacks must still match the runner, branch and step before changing state.

A failed environment refresh does not execute the step anyway. The UI reports that preparation failed and explains how to start a fresh terminal. Refresh time is shown as active work, without adding an artificial delay.

## Evidence

- Six executable controller regressions passed against the changed native module. The pre-patch module failed 13 assertions with the same tests. These cover repeated Retry, Continue while pending, Stop/Back, stale completion, failed refresh and visible in-flight state.
- The full inert native harness check command completed successfully. This proves the exercised deterministic paths, not model quality or installed target-app behavior.
- Xcode GUI build `801DA1C6-A545-4272-81A2-C44CEFA86EEF` completed with zero errors and 130 warnings. Only the separate Iris Test app was replaced and its signature verified. Normal Iris was unchanged.
- Installed Iris Test binary SHA-256: `ec39b2ec604e957158b53e679be1f8430fc3bd72126f95de829d0c76e0bb8299`. Computer use opened its actual Ask composer after restart.

The build also contains the separate pure redaction-helper extraction documented in the package-wiring follow-up. Do not attribute its complete binary hash to this retry patch alone.

## Reproduction and limits

The standalone test entry point documents compilation against an already-built native module. `GuideRetryWindowProbe.swift` is opt-in and presents production terminal controls with a suspended fake shell. It is explicitly a controlled native fixture, not a full installer or phone acceptance test.

This change addresses one observed concurrency mechanism. It does not establish that Kneecap installs end to end, that a dirty existing folder may be overwritten, or that upstream integration is complete. The separate Iris Test installer isolation restriction remains intact. No model calls, credential permissions, command risk gates or user repositories were changed by this patch.

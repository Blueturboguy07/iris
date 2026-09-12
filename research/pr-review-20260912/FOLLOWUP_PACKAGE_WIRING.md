# Follow-up: standalone usability package wiring

The frozen `e79b401` snapshot's standalone usability package failed to compile because it omitted the redaction helper used by delivery receipts. That original failure remains recorded in the baseline reports.

This follow-up moves the existing redaction function and its three private helpers unchanged from `VerificationHarness.swift` to `VerificationOutputRedaction.swift`. Relative source links add it and the existing output buffer to the isolated usability package. No redaction behavior or delivery gate is changed.

The fresh public-worktree command `swift test --package-path iris-macos/tools/usability-tests --scratch-path <external-scratch>` now passes 134 tests in 17 suites. Existing package unhandled-file and Keychain deprecation warnings remain. This is package/component evidence, not installed feature acceptance.

Together with the retry follow-up, this source was compiled by GUI build `801DA1C6-A545-4272-81A2-C44CEFA86EEF`, installed only as Iris Test, and opened through computer use. The 175-file native host source aggregate is `1c0803483688e9565e74788845468532cb619f4ce14456f041aa76013ca867de`; the Test binary is `ec39b2ec604e957158b53e679be1f8430fc3bd72126f95de829d0c76e0bb8299`.

`SOURCE_MANIFEST.json` still describes the original frozen snapshot, not these later commits. Upstream integration and full complex-feature acceptance remain open.

# Codex provider contract checks

This is a standalone, inert regression fixture for the Codex provider changes.
It is intentionally outside SwiftPM and Xcode. The stubs replace the app's
credential, model-selection, logging, and provider dependencies. The test
generates a temporary fake `codex` executable, so it makes no model call,
network request, credential read, app launch, or real installation.

The eight checks cover:

1. validated reasoning-effort argument emission
2. rejection of an unsupported effort
3. preservation of unknown usage fields as `nil`
4. per-process attempt reporting and the zero-retry harness override
5. prompt framing matches enabled or disabled web-search capability
6. a 256 KiB child stdout burst before stdin consumption, with a 300,000-byte prompt
7. a final-message file followed by a stubborn child, bounded by the provider deadline
8. cancellation and termination of the generated fake child

Run from the repository root:

```sh
set -eu
contract_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/iris-codex-contract.XXXXXX")"
trap 'rm -rf "$contract_output_dir"' EXIT
swiftc -O \
  iris-macos/tools/codex-provider-contract-tests/TypecheckStubs.swift \
  iris-macos/leanring-buddy/CodexMaintainProvider.swift \
  iris-macos/leanring-buddy/FeatureEditRequestProbe.swift \
  iris-macos/tools/codex-provider-contract-tests/ProviderContractChecks.swift \
  -o "$contract_output_dir/iris-codex-provider-contract-checks"
"$contract_output_dir/iris-codex-provider-contract-checks"
```

Expected output:

```text
PASS provider contract checks: 8
```

The large-pipe check is bounded by a two-second task watchdog. The fake child
writes 256 KiB before reading stdin, so the provider must start its stdout and
stderr collectors before sending the 300,000-byte prompt. The deadline check
writes the final-message file, ignores graceful termination, and verifies that
the provider still completes in under 1.5 seconds. A timeout or cancellation is
a failed contract check, not evidence about a live model call.

For the isolated host path, compile with `-D IRIS_HARNESS_HEADLESS` and include
`iris-macos/leanring-buddy/HarnessFixtureEnvironment.swift`. Set
`IRIS_HARNESS_SCRATCH` to an existing private scratch directory when running.
The cancellation check then spawns a fake descendant and verifies that it also
terminates. This remains an inert check, with no real model call.

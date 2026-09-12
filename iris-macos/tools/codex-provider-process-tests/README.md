# Codex production process lifecycle checks

This is a standalone, offline regression tool for the production process path
in `CodexMaintainProvider`. It compiles the provider without
`IRIS_HARNESS_HEADLESS`, then invokes its real `runCodexExec` implementation
with disposable fake Codex executables. It makes no model call, network request,
credential read, app launch, installation, or profile change.

The four checks cover:

1. a large stdin prompt while the child emits more than a pipe buffer
2. a parent that exits while a descendant keeps stdout and stderr open
3. cancellation of a parent plus a descendant
4. a missing executable and its bounded user-facing error mapping

Run from the repository root:

```sh
process_output_dir="$(mktemp -d /tmp/iris-codex-process.XXXXXX)"
swiftc -O \
  iris-macos/tools/codex-provider-process-tests/TypecheckStubs.swift \
  iris-macos/leanring-buddy/CodexMaintainProvider.swift \
  iris-macos/tools/codex-provider-process-tests/ProcessLifecycleChecks.swift \
  -o "$process_output_dir/iris-codex-provider-process-checks"
"$process_output_dir/iris-codex-provider-process-checks"
```

Expected output:

```text
PASS production process lifecycle checks: 4
```

The checks run the production branch, not a copied process implementation. The
fixture holding a pipe sleeps for ten seconds, so the elapsed-time assertion
fails against a provider that waits for EOF after the parent exits. The fixture
also records its descendant PID and verifies that normal completion and
cancellation do not leave that process running.

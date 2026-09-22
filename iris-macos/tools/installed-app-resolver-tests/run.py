#!/usr/bin/env python3
"""Compile the exact installed-app resolver slice against disposable bundles."""

from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import tempfile
import time


ROOT = pathlib.Path(__file__).resolve().parents[2]
SERVICE = ROOT / "leanring-buddy" / "AppRelaunchService.swift"
COORDINATOR = ROOT / "leanring-buddy" / "OnDemandEditCoordinator.swift"
MANAGER = ROOT / "leanring-buddy" / "CompanionManager.swift"
NATIVE_TESTS = ROOT / "leanring-buddyTests" / "AppRelaunchInstalledDeliveryTests.swift"
TEMPLATE = pathlib.Path(__file__).with_name("main.swift")
RUNNER = pathlib.Path(__file__)
START = "    nonisolated enum DeliveryBundleValidation: Equatable, Sendable {"
END = "    /// Where a pre-delivery snapshot of an installed bundle is kept"


def digest(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    service_text = SERVICE.read_text()
    coordinator_text = COORDINATOR.read_text()
    manager_text = MANAGER.read_text()
    native_tests_text = NATIVE_TESTS.read_text()
    start = service_text.index(START)
    end = service_text.index(END, start)
    production_slice = service_text[start:end]
    template = TEMPLATE.read_text()
    generated = template.replace(
        "// PRODUCTION_RESOLVER_SLICE",
        "@MainActor\nfinal class Resolver {\n" + production_slice + "\n}",
        1,
    )
    if "// PRODUCTION_RESOLVER_SLICE" in generated:
        raise SystemExit("template must contain exactly one production-slice marker")
    coordinator_start = coordinator_text.index("    private var deliveryRejectionReason: String?")
    coordinator_end = coordinator_text.index("    /// The rebuilt app is up.", coordinator_start)
    coordinator_delivery = coordinator_text[coordinator_start:coordinator_end]
    coordinator_contracts = {
        "typed rejection branch": "case .deliveryRejected(let reason):" in coordinator_delivery,
        "rejection clears relaunch artifact": "packagedArtifactPath = nil" in coordinator_delivery,
        "rejection returns no launch path": "return nil" in coordinator_delivery,
        "rejection is surfaced to the user": coordinator_text.count("Nothing was launched.") == 3,
        "all delivery call sites guard the optional path": coordinator_text.count(
            "guard let launchPath = await"
        ) == 2 and coordinator_text.count("guard let launchArtifactPath = await") == 1,
    }
    resolver_input_contracts = {
        "matched running process paths preserve nil bundle URLs":
            "let runningPaths = runningInstances.map { $0.bundleURL?.path }" in service_text,
        "pure resolver accepts optional running paths":
            "runningPaths: [String?]" in service_text,
    }
    adapter_start = manager_text.index("coordinator.deliverEditedAppOverInstalledApp =")
    adapter_end = manager_text.index("coordinator.restoreInstalledAppFromBackup =", adapter_start)
    delivery_adapter = manager_text[adapter_start:adapter_end]
    adapter_contracts = {
        "missing service is rejected": ".deliveryRejected(reason: \"Iris's delivery service is no longer available\")" in delivery_adapter,
        "missing bundle id is rejected": ".deliveryRejected(reason: \"Iris has no bundle identifier for this app\")" in delivery_adapter,
        "missing clone is rejected": ".deliveryRejected(reason: \"Iris has no verified source clone for this app\")" in delivery_adapter,
        "adapter has no fallback result": ".deliveryFailed(" not in delivery_adapter,
    }

    def test_body(name: str) -> str:
        marker = f"    @Test func {name}("
        start = native_tests_text.index(marker)
        next_test = native_tests_text.find("\n    @Test func ", start + len(marker))
        return native_tests_text[start:] if next_test == -1 else native_tests_text[start:next_test]


    blocked_caller_test = test_body(
        "blockedRebuildEntryPointRejectsWithoutRelaunchAndAllowsSuccessfulControl"
    )
    automatic_caller_test = test_body(
        "automaticDeliveryCallerRejectsWithoutRelaunchAndAllowsSuccessfulControl"
    )

    def caller_contracts(test: str, *, automatic: bool) -> dict[str, bool]:
        automatic_argument = ",\n            automaticallyApplyEdit: true" in test
        return {
            "rejects delivery": '.deliveryRejected(reason: "the fixture was not an eligible delivery target")' in test,
            "observes the attempted delivery": "#expect(rejected.deliveryCallCount == 1)" in test,
            "does not relaunch after rejection": "#expect(rejected.relaunchCalls.isEmpty)" in test,
            "success control approves fallback launch": "deliveryResult: .noInstalledCopyToReplace" in test,
            "success control uses the intended caller path": automatic_argument if automatic else not automatic_argument,
            "success control observes the attempted delivery": "#expect(successful.deliveryCallCount == 1)" in test,
            "success control reaches relaunch": "#expect(successful.relaunchCalls.count == 1)" in test,
            "success callback preserves target and path": (
                '#expect(successful.relaunchCalls.first?.appSlug == "resolver-fixture")' in test
                and "#expect(successful.relaunchCalls.first?.path == successful.artifactPath)" in test
            ),
            "success callback preserves force-quit policy": "#expect(successful.relaunchCalls.first?.allowForceQuit == false)" in test,
        }

    public_caller_contracts = {
        f"blocked rebuild {name}": passed
        for name, passed in caller_contracts(blocked_caller_test, automatic=False).items()
    }
    public_caller_contracts.update({
        f"automatic delivery {name}": passed
        for name, passed in caller_contracts(automatic_caller_test, automatic=True).items()
    })
    native_test_contracts = {
        "blocked-rebuild public caller regression is present": bool(blocked_caller_test),
        "automatic-delivery public caller regression is present": bool(automatic_caller_test),
    }
    if (not all(coordinator_contracts.values()) or not all(adapter_contracts.values())
            or not all(native_test_contracts.values()) or not all(public_caller_contracts.values())
            or not all(resolver_input_contracts.values())):
        raise SystemExit(
            "fail-closed source contract is incomplete: "
            + repr({**coordinator_contracts, **adapter_contracts, **native_test_contracts,
                    **public_caller_contracts, **resolver_input_contracts})
        )

    manifest = {
        "created_at_unix": int(time.time()),
        "base": subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True
        ).strip(),
        "inputs": {
            str(path.relative_to(ROOT)): digest(path)
            for path in (SERVICE, COORDINATOR, MANAGER, NATIVE_TESTS, TEMPLATE, RUNNER)
        },
        "extracted_range": {
            "start": START.strip(),
            "end_exclusive": END.strip(),
            "sha256": hashlib.sha256(production_slice.encode()).hexdigest(),
        },
    }

    with tempfile.TemporaryDirectory(prefix="iris-installed-resolver-") as directory:
        source = pathlib.Path(directory) / "main.swift"
        executable = pathlib.Path(directory) / "resolver-tests"
        source.write_text(generated)
        subprocess.run(
            ["swiftc", "-swift-version", "5", "-parse-as-library", str(source), "-o", str(executable)],
            check=True,
        )
        subprocess.run([str(executable)], check=True)
    print("SOURCE_MANIFEST=" + json.dumps(manifest, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Run actual Host-state sources without an iOS UI/runtime.

Only the supported-platform constant is supplied by this harness. The complete
NativeShellAppModel, signature store/resolver/scope check and Core sources are
source-linked unchanged. This is not a simulator, WebKit or native-product run.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys


def main() -> int:
    repo = Path(__file__).resolve().parents[4]
    native = repo / "mobile-shell/native"
    if len(sys.argv) > 2:
        raise RuntimeError("Expected at most one new evidence-directory label")
    label = sys.argv[1] if len(sys.argv) == 2 else "host-model-run-1"
    if not re.fullmatch(r"[a-z0-9-]{1,60}", label):
        raise RuntimeError("Evidence label must be a simple local directory name")
    output = repo / "outputs/iris_kneecap_user_test_20260916/seamless_mobile_20260918/resumed_20260918/core-acceptance/api-install-binding-20260919" / label
    if output.exists():
        raise RuntimeError("Preserve existing evidence; select a new output for a corrected run.")
    output.mkdir(parents=True)
    model_path = native / "Sources/IrisMobileShellHost/NativeShellAppView.swift"
    scripts_path = native / "Sources/IrisMobileShellHost/IrisPackagedAPIHostScripts.swift"
    tests_path = native / "IrisMobileShellApp/Tests/VerifiedRevisionWebViewLifecycleDeepAcceptanceTests.swift"
    model_text = model_path.read_text()
    assert model_text.count("public struct NativeShellAppView: View") == 1
    model = model_text.split("public struct NativeShellAppView: View", 1)[0]
    model = model.replace("#if os(iOS)\n", "", 1).replace("import IrisMobileShellCore\n", "", 1)
    (output / "ActualNativeShellAppModel.swift").write_text(model)
    scripts = scripts_path.read_text()
    preamble = scripts.split("@MainActor\nenum IrisPackagedAPIHostScripts", 1)[0]
    preamble = preamble.replace("#if os(iOS)\n", "", 1).replace("import IrisMobileShellCore\n", "", 1).replace("import WebKit\n", "", 1)
    scope = scripts[scripts.index("    static func validateScope("):scripts.index("    static func install(")]
    support = preamble + "\n@MainActor enum IrisPackagedAPIHostScripts {\n" + scope + "}\n"
    support += "public enum NativeShellWebLoadResult: Equatable, Sendable { case loaded, failed }\n"
    support += "enum VerifiedRevisionWebView { static let supportsFailClosedMediaBoundary = true; static let unsupportedRuntimeMessage = \"Unsupported platform fixture\" }\n"
    (output / "ActualConfigurationAndPlatformInput.swift").write_text(support)
    tests = tests_path.read_text()
    fixture = tests.split("private struct SignedAPITestFixture {", 1)[1].split("\n@MainActor\nprivate final class PackagedAdapterHostedView", 1)[0]
    entry = Path(__file__).with_name("main.swift").read_text() + "\nprivate struct SignedAPITestFixture {" + fixture
    (output / "main.swift").write_text(entry)
    sources = sorted((native / "Sources/IrisMobileShellCore").glob("*.swift"))
    hashes = {str(path.relative_to(repo)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources + [model_path, scripts_path, tests_path]}
    binary = output / "host-model-checks"
    command = ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-whole-module-optimization", "-swift-version", "5", "-target", "arm64-apple-macos14.2", "-Onone", "-num-threads", "1", *map(str, sources), str(output / "ActualNativeShellAppModel.swift"), str(output / "ActualConfigurationAndPlatformInput.swift"), str(output / "main.swift"), "-o", str(binary)]
    with (output / "compile.log").open("x") as log:
        compiled = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=120)
    print("Compile exit", compiled.returncode, flush=True)
    if compiled.returncode:
        print((output / "compile.log").read_text()[-12000:])
        return compiled.returncode
    for relative, expected in hashes.items():
        if hashlib.sha256((repo / relative).read_bytes()).hexdigest() != expected:
            raise RuntimeError("Source changed while compiling: " + relative)
    with (output / "runtime.log").open("x") as log:
        result = subprocess.run([str(binary), str(repo)], stdout=log, stderr=subprocess.STDOUT, timeout=90)
    print((output / "runtime.log").read_text(), flush=True)
    (output / "RESULT.json").write_text(json.dumps({"compileExit": compiled.returncode, "runtimeExit": result.returncode, "sourceSHA256": hashes, "scope": __doc__, "lastActualIOSHostedCount": 32}, indent=2) + "\n")
    return result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(2)

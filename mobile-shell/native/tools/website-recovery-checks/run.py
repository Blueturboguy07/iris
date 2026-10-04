#!/usr/bin/env python3
"""Source-link actual mobile Core/Host recovery scenarios, without WebKit or network.

The iOS hosted tests call the same scenarios. Only the supported-runtime constant
and WebKit result enum are supplied here; model/flow/store/approval code is actual
source. Each run keeps its original sources, compile log and runtime evidence.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys


def main() -> int:
    repo = Path(__file__).resolve().parents[4]
    if len(sys.argv) not in (2, 3) or not re.fullmatch(r"[a-z0-9-]{1,60}", sys.argv[1]):
        raise RuntimeError("Supply one fresh evidence label and an optional named offline mutant")
    mutation = sys.argv[2] if len(sys.argv) == 3 else None
    mutations = {
        "drop-website-approval": ("NativeWebsiteInstallFlow.swift",
            "source: .installed(alreadyStaged: activated.alreadyStaged), launch: launch))",
            "source: .alreadyInstalled, launch: launch))"),
        "ignore-selection-epoch": ("NativeShellLibraryCoordinator.swift",
            "selectionIDs[identity] == selection.selectionID else {", "true else {"),
        "renew-review-consent": ("NativeWebsiteInstallFlow.swift",
            "recordUsage(.reviewOutcome(outcome), binding: binding)",
            "recordUsage(.reviewOutcome(outcome), binding: binding.flatMap { usageService?.binding(for: $0.identity) })"),
        "hide-open-retry": ("NativeShellAppView.swift",
            "let binding = beginUsage(.openRequest, identity: identity)\n        run(\n            retry: .open(identity),",
            "let binding = beginUsage(.openRequest, identity: identity)\n        run(\n            retry: nil,"),
    }
    if mutation is not None and mutation not in mutations:
        raise RuntimeError("Unknown mutation; production files are never modified")
    out = repo / "outputs/iris_kneecap_user_test_20260916/seamless_mobile_20260918/resumed_20260918/core-acceptance/mobile-only-20260920" / sys.argv[1]
    if out.exists():
        raise RuntimeError("Existing evidence is immutable; inspect it instead of overwriting")
    out.mkdir(parents=True)
    native = repo / "mobile-shell/native"
    sources = sorted((native / "Sources/IrisMobileShellCore").glob("*.swift"))
    host = native / "Sources/IrisMobileShellHost"
    model_path = host / "NativeShellAppView.swift"
    website_path = host / "NativeShellWebsiteInstallView.swift"
    scripts_path = host / "IrisPackagedAPIHostScripts.swift"
    tests_path = native / "IrisMobileShellApp/Tests/VerifiedRevisionWebViewLifecycleDeepAcceptanceTests.swift"
    inputs = sources + [model_path, website_path, scripts_path, tests_path, Path(__file__)]
    hashes = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    copied = []
    mutated_path = None
    for path in inputs:
        destination = out / "input-source" / path.relative_to(repo)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(path.read_bytes())
        if mutation and path.name == mutations[mutation][0]:
            original, replacement = mutations[mutation][1:]
            text = destination.read_text()
            if text.count(original) != 1:
                raise RuntimeError("Mutation no longer matches exactly one production location")
            destination.write_text(text.replace(original, replacement))
            mutated_path = destination
    compilation_sources = [mutated_path if mutated_path and p.name == mutated_path.name else p for p in sources]
    for path, boundary in ((model_path, "public struct NativeShellAppView: View"),
                           (website_path, "struct NativeShellWebsiteInstallView: View")):
        text = (mutated_path if mutated_path and path.name == mutated_path.name else path).read_text()
        assert text.count(boundary) == 1
        text = text.split(boundary)[0].replace("#if os(iOS)\n", "", 1).replace("import IrisMobileShellCore\n", "", 1)
        destination = out / path.name
        destination.write_text(text)
        copied.append(destination)
    scripts = scripts_path.read_text()
    prefix = scripts.split("@MainActor\nenum IrisPackagedAPIHostScripts", 1)[0]
    prefix = prefix.replace("#if os(iOS)\n", "", 1).replace("import IrisMobileShellCore\n", "", 1).replace("import WebKit\n", "", 1)
    scope = scripts[scripts.index("    static func validateScope("):scripts.index("    static func install(")]
    support = out / "ActualAPIScopeAndRuntimeInput.swift"
    support.write_text(prefix + "\n@MainActor enum IrisPackagedAPIHostScripts {\n" + scope + "}\n"
                       + "public enum NativeShellWebLoadResult: Equatable, Sendable { case loaded, failed }\n"
                       + "enum VerifiedRevisionWebView { static let supportsFailClosedMediaBoundary = true; static let unsupportedRuntimeMessage = \"Unsupported runtime\" }\n")
    tests = tests_path.read_text()
    scenarios = tests.split("// BEGIN_MOBILE_WEBSITE_RECOVERY_SCENARIOS\n", 1)[1].split("// END_MOBILE_WEBSITE_RECOVERY_SCENARIOS", 1)[0]
    signer = "private struct SignedAPITestFixture {" + tests.split("private struct SignedAPITestFixture {", 1)[1].split("\n@MainActor\nprivate final class PackagedAdapterHostedView", 1)[0]
    entry = out / "main.swift"
    entry.write_text("import Foundation\nimport CryptoKit\n" + scenarios + "\n" + signer + '''
@main @MainActor struct RecoveryChecks {
    static func main() async {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let resource = URL(fileURLWithPath: CommandLine.arguments[2])
        var failed = 0
        for (name, scenario) in MobileWebsiteRecoveryScenarios.cases {
            do {
                let fixture = try MobileWebsiteRecoveryFixture(root: root.appendingPathComponent(name),
                    initial: Data(contentsOf: resource.appendingPathComponent("SafeDemo.irisapp")),
                    update: Data(contentsOf: resource.appendingPathComponent("SafeDemoUpdate.irisapp")))
                try await scenario(fixture)
                print("PASS " + name)
            } catch { failed += 1; print("FAIL " + name + ": " + String(describing: error)) }
        }
        print("Scenarios: \\(MobileWebsiteRecoveryScenarios.cases.count - failed)/\\(MobileWebsiteRecoveryScenarios.cases.count); actual Core/Host, no WebKit/provider/network")
        exit(failed == 0 ? 0 : 1)
    }
}
''')
    command = ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-whole-module-optimization", "-swift-version", "5",
               "-target", "arm64-apple-macos14.2", "-Onone", "-num-threads", "1", *map(str, compilation_sources),
               *map(str, copied), str(support), str(entry), "-o", str(out / "recovery-checks")]
    receipt = {"scope": __doc__, "sourceSHA256": hashes, "mutation": mutation,
               "mutantSHA256": hashlib.sha256(mutated_path.read_bytes()).hexdigest() if mutated_path else None}
    with (out / "compile.log").open("x") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=150)
    receipt["compileExit"] = result.returncode
    print("Compile exit", result.returncode, flush=True)
    if result.returncode:
        print((out / "compile.log").read_text()[-15000:])
    else:
        if any(hashlib.sha256((repo / p).read_bytes()).hexdigest() != h for p, h in hashes.items()):
            raise RuntimeError("Source changed during compilation")
        with (out / "runtime.log").open("x") as log:
            result = subprocess.run([str(out / "recovery-checks"), str(out / "fixtures"),
                                     str(native / "IrisMobileShellApp/Resources")], stdout=log, stderr=subprocess.STDOUT, timeout=100)
        receipt["runtimeExit"] = result.returncode
        print((out / "runtime.log").read_text(), flush=True)
    (out / "RESULT.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        sys.exit(2)

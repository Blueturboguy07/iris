#!/usr/bin/env bash
# check-debug-only-fixtures.sh - the UI-test fixtures must not exist in Release
# (round 6, MA2 hook 5; complements release-hygiene.sh, which only looks for a
# fixed list of forbidden strings and would not notice a fixture that lost its guard).
#
# Rule: every Swift file under Sources/ whose name contains "UITestFixtures" or
# "UITestSeed" must be wrapped whole in one `#if DEBUG ... #endif`: its first line of
# code (after comments, blank lines and imports) is exactly `#if DEBUG`, the
# matching `#endif` is the last line of code, and no `#else` or `#elseif` sits at
# that outer level (an `#else` branch would compile into Release).
#
# Usage: check-debug-only-fixtures.sh [--root DIR]  (default: mobile-shell/native)
# Exit 0 pass, 1 findings ("FAIL path - reason"), 2 usage.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
while [ $# -gt 0 ]; do case "$1" in --root) ROOT="$(cd "$2" && pwd)"; shift 2 ;; *) echo "usage: check-debug-only-fixtures.sh [--root DIR]" >&2; exit 2 ;; esac; done
python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
found, findings = 0, []
for base, _, files in os.walk(os.path.join(root, "Sources")):
    for name in sorted(files):
        if not name.endswith(".swift") or not re.search(r"UITestFixtures|UITestSeed", name):
            continue
        found += 1
        path = os.path.join(base, name); rel = os.path.relpath(path, root)
        code = []
        in_block = False
        for raw in open(path, encoding="utf-8", errors="replace"):
            line = raw.strip()
            if in_block:
                if "*/" in line: in_block = False
                continue
            if line.startswith("/*"):
                if "*/" not in line: in_block = True
                continue
            if not line or line.startswith("//") or line.startswith("import "):
                continue
            code.append(line)
        if not code or code[0] != "#if DEBUG":
            findings.append(f"FAIL {rel} - the first line of code is not `#if DEBUG` (the fixture would compile into Release)")
            continue
        depth = 0; closed_at = None
        for i, line in enumerate(code):
            if re.match(r"#if\b", line): depth += 1
            elif re.match(r"#endif\b", line):
                depth -= 1
                if depth == 0 and closed_at is None: closed_at = i
            elif depth == 1 and re.match(r"#(else|elseif)\b", line):
                findings.append(f"FAIL {rel} - an `{line}` at the outer level compiles a branch into Release")
        if closed_at != len(code) - 1:
            findings.append(f"FAIL {rel} - code after the closing `#endif` of the outer `#if DEBUG` (that code compiles into Release)")
if found == 0:
    findings.append("FAIL Sources - no UITestFixtures or UITestSeed file found to check")
for f in findings: print(f)
if findings: sys.exit(1)
print(f"PASS {found} fixture file(s) are wrapped whole in #if DEBUG")
PY

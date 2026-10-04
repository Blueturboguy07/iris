#!/usr/bin/env bash
# check-deployment-target.sh - RC-10 gate: the deployment target is honest
# for what the shell says it needs (apple-compliance/REQUIRED_CHANGES.md, RC-10).
#
# The shell tells people, in plain words, "requires iOS 18.4 or later" when it
# refuses to open an app on an older phone (VerifiedRevisionWebView's
# unsupportedRuntimeMessage). If the project still installs on iOS 16 and 17,
# that promise is a lie for anyone with an older phone: the App Store listing
# offers Iris to them and the bundled starters cannot open. This script fails
# when any deployment target is lower than the highest iOS version the
# sources say they require.
#
# Checks (all must be >= the required version):
#   - every IPHONEOS_DEPLOYMENT_TARGET in project.pbxproj (app, acceptance
#     tests and UI tests, both configurations, and the project level)
#   - every IPHONEOS_DEPLOYMENT_TARGET in a *.xcconfig next to the project
#   - the .iOS(...) entry in Package.swift `platforms`
#
# The required version is the highest "requires iOS N or later" (or N.M) named
# in a .swift file under Sources/ that is not a test file.
#
# Usage: check-deployment-target.sh [--root DIR]   (default: mobile-shell/native)
# Exit: 0 pass, 1 findings (printed as "FAIL file:line - message"), 2 usage.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    *) echo "usage: check-deployment-target.sh [--root DIR]" >&2; exit 2 ;;
  esac
done
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }

python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]

def ver(text):
    parts = text.split(".")
    return tuple(int(p) for p in (parts + ["0", "0"])[:3])

def fmt(v):
    v = list(v)
    while len(v) > 1 and v[-1] == 0:
        v.pop()
    return ".".join(str(x) for x in v)

required = (0, 0, 0)
required_src = None
pat = re.compile(r"requires iOS (\d+(?:\.\d+)?) or later")
for base, dirs, files in os.walk(os.path.join(root, "Sources")):
    for name in files:
        if not name.endswith(".swift") or name.endswith("Tests.swift"):
            continue
        path = os.path.join(base, name)
        for n, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
            for m in pat.finditer(line):
                if ver(m.group(1)) > required:
                    required, required_src = ver(m.group(1)), f"{os.path.relpath(path, root)}:{n}"

findings = []
if required == (0, 0, 0):
    print("FAIL Sources - no 'requires iOS N or later' message found, so the honest minimum cannot be worked out")
    sys.exit(1)

def check(path, n, value, what):
    if ver(value) < required:
        findings.append(f"FAIL {os.path.relpath(path, root)}:{n} - {what} is {value}, but the app says it requires iOS {fmt(required)} or later ({required_src})")

seen = 0
app_dir = os.path.join(root, "IrisMobileShellApp")
for base, dirs, files in os.walk(app_dir):
    dirs[:] = [d for d in dirs if d not in ("Resources", "build", "DerivedData")]
    for name in files:
        path = os.path.join(base, name)
        if name == "project.pbxproj" or name.endswith(".xcconfig"):
            for n, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
                for m in re.finditer(r"IPHONEOS_DEPLOYMENT_TARGET\s*=\s*\"?(\d+(?:\.\d+)*)\"?", line):
                    seen += 1
                    check(path, n, m.group(1), "IPHONEOS_DEPLOYMENT_TARGET")
if seen == 0:
    findings.append("FAIL IrisMobileShellApp - no IPHONEOS_DEPLOYMENT_TARGET found in the project or xcconfig files")

pkg = os.path.join(root, "Package.swift")
if os.path.exists(pkg):
    for n, line in enumerate(open(pkg), 1):
        m = re.search(r"\.iOS\(\s*(?:\"(\d+(?:\.\d+)*)\"|\.v(\d+)(?:_(\d+))?)\s*\)", line)
        if m:
            value = m.group(1) or (m.group(2) + ("." + m.group(3) if m.group(3) else ""))
            check(pkg, n, value, "Package.swift .iOS platform")
            seen += 1
else:
    findings.append("FAIL Package.swift - not found")

for f in findings:
    print(f)
if findings:
    sys.exit(1)
print(f"PASS deployment targets ({seen} checked) are all at or above the required iOS {fmt(required)} ({required_src})")
PY

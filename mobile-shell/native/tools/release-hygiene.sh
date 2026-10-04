#!/usr/bin/env bash
# release-hygiene.sh - Apple release-hygiene gate for the Iris Apps iOS
# shell (RC-08, apple-compliance/REQUIRED_CHANGES.md).
#
# Exits 1 and prints every finding as "FAIL path:line - message" if:
#
#   1. The Release build configuration of the app target has DEBUG in
#      SWIFT_ACTIVE_COMPILATION_CONDITIONS, or any non-empty
#      GCC_PREPROCESSOR_DEFINITIONS (checked in the merged project.pbxproj
#      build settings and, if present, the referenced .xcconfig file).
#
#   2. WKScriptMessageHandler, a user-content-controller add(_:name:) call,
#      "isInspectable = true", the string "Import local package" or the
#      string "Review demo" appear in a .swift file outside an #if DEBUG
#      region. A small nested #if/#elseif/#else/#endif region parser
#      decides what is DEBUG-only; only an exact "#if DEBUG" (or an
#      "#elseif DEBUG") branch counts as DEBUG-only, matching the pattern
#      used throughout this codebase. Matching is done against each file's
#      full text (not line by line), so a call or assignment wrapped across
#      several lines is still caught. Test files are skipped (path has a
#      "/Tests/" or "*UITests/" ancestor directory, or the filename ends
#      "Tests.swift"). A production file is never skipped just because its
#      name contains "fixture": a file that is genuinely DEBUG-only (for
#      example, one that generates fixtures for XCUITest) is instead
#      recognized because its content sits inside its own #if DEBUG region.
#
#   3. UIFileSharingEnabled is true in the Info.plist the Release build
#      configuration's INFOPLIST_FILE points to.
#
#   4. Any http:// URL, or an https host other than publikhq.com or
#      apple.com (or one of their subdomains), appears in a .swift file
#      outside an #if DEBUG region. Same test-file exclusion and the same
#      #if DEBUG gating as rule 2: this is what "shipped .swift file" means
#      here, and it keeps a DEBUG-only fixture file's test-only hosts from
#      being flagged as if they shipped.
#
# Usage:
#   release-hygiene.sh [--root DIR] [--project PATH/project.pbxproj] [--app-target NAME]
#
#   --root DIR          Tree to scan for .swift sources and to auto-discover
#                        a project.pbxproj under, if --project is not given.
#                        Default: this script's ../.. (mobile-shell/native).
#   --project PATH       project.pbxproj to check. Default: the first
#                        *.xcodeproj/project.pbxproj found under --root.
#   --app-target NAME    PBXNativeTarget name whose Release configuration is
#                        checked. Default: IrisMobileShellApp.
#
# Exit codes: 0 = no findings. 1 = one or more findings (printed on stdout).
# 2 = usage error or a required tool (plutil, python3) is missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT=""
APP_TARGET="IrisMobileShellApp"

usage() {
  sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || { echo "release-hygiene.sh: --root needs a value" >&2; exit 2; }
      ROOT="$2"; shift 2 ;;
    --project)
      [ $# -ge 2 ] || { echo "release-hygiene.sh: --project needs a value" >&2; exit 2; }
      PROJECT="$2"; shift 2 ;;
    --app-target)
      [ $# -ge 2 ] || { echo "release-hygiene.sh: --app-target needs a value" >&2; exit 2; }
      APP_TARGET="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "release-hygiene.sh: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [ ! -d "$ROOT" ]; then
  echo "release-hygiene.sh: --root directory does not exist: $ROOT" >&2
  exit 2
fi
ROOT="$(cd "$ROOT" && pwd)"

if ! command -v plutil >/dev/null 2>&1; then
  echo "release-hygiene.sh: requires plutil (macOS)" >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "release-hygiene.sh: requires python3" >&2
  exit 2
fi

if [ -z "$PROJECT" ]; then
  # Prefer the well-known real layouts before falling back to a recursive
  # search, so this tool's own fixture trees under tools/release-hygiene-
  # tests/ (deliberately fake .xcodeproj bundles, used to test each rule in
  # isolation) never shadow the real app project when --root is the whole
  # mobile-shell/native tree. tools/ is a dev-only directory (scripts,
  # benchmarks, checkers, this tool's own tests) and never holds the
  # shipped app's Xcode project, so the recursive fallback excludes it too.
  if [ -f "$ROOT/IrisMobileShellApp/$APP_TARGET.xcodeproj/project.pbxproj" ]; then
    PROJECT="$ROOT/IrisMobileShellApp/$APP_TARGET.xcodeproj/project.pbxproj"
  else
    FOUND_XCODEPROJ="$(find "$ROOT" -maxdepth 1 -type d -name '*.xcodeproj' -print -quit 2>/dev/null || true)"
    if [ -z "$FOUND_XCODEPROJ" ]; then
      FOUND_XCODEPROJ="$(find "$ROOT" -type d -name '*.xcodeproj' \
        -not -path '*/.build/*' \
        -not -path "$ROOT/tools/*" \
        -print -quit 2>/dev/null || true)"
    fi
    if [ -n "$FOUND_XCODEPROJ" ]; then
      PROJECT="$FOUND_XCODEPROJ/project.pbxproj"
    fi
  fi
fi

python3 - "$ROOT" "$PROJECT" "$APP_TARGET" <<'PYEOF'
import bisect
import json
import os
import re
import subprocess
import sys

root, project_pbxproj, app_target = sys.argv[1], sys.argv[2], sys.argv[3]

findings = []  # list of (location, message)


# ---------------------------------------------------------------------------
# Rule 1 & 2: Release build settings of the app target (project.pbxproj +
# its referenced .xcconfig), and rule 3's plist resolution.
# ---------------------------------------------------------------------------

def load_pbxproj_as_json(path):
    proc = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", path],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return None, proc.stderr.strip()
    try:
        return json.loads(proc.stdout), None
    except json.JSONDecodeError as exc:
        return None, str(exc)


def parse_xcconfig(path):
    settings = {}
    if not os.path.isfile(path):
        return settings
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("//"):
                continue
            m = re.match(r'^([A-Za-z0-9_\[\]=$().\-]+)\s*=\s*(.*?);?\s*$', line)
            if m:
                key = m.group(1).split("[")[0]
                settings[key] = m.group(2).strip().strip('"')
    return settings


release_plist_path = None

if project_pbxproj and os.path.isfile(project_pbxproj):
    data, err = load_pbxproj_as_json(project_pbxproj)
    if data is None:
        findings.append((project_pbxproj, f"could not parse project.pbxproj ({err})"))
    else:
        objects = data.get("objects", {})
        xcodeproj_dir = os.path.dirname(project_pbxproj)
        source_root = os.path.dirname(xcodeproj_dir)

        target_obj = None
        for obj in objects.values():
            if isinstance(obj, dict) and obj.get("isa") == "PBXNativeTarget" and obj.get("name") == app_target:
                target_obj = obj
                break

        if target_obj is None:
            findings.append((project_pbxproj, f"no PBXNativeTarget named '{app_target}' found"))
        else:
            cfg_list = objects.get(target_obj.get("buildConfigurationList"), {})
            release_cfg = None
            for cfg_id in cfg_list.get("buildConfigurations", []):
                cfg = objects.get(cfg_id, {})
                if cfg.get("name") == "Release":
                    release_cfg = cfg
                    break

            if release_cfg is None:
                findings.append((project_pbxproj, f"no Release build configuration for target '{app_target}'"))
            else:
                merged = dict(release_cfg.get("buildSettings", {}) or {})

                xcconfig_path = None
                base_ref = release_cfg.get("baseConfigurationReference")
                if base_ref:
                    file_ref = objects.get(base_ref, {})
                    rel_path = file_ref.get("path")
                    if rel_path:
                        candidate = os.path.normpath(os.path.join(source_root, rel_path))
                        if not os.path.isfile(candidate):
                            candidate = os.path.normpath(os.path.join(xcodeproj_dir, rel_path))
                        if os.path.isfile(candidate):
                            xcconfig_path = candidate
                            for k, v in parse_xcconfig(candidate).items():
                                merged.setdefault(k, v)

                settings_location = xcconfig_path or project_pbxproj

                sacc = str(merged.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""))
                tokens = re.split(r"\s+", sacc.strip('"'))
                if "DEBUG" in tokens:
                    findings.append((
                        settings_location,
                        f"Release SWIFT_ACTIVE_COMPILATION_CONDITIONS for target '{app_target}' "
                        f"contains DEBUG: {sacc!r}",
                    ))

                for key, value in merged.items():
                    if key == "GCC_PREPROCESSOR_DEFINITIONS" or key.startswith("GCC_PREPROCESSOR_DEFINITIONS["):
                        value_str = str(value).strip('"').strip()
                        if value_str and value_str != "$(inherited)":
                            findings.append((
                                settings_location,
                                f"Release {key} for target '{app_target}' is set: {value!r}",
                            ))

                infoplist_rel = merged.get("INFOPLIST_FILE")
                if infoplist_rel:
                    candidate = os.path.normpath(os.path.join(source_root, infoplist_rel))
                    if os.path.isfile(candidate):
                        release_plist_path = candidate
elif project_pbxproj:
    # An explicit --project (or an auto-discovered path) that does not
    # exist is a real configuration problem, not just "nothing to check".
    findings.append((project_pbxproj, "project.pbxproj not found"))
else:
    # No .xcodeproj anywhere under --root: rules 1-3 (build settings and
    # the Release plist) have nothing to check against. This is expected
    # for a --root scoped to plain .swift sources (see release-hygiene-
    # tests/fixtures/r3, r5, r6), so it is not itself a finding, only a
    # note on stderr.
    print(
        "release-hygiene: note: no project.pbxproj found under --root; "
        "rules 1-3 (Release build settings and Info.plist) were skipped",
        file=sys.stderr,
    )


# ---------------------------------------------------------------------------
# Rule 3: UIFileSharingEnabled in the Release Info.plist.
# ---------------------------------------------------------------------------

if release_plist_path:
    proc = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", release_plist_path],
        capture_output=True, text=True,
    )
    if proc.returncode == 0:
        try:
            plist = json.loads(proc.stdout)
        except json.JSONDecodeError:
            plist = {}
        if plist.get("UIFileSharingEnabled") is True:
            findings.append((release_plist_path, "UIFileSharingEnabled is true in the Release Info.plist"))


# ---------------------------------------------------------------------------
# Rule 2 (symbols) and rule 4 (hosts): walk .swift sources.
# ---------------------------------------------------------------------------

EXCLUDE_DIR_NAMES = {".build", ".git", ".swiftpm", "DerivedData"}


def is_test_or_fixture_dir(name):
    # Deliberately narrow: only directories that are structurally an XCTest
    # target (an exact "Tests" folder, or one ending "UITests") are
    # excluded. A directory or filename merely containing "fixture" is NOT
    # excluded here: real shipped code under Sources/ can legitimately have
    # "Fixture" in its name (see NativeUITestFixtures.swift, whose content
    # is DEBUG-only fixture *generation* code used by the real UITests
    # target, but which is not itself under a Tests/ directory). Excluding
    # it by filename would blind every rule below to that file; excluding
    # it by #if DEBUG (which the region parser already understands) does
    # not, and is what actually decides whether the code ships.
    lower = name.lower()
    return lower == "tests" or lower.endswith("uitests")


def iter_swift_files(base):
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [
            d for d in dirnames
            if d not in EXCLUDE_DIR_NAMES
            and not d.endswith(".xcodeproj")
            and not is_test_or_fixture_dir(d)
        ]
        for fn in filenames:
            if fn.endswith(".swift"):
                yield os.path.join(dirpath, fn)


def is_test_or_fixture(rel_path):
    lower = rel_path.lower()
    parts = lower.split(os.sep)
    if any(is_test_or_fixture_dir(p) for p in parts[:-1]):
        return True
    base = parts[-1]
    if base.endswith("tests.swift"):
        return True
    return False


# Known shipped-source roots to scan (relative to --root): the SwiftPM
# package sources and the app target's own directory, but not its Tests/
# IrisMobileShellUITests subfolders (excluded by iter_swift_files above),
# not its .xcodeproj, and not this tool's own tools/ directory (dev
# scripts, benchmarks, checkers and this tool's fixtures are never
# compiled into the shipped app).
_DEFAULT_SCAN_SUBDIRS = ("Sources", "IrisMobileShellApp")


def scan_roots(base):
    found = [os.path.join(base, d) for d in _DEFAULT_SCAN_SUBDIRS if os.path.isdir(os.path.join(base, d))]
    return found or [base]


SYMBOL_PATTERNS = [
    (re.compile(r"\bWKScriptMessageHandler\b"), "WKScriptMessageHandler"),
    (re.compile(r"\.add\([^)]*\bname\s*:"), "a user-content-controller add(_:name:) call"),
    (re.compile(r"\bisInspectable\s*=\s*true\b"), "isInspectable = true"),
    (re.compile(r'"Import local package"'), '"Import local package"'),
    (re.compile(r'"Review demo"'), '"Review demo"'),
]

IF_RE = re.compile(r"^\s*#if\s+(.*)$")
ELSEIF_RE = re.compile(r"^\s*#elseif\s+(.*)$")
ELSE_RE = re.compile(r"^\s*#else\b")
ENDIF_RE = re.compile(r"^\s*#endif\b")

URL_RE = re.compile(r"\b(https?)://([A-Za-z0-9.\-]+)")
ALLOWED_HOST_SUFFIXES = ("publikhq.com", "apple.com")


def is_debug_only_condition(cond):
    # Only an exact "DEBUG" condition (ignoring whitespace and a single
    # pair of wrapping parens) counts. Compound conditions such as
    # "DEBUG && os(iOS)" are intentionally NOT treated as DEBUG-only: this
    # keeps the parser simple and matches every #if DEBUG in this codebase.
    c = re.sub(r"\s+", "", cond)
    if c.startswith("(") and c.endswith(")"):
        c = c[1:-1]
    return c == "DEBUG"


def debug_gated_line_mask(lines):
    """Return a list[bool], True where that line is unreachable in a
    non-DEBUG (Release) build because some enclosing #if/#elseif branch is
    an exact `DEBUG` condition. Handles nesting and #else/#elseif."""
    stack = []  # each entry: {"debug_only": bool}
    mask = [False] * len(lines)
    for i, raw in enumerate(lines):
        stripped = raw.strip()
        m = IF_RE.match(stripped)
        if m:
            stack.append({"debug_only": is_debug_only_condition(m.group(1))})
            continue
        m = ELSEIF_RE.match(stripped)
        if m:
            if stack:
                stack[-1]["debug_only"] = is_debug_only_condition(m.group(1))
            continue
        if ELSE_RE.match(stripped):
            if stack:
                # The #else branch of "#if DEBUG" runs precisely when DEBUG
                # is NOT defined, i.e. in Release: never DEBUG-only.
                stack[-1]["debug_only"] = False
            continue
        if ENDIF_RE.match(stripped):
            if stack:
                stack.pop()
            continue
        mask[i] = any(frame["debug_only"] for frame in stack)
    return mask


def host_allowed(host):
    host = host.lower().rstrip(".")
    return any(host == suf or host.endswith("." + suf) for suf in ALLOWED_HOST_SUFFIXES)


for scan_root in scan_roots(root):
    for path in iter_swift_files(scan_root):
        rel = os.path.relpath(path, root)
        if is_test_or_fixture(rel):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
        except OSError as exc:
            findings.append((rel, f"could not read file ({exc})"))
            continue

        gated = debug_gated_line_mask(lines)

        # Match against the file's full text, not line by line: a
        # user-content-controller `.add(...)` call or an
        # `isInspectable =\n    true` assignment is routinely wrapped
        # across several lines by normal Swift formatting, and a per-line
        # regex never sees the whole statement. `[^)]*` and `\s*` in
        # SYMBOL_PATTERNS already match across newlines (they are not `.`,
        # so DOTALL is not needed); what per-line scanning was missing was
        # simply seeing more than one line at a time.
        text = "".join(lines)
        line_offsets = [0]
        for raw in lines:
            line_offsets.append(line_offsets[-1] + len(raw))

        def line_for_offset(offset):
            return bisect.bisect_right(line_offsets, offset) - 1

        for pattern, label in SYMBOL_PATTERNS:
            for m in pattern.finditer(text):
                i = line_for_offset(m.start())
                if not gated[i]:
                    findings.append((f"{rel}:{i + 1}", f"{label} appears outside an #if DEBUG region"))

        for m in URL_RE.finditer(text):
            i = line_for_offset(m.start())
            if gated[i]:
                continue
            scheme, host = m.group(1), m.group(2)
            if scheme == "http":
                findings.append((f"{rel}:{i + 1}", f"http:// URL in shipped source (host: {host})"))
            elif not host_allowed(host):
                findings.append((f"{rel}:{i + 1}", f"disallowed host '{host}' in shipped source"))


# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------

if not findings:
    print("release-hygiene: PASS (0 findings)")
    sys.exit(0)

for loc, msg in sorted(findings, key=lambda pair: pair[0]):
    print(f"FAIL {loc} - {msg}")
print(f"release-hygiene: FAIL ({len(findings)} finding(s))")
sys.exit(1)
PYEOF

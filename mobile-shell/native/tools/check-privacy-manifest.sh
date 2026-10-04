#!/bin/bash
# check-privacy-manifest.sh
#
# Verifies that mobile-shell/native/IrisMobileShellApp/PrivacyInfo.xcprivacy
# is well-formed and lists exactly the Apple "required-reason API" categories
# that the mobile shell's source actually uses, no more and no fewer.
#
# Usage: mobile-shell/native/tools/check-privacy-manifest.sh
# Exit code 0 = pass, non-zero = fail (prints why).
#
# Part of RC-01 (docs/plans/20260928-all-routes/apple-compliance/REQUIRED_CHANGES.md).
# See docs/plans/20260928-all-routes/round4/RC-01-privacy-manifest/PLAN.md for how the
# category-to-grep-pattern mapping was derived.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$NATIVE_DIR/IrisMobileShellApp/PrivacyInfo.xcprivacy"
SOURCES_DIR="$NATIVE_DIR/Sources"
APP_DIR="$NATIVE_DIR/IrisMobileShellApp"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

if [ ! -f "$MANIFEST" ]; then
    fail "manifest not found at $MANIFEST"
fi

# 1. The manifest must be a well-formed plist.
if ! plutil -lint "$MANIFEST" >/tmp/check-privacy-manifest.lint.$$ 2>&1; then
    cat /tmp/check-privacy-manifest.lint.$$ >&2
    rm -f /tmp/check-privacy-manifest.lint.$$
    fail "plutil -lint rejected $MANIFEST"
fi
rm -f /tmp/check-privacy-manifest.lint.$$

# 2. Collect Swift source files to grep: Sources/ (excluding Tests) and
#    IrisMobileShellApp/*.swift at the top level (excluding its Tests and
#    IrisMobileShellUITests subfolders, which are test-only and not shipped).
SWIFT_FILES=$(
    { find "$SOURCES_DIR" -name '*.swift' -not -path '*/Tests/*' 2>/dev/null; \
      find "$APP_DIR" -maxdepth 1 -name '*.swift' 2>/dev/null; } | sort -u
)

if [ -z "$SWIFT_FILES" ]; then
    fail "no Swift source files found under $SOURCES_DIR or $APP_DIR (grep base is empty; refusing to pass vacuously)"
fi

grep_any() {
    # grep_any <pattern...> -- returns 0 (found) or 1 (not found) across SWIFT_FILES
    local pattern="$1"
    echo "$SWIFT_FILES" | xargs grep -lE "$pattern" 2>/dev/null | grep -q .
}

# 3. Determine which required-reason categories the source actually uses.
#    Patterns mirror REQUIRED_CHANGES.md RC-01 and AUDIT.md section 6.
declare -a USED_CATEGORIES=()

if grep_any '\bUserDefaults\b'; then
    USED_CATEGORIES+=("NSPrivacyAccessedAPICategoryUserDefaults")
fi

if grep_any '(^|[^a-zA-Z_])stat\(|\blstat\(|\bfstat\(|\battributesOfItem\b|\bcontentModificationDateKey\b|\bmodificationDate\b|\bcreationDate\b'; then
    USED_CATEGORIES+=("NSPrivacyAccessedAPICategoryFileTimestamp")
fi

if grep_any '\bvolumeAvailableCapacity'; then
    USED_CATEGORIES+=("NSPrivacyAccessedAPICategoryDiskSpace")
fi

if grep_any '\bsystemUptime\b|\bmach_absolute_time\b'; then
    USED_CATEGORIES+=("NSPrivacyAccessedAPICategorySystemBootTime")
fi

if grep_any '\bactiveInputModes\b'; then
    USED_CATEGORIES+=("NSPrivacyAccessedAPICategoryUserDefaults.ActiveKeyboards")
fi

# 4. Read the categories the manifest declares.
MANIFEST_JSON=$(plutil -convert json -o - "$MANIFEST" 2>/dev/null)
if [ -z "$MANIFEST_JSON" ]; then
    fail "could not convert $MANIFEST to JSON for inspection"
fi

DECLARED_CATEGORIES=$(printf '%s' "$MANIFEST_JSON" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception as e:
    print("PARSE_ERROR:" + str(e))
    sys.exit(1)
types = data.get("NSPrivacyAccessedAPITypes")
if not isinstance(types, list):
    print("PARSE_ERROR:NSPrivacyAccessedAPITypes missing or not an array")
    sys.exit(1)
seen = set()
for entry in types:
    cat = entry.get("NSPrivacyAccessedAPIType")
    reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
    if not cat:
        print("PARSE_ERROR:an entry is missing NSPrivacyAccessedAPIType")
        sys.exit(1)
    if not isinstance(reasons, list) or len(reasons) == 0:
        print("PARSE_ERROR:" + cat + " has no NSPrivacyAccessedAPITypeReasons")
        sys.exit(1)
    if cat in seen:
        print("PARSE_ERROR:" + cat + " is declared more than once")
        sys.exit(1)
    seen.add(cat)
for cat in sorted(seen):
    print(cat)
')

if echo "$DECLARED_CATEGORIES" | grep -q '^PARSE_ERROR:'; then
    fail "manifest structure problem: $(echo "$DECLARED_CATEGORIES" | sed -n 's/^PARSE_ERROR://p')"
fi

# 5. Compare used vs. declared. Treat the Keyboard/ActiveKeyboards pseudo-category
#    as an alias of the UserDefaults category check above but reported separately.
MISSING=()
for cat in "${USED_CATEGORIES[@]}"; do
    base_cat="${cat%%.*}"
    if ! echo "$DECLARED_CATEGORIES" | grep -qx "$base_cat"; then
        MISSING+=("$cat")
    fi
done

UNUSED=()
while IFS= read -r declared; do
    [ -z "$declared" ] && continue
    found=0
    for cat in "${USED_CATEGORIES[@]}"; do
        if [ "${cat%%.*}" = "$declared" ]; then
            found=1
            break
        fi
    done
    if [ "$found" -eq 0 ]; then
        UNUSED+=("$declared")
    fi
done <<< "$DECLARED_CATEGORIES"

if [ "${#MISSING[@]}" -gt 0 ]; then
    fail "source uses a required-reason API category not declared in the manifest: ${MISSING[*]}"
fi

if [ "${#UNUSED[@]}" -gt 0 ]; then
    fail "manifest declares a required-reason API category with no matching source usage: ${UNUSED[*]}"
fi

echo "PASS: $MANIFEST is valid and matches source usage."
echo "Declared categories:"
echo "$DECLARED_CATEGORIES" | sed 's/^/  - /'
exit 0

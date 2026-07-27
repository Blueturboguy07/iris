#!/usr/bin/env bash
#
# Proves a macOS build is actually installable — not just that the bundler
# exited zero. Checking `codesign --verify` alone is what let an unopenable dmg
# ship before: a bundle can be perfectly signed and still be refused by
# Gatekeeper the moment it arrives with a download flag on it.
#
# So this mounts the dmg the way a person would, copies the app out, marks it
# quarantined exactly as a browser download would, and then asks macOS the same
# question it asks itself at double-click time.
#
# Usage: scripts/verify-iris-macos.sh [--dmg <path>] [--app <path>] [--require-notarized]
set -uo pipefail

cd "$(dirname "$0")/.."
# Searched rather than hard-coded: a universal build lands under
# target/universal-apple-darwin/release/bundle, not target/release/bundle.
BUNDLE_DIR="iris-desktop/src-tauri/target"
DMG=""
APP=""
REQUIRE_SIGNED=0
REQUIRE_NOTARIZED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dmg) DMG="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --require-signed) REQUIRE_SIGNED=1; shift ;;
    # Nothing can be notarized without being signed first, so asking for one
    # asks for the other.
    --require-notarized) REQUIRE_NOTARIZED=1; REQUIRE_SIGNED=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -z "$APP" ] && APP="$(/usr/bin/find "$BUNDLE_DIR" -maxdepth 5 -path "*/release/bundle/macos/Iris.app" -print -quit 2>/dev/null)"
[ -z "$DMG" ] && DMG="$(/usr/bin/find "$BUNDLE_DIR" -maxdepth 5 -path "*/release/bundle/dmg/*.dmg" -print -quit 2>/dev/null)"

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "No Iris.app found — build one first." >&2
  exit 1
fi

FAILURES=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
note() { printf '  ----  %s\n' "$1"; }

echo "App: $APP"
[ -n "$DMG" ] && echo "Dmg: $DMG"

echo
echo "Signature"
if codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null 2>&1; then
  pass "signature is intact and covers every nested binary"
else
  fail "codesign --verify rejected the bundle"
fi

# A build with no certificate configured is ad-hoc on purpose — that is the
# fallback path, and it is what a fork or a secret-less CI run produces. Only
# a run that asked for a real signature treats it as a failure; otherwise the
# distribution checks are reported and skipped.
SIGN_INFO="$(codesign --display --verbose=4 "$APP" 2>&1)"
AUTHORITY="$(printf '%s\n' "$SIGN_INFO" | awk -F'=' '/^Authority=/ {print $2; exit}')"
ADHOC=0
if printf '%s' "$AUTHORITY" | grep -q "^Developer ID Application"; then
  pass "signed by $AUTHORITY"
elif printf '%s\n' "$SIGN_INFO" | grep -q "Signature=adhoc"; then
  ADHOC=1
  if [ "$REQUIRE_SIGNED" = "1" ]; then
    fail "ad-hoc signed — this build cannot be distributed"
  else
    note "ad-hoc signed (no certificate configured); distribution checks skipped"
  fi
else
  fail "unexpected signing authority: ${AUTHORITY:-none}"
fi

if [ "$ADHOC" = "0" ]; then
  # The runtime flag is what notarization checks for; a signature without it is
  # accepted locally and then rejected by Apple at submission time.
  if printf '%s\n' "$SIGN_INFO" | grep -q "flags=.*runtime"; then
    pass "hardened runtime is enabled"
  else
    fail "hardened runtime is missing"
  fi

  TEAM="$(printf '%s\n' "$SIGN_INFO" | awk -F'=' '/^TeamIdentifier=/ {print $2; exit}')"
  if [ -n "$TEAM" ] && [ "$TEAM" != "not set" ]; then
    pass "team identifier is $TEAM"
  else
    fail "no team identifier — Gatekeeper cannot attribute this build"
  fi
fi

echo
echo "Notarization"
if xcrun stapler validate "$APP" >/dev/null 2>&1; then
  pass "a notarization ticket is stapled to the app"
elif [ "$REQUIRE_NOTARIZED" = "1" ]; then
  fail "no stapled ticket — a downloaded copy will be blocked"
else
  note "no stapled ticket (expected for a local build; required to publish)"
fi

if [ -n "$DMG" ] && [ -f "$DMG" ]; then
  if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    pass "the dmg carries its own ticket"
  elif [ "$REQUIRE_NOTARIZED" = "1" ]; then
    fail "the dmg has no ticket"
  else
    note "the dmg has no ticket"
  fi
fi

# The real test. A quarantined copy is what everyone who is not us will run.
echo
echo "Install and open"
STAGE="$(mktemp -d)"
cleanup() {
  [ -n "${MOUNTED:-}" ] && hdiutil detach "$MOUNTED" -quiet >/dev/null 2>&1
  rm -rf "$STAGE"
}
trap cleanup EXIT

SOURCE_APP="$APP"
if [ -n "$DMG" ] && [ -f "$DMG" ]; then
  MOUNTED="$(mktemp -d)"
  if hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNTED" -quiet; then
    pass "the dmg mounts"
    DMG_APP="$(/usr/bin/find "$MOUNTED" -maxdepth 2 -name "Iris.app" -print -quit)"
    if [ -n "$DMG_APP" ]; then
      SOURCE_APP="$DMG_APP"
    else
      fail "no Iris.app inside the dmg"
    fi
  else
    MOUNTED=""
    fail "the dmg would not mount"
  fi
fi

cp -R "$SOURCE_APP" "$STAGE/Iris.app"
INSTALLED="$STAGE/Iris.app"

# Exactly what a browser writes onto a download, so Gatekeeper runs its full
# first-launch assessment instead of the relaxed local-file path.
xattr -w com.apple.quarantine "0083;00000000;Safari;" "$INSTALLED" 2>/dev/null

ASSESS="$(spctl --assess --type execute --verbose=4 "$INSTALLED" 2>&1)"
if printf '%s\n' "$ASSESS" | grep -q "accepted"; then
  pass "Gatekeeper accepts a quarantined copy"
  GATEKEEPER_OK=1
else
  GATEKEEPER_OK=0
  REASON="$(printf '%s\n' "$ASSESS" | tail -1)"
  if [ "$REQUIRE_NOTARIZED" = "1" ]; then
    fail "Gatekeeper rejects a quarantined copy: $REASON"
  else
    note "Gatekeeper rejects a quarantined copy: $REASON"
    note "That is what an un-notarized build is supposed to do."
  fi
fi

# Launching is a separate question from being allowed to launch: a bundle can
# pass assessment and still die on start over a bad entitlement or a missing
# framework. Run it without the quarantine flag so this stays a launch test.
LAUNCH_COPY="$STAGE/launch/Iris.app"
mkdir -p "$STAGE/launch"
cp -R "$SOURCE_APP" "$LAUNCH_COPY"
xattr -cr "$LAUNCH_COPY" 2>/dev/null

# Read the name rather than assuming it: the bundle is "Iris.app" but the
# executable inside is whatever Cargo or mainBinaryName produced.
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
  "$LAUNCH_COPY/Contents/Info.plist" 2>/dev/null)"
BINARY="$LAUNCH_COPY/Contents/MacOS/$EXECUTABLE_NAME"
if [ -z "$EXECUTABLE_NAME" ] || [ ! -x "$BINARY" ]; then
  fail "no executable at Contents/MacOS/${EXECUTABLE_NAME:-<unset>}"
else
  "$BINARY" >"$STAGE/run.log" 2>&1 &
  APP_PID=$!
  SETTLED=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if kill -0 "$APP_PID" 2>/dev/null; then SETTLED=$((SETTLED + 1)); else break; fi
  done

  if kill -0 "$APP_PID" 2>/dev/null; then
    pass "the app starts and stays running (${SETTLED}s)"
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
  else
    fail "the app exited on launch"
    sed -n '1,20p' "$STAGE/run.log" | sed 's/^/        /'
  fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  if [ "${GATEKEEPER_OK:-0}" = "1" ]; then
    echo "Ready to distribute: a downloaded copy opens with no warning."
  elif [ "$ADHOC" = "1" ]; then
    echo "Builds and runs. Not signed, so this build is for local use only."
  else
    echo "Builds and runs, but is not distributable until it is notarized."
  fi
  exit 0
fi

echo "$FAILURES check(s) failed."
exit 1

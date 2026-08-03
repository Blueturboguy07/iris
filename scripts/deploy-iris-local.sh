#!/usr/bin/env bash
# Build Iris and install it to /Applications for local use.
#
# The only interesting thing this does is sign with the real Developer ID
# certificate rather than ad-hoc.
#
# TCC — the permission system behind Screen Recording and Accessibility —
# identifies an app by its code signature. An ad-hoc signature (`codesign
# --sign -`) embeds a hash of the binary, so every rebuild produces a signature
# macOS has never seen and treats as a different app: the permissions you
# granted five minutes ago belong to a build that no longer exists, and Iris
# asks again. Forever.
#
# A Developer ID signature's designated requirement is bundle id + team id,
# with no binary hash in it, so every build satisfies the requirement the
# previous grant was recorded against. Grant once, keep it.
#
# This is what `iris-macos/CLAUDE.md` is really warning about when it says not
# to run xcodebuild from the terminal.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/iris-macos"
DERIVED_DATA="${IRIS_DERIVED_DATA:-$PROJECT_DIR/.build-local}"
SIGNING_IDENTITY="${IRIS_SIGNING_IDENTITY:-Developer ID Application: Mann Bellani (R5R3ZS54LV)}"
INSTALL_PATH="/Applications/Iris.app"

if ! security find-identity -v -p codesigning | grep -qF "$SIGNING_IDENTITY"; then
  echo "Signing identity not found in the keychain:" >&2
  echo "  $SIGNING_IDENTITY" >&2
  echo >&2
  echo "Available:" >&2
  security find-identity -v -p codesigning >&2
  echo >&2
  echo "Set IRIS_SIGNING_IDENTITY to one of the above. Do not fall back to" >&2
  echo "ad-hoc signing: it works, and then macOS forgets every permission on" >&2
  echo "the next build." >&2
  exit 1
fi

echo "Building Iris…"
xcodebuild build \
  -project "$PROJECT_DIR/leanring-buddy.xcodeproj" \
  -scheme leanring-buddy \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  | grep -E "error:|warning: .*deprecated|BUILD" || true

BUILT_APP="$DERIVED_DATA/Build/Products/Debug/Iris.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "Build did not produce $BUILT_APP" >&2
  exit 1
fi

echo "Stopping any running copy..."
osascript -e 'tell application "Iris" to quit' 2>/dev/null || true
pkill -x Iris 2>/dev/null || true
sleep 2

echo "Installing to $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"
cp -R "$BUILT_APP" "$INSTALL_PATH"

# Point the app at a local dev server when asked. The funded assistant
# endpoints only exist on the iris-assistant branch, so until that ships a
# build talking to publikhq.com gets a 404 and reports it as "something went
# wrong reaching the assistant" - which reads as a bug in the app.
if [ -n "${IRIS_API_BASE_URL:-}" ]; then
  echo "Pointing at $IRIS_API_BASE_URL..."
  /usr/libexec/PlistBuddy -c "Add :PublikAPIBaseURL string $IRIS_API_BASE_URL" \
    "$INSTALL_PATH/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :PublikAPIBaseURL $IRIS_API_BASE_URL" \
       "$INSTALL_PATH/Contents/Info.plist"
fi

# Signing must come after any Info.plist edit: changing a file inside the
# bundle invalidates the seal, and macOS refuses to launch a bundle whose
# signature no longer matches its contents.
echo "Signing with $SIGNING_IDENTITY..."
codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$INSTALL_PATH"
xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true

echo
echo "Designated requirement (what TCC records a grant against):"
codesign -d -r- "$INSTALL_PATH" 2>&1 | grep "^designated" || true
echo
echo "Installed. Permissions granted to this signature survive future builds."

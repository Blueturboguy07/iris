#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

# =============================================================================
# deploy-iris-local.sh — build Iris and install it to /Applications for local
# testing. Unlike release.sh, this does NOT notarize, make a DMG, or cut a GitHub
# release — it just gets the *current source* running on this Mac in one step.
#
# Why a signed build and not Cmd+R / a plain xcodebuild:
#   TCC (Screen Recording, Accessibility) grants are keyed to the app's code
#   signature. A Developer ID signature is STABLE across rebuilds, so the grants
#   survive each redeploy. An ad-hoc / DerivedData / Cmd+R build gets a different
#   (or "-") signature each time, which is why those make Iris re-ask for
#   permissions — the exact churn AGENTS.md warns about. This script always signs
#   with the same Developer ID identity, so you grant permissions once.
#
# Prereqs (already true on this Mac): the "Developer ID Application: Mann Bellani
# (R5R3ZS54LV)" certificate in the login Keychain, and Xcode's command line tools.
#
# Usage:  ./scripts/deploy-iris-local.sh
# You will be prompted once for your Keychain password so codesign can use the key.
# =============================================================================

SCHEME="leanring-buddy"
IDENTITY="Developer ID Application: Mann Bellani (R5R3ZS54LV)"
TEAM="R5R3ZS54LV"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build-local"
APP_SRC="${BUILD_DIR}/Build/Products/Release/Iris.app"
APP_DEST="/Applications/Iris.app"

cd "${PROJECT_DIR}"

echo "🛑 Quitting any running Iris…"
osascript -e 'quit app "Iris"' 2>/dev/null || true
sleep 1

echo "🔨 Building Iris (Release, Developer ID signed) — this takes a minute…"
xcodebuild \
  -project leanring-buddy.xcodeproj \
  -scheme "${SCHEME}" \
  -configuration Release \
  -derivedDataPath "${BUILD_DIR}" \
  CODE_SIGN_IDENTITY="${IDENTITY}" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="${TEAM}" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build 2>&1 | tail -8

if [ ! -d "${APP_SRC}" ]; then
  echo "❌ Build did not produce ${APP_SRC}"
  exit 1
fi

echo "📥 Installing to ${APP_DEST}…"
rm -rf "${APP_DEST}"
ditto "${APP_SRC}" "${APP_DEST}"

echo "🔎 Verifying the signature (a stable identity = TCC grants stick)…"
codesign --verify --deep --strict --verbose=1 "${APP_DEST}"
codesign -dvv "${APP_DEST}" 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier" || true

echo "🚀 Launching Iris from /Applications…"
open "${APP_DEST}"

echo ""
echo "✅ Done. Iris is running from /Applications with today's changes:"
echo "   • no-click auto-advance on open steps"
echo "   • deliberate pacing"
echo "   • on install finish: the app opens and joins 'Your publik apps'"
echo ""
echo "If macOS asks for Screen Recording / Accessibility, grant them once —"
echo "they'll persist across future runs of this script."

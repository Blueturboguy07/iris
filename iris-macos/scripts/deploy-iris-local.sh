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
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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

# The build leaves a copy in .build-local that ALSO carries bundle id
# com.publikhq.iris and ALSO claims the iris:// URL scheme. If it stays
# registered, LaunchServices has two claimants for one scheme and can resolve
# iris:// (the "Open in Iris" handoff) to the wrong — or a since-deleted — copy.
# That is exactly how dozens of phantom handlers accreted before.
#
# Unregistering only THIS run's own .build-local copy was not enough: every
# `xcodebuild build`/`xcodebuild test` anywhere (a different .build-* dir, a
# DerivedData copy, a scratch worktree, an old DMG staging folder) registers
# its OWN Iris.app under the same bundle id and never gets cleaned up when that
# directory is later deleted — LaunchServices keeps the dangling registration.
# On this Mac they had piled up to 54 separate `com.publikhq.iris` claimants,
# most pointing at directories that no longer exist, and a `iris://` open (the
# live-run report's "`open -a Iris 'iris://guide/…'` does nothing") is free to
# resolve to any one of them instead of the real, running /Applications copy.
# So: sweep EVERY registered com.publikhq.iris bundle other than the one at
# APP_DEST and drop its registration, then force APP_DEST to be the one and
# only iris:// handler on every deploy — not just the previous build's copy.
echo "🧹 Making /Applications/Iris.app the sole iris:// handler…"
if [ -x "${LSREG}" ]; then
  "${LSREG}" -dump 2>/dev/null | awk -v skip="${APP_DEST}" '
    BEGIN { path = ""; ident = "" }
    /^--------------------------------------------------------------------------------$/ {
      if (ident == "com.publikhq.iris" && path != "" && path != skip) print path
      path = ""; ident = ""
      next
    }
    /^path: / {
      line = $0
      sub(/^path: */, "", line)
      sub(/ *\(0x[0-9a-f]*\)$/, "", line)
      path = line
    }
    /^identifier: / {
      line = $0
      sub(/^identifier: */, "", line)
      ident = line
    }
    END { if (ident == "com.publikhq.iris" && path != "" && path != skip) print path }
  ' | while IFS= read -r stalePath; do
    "${LSREG}" -u "${stalePath}" 2>/dev/null || true
  done
  "${LSREG}" -f "${APP_DEST}" 2>/dev/null || true
  CLAIMANTS="$("${LSREG}" -dump 2>/dev/null | grep -c 'claimed schemes:.*iris:' || true)"
  echo "   iris:// claimants now registered: ${CLAIMANTS} (want 1)"
fi

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

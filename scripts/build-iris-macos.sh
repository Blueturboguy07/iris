#!/usr/bin/env bash
#
# Builds the Iris desktop app for macOS, taking whichever of two signing paths
# the environment can support. This mirrors how NitroAI's electron-builder
# config picks its path, so both products behave the same way.
#
#   • Developer ID + notarized — when APPLE_SIGNING_IDENTITY names a real
#     "Developer ID Application" identity. Tauri signs with the hardened runtime
#     and, if APPLE_ID / APPLE_PASSWORD / APPLE_TEAM_ID are also set, submits
#     the bundle to Apple and waits for the ticket. The result opens on the
#     first double-click on someone else's Mac with no warning at all.
#
#   • Ad-hoc — when no identity is configured. The app is valid rather than
#     "damaged", but macOS will refuse to open it after a download. Good enough
#     to run the thing locally, never good enough to publish.
#
# Usage: scripts/build-iris-macos.sh [--target <triple>] [--bundles <list>]
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
TAURI="$REPO_ROOT/node_modules/.bin/tauri"
TARGET=""
BUNDLES="app,dmg"

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --bundles) BUNDLES="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ ! -x "$TAURI" ]; then
  echo "Tauri CLI missing — run 'pnpm install' first." >&2
  exit 1
fi

BUILD_ARGS=(build --bundles "$BUNDLES")
[ -n "$TARGET" ] && BUILD_ARGS+=(--target "$TARGET")

# An identity is only usable if it is actually in a keychain we can reach;
# otherwise codesign fails deep inside the bundler with a far worse message.
SIGN=0
if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
  if security find-identity -v -p codesigning | grep -qF "$APPLE_SIGNING_IDENTITY"; then
    SIGN=1
  else
    echo "APPLE_SIGNING_IDENTITY is set but no matching identity is in the keychain." >&2
    exit 1
  fi
fi

if [ "$SIGN" = "1" ]; then
  NOTARIZE=0
  if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
    echo "==> Building signed and notarized (identity: $APPLE_SIGNING_IDENTITY)"
    NOTARIZE=1
  else
    echo "==> Building signed but NOT notarized (identity: $APPLE_SIGNING_IDENTITY)"
    echo "    Set APPLE_ID, APPLE_PASSWORD and APPLE_TEAM_ID to notarize."
    # Tauri notarizes whenever these are present, so make sure a partial set
    # does not half-start a submission.
    unset APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID
  fi
  cd iris-desktop
  "$TAURI" "${BUILD_ARGS[@]}"

  # Tauri notarizes and staples the .app, then wraps it in a dmg which it signs
  # but does not notarize. A dmg with no ticket of its own has to be checked
  # against Apple over the network, so the download is refused on a machine that
  # is offline or behind a filter — the failure looks like a corrupt file.
  if [ "$NOTARIZE" = "1" ]; then
    TARGET_DIR="src-tauri/target"
    [ -n "$TARGET" ] && TARGET_DIR="$TARGET_DIR/$TARGET"
    DMG="$(/usr/bin/find "$TARGET_DIR/release/bundle/dmg" -name "*.dmg" -print -quit 2>/dev/null)"
    if [ -n "$DMG" ]; then
      echo "==> Notarizing the disk image itself"
      xcrun notarytool submit "$DMG" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait
      xcrun stapler staple "$DMG"
    fi
  fi
else
  echo "==> No signing identity — building ad-hoc signed (local use only)"
  cd iris-desktop
  "$TAURI" "${BUILD_ARGS[@]}" --no-sign

  TARGET_DIR="src-tauri/target"
  [ -n "$TARGET" ] && TARGET_DIR="$TARGET_DIR/$TARGET"
  APP="$TARGET_DIR/release/bundle/macos/Iris.app"
  if [ -d "$APP" ]; then
    # Without this the bundle has no signature at all and macOS reports it as
    # damaged rather than merely untrusted.
    codesign --force --deep --sign - "$APP"
    echo "Ad-hoc signed $APP"
  fi
fi

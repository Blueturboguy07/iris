#!/bin/zsh
# Compiles and runs the shell-audio-checks against the REAL, unchanged
# Sources/IrisMobileShellHost/NativeAudioSessionPolicy.swift (source-linked,
# never copied) plus this folder's own main.swift. Target is macOS, so only
# the pure Foundation-only half of that file (no AVFoundation, no UIKit) is
# reachable; the #if os(iOS) adapter is excluded by the compiler, exactly as
# it would be in any other macOS build of that file. No xcodebuild, no
# simulator, no WebKit, no native app.
#
# Usage: run.sh [repo-root]   default /Users/akrit/Documents/iris
set -euo pipefail

HERE=${0:A:h}
REPO=${1:-/Users/akrit/Documents/iris}
SOURCE=$REPO/mobile-shell/native/Sources/IrisMobileShellHost/NativeAudioSessionPolicy.swift
OUT=${SHELL_AUDIO_CHECKS_OUT:-/private/tmp/claude-501/-Users-akrit-Projects-Hub-Iris-iris/7fc55283-00a8-41d4-832e-c5cc3a8c6d38/scratchpad/kneecap-bugpass/shell-audio-checks-out}
BINARY=$OUT/shell-audio-checks
LOG=$OUT/compile.log

if [[ ! -f "$SOURCE" ]]; then
  echo "shell-audio-checks: source not found: $SOURCE" >&2
  exit 2
fi

mkdir -p "$OUT"

echo "shell-audio-checks: compiling $SOURCE + $HERE/main.swift"
if ! xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
    "$SOURCE" "$HERE/main.swift" -o "$BINARY" > "$LOG" 2>&1; then
  echo "shell-audio-checks: COMPILE FAILED"
  cat "$LOG"
  exit 2
fi

"$BINARY"

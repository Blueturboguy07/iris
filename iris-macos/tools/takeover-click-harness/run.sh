#!/bin/bash
#
# Builds the takeover click harness against the app's own sources and runs it.
#
# The harness links every leanring-buddy/*.swift (except the @main app entry,
# which pulls in Sparkle) plus this directory's main.swift, so it drives the
# REAL GuideAutopilotTakeoverController / GuideAutopilotTakeoverTerminalPanel and
# the REAL "Try again" / "Continue past it" buttons — no replica.
#
# Needs an AWAKE, UNLOCKED GUI session and an Accessibility grant for whatever
# launches it (Terminal / the agent host), so posted CGEvents are delivered.
# A locked screen makes the harness print `RESULT blocked-screen-locked`.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../leanring-buddy"
OUT="${TMPDIR:-/tmp}/takeover-click-harness"

FILES=$(ls "$SRC"/*.swift | grep -v 'leanring_buddyApp.swift')

echo "Compiling harness against $(echo "$FILES" | wc -l | tr -d ' ') app sources ..."
# shellcheck disable=SC2086
swiftc -O -o "$OUT" $FILES "$HERE/main.swift"

echo "Running (a real takeover window appears for a few seconds) ..."
caffeinate -u -t 90 >/dev/null 2>&1 &
"$OUT"

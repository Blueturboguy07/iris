#!/bin/bash
set -euo pipefail

# =============================================================================
# release-app-token.sh — print this Mac's publik app token, for a LOCAL release.
#
# Used as a command substitution, so the token goes straight into xcodebuild's
# argument list and never lands in a shell variable, a log, or the terminal:
#
#   xcodebuild archive ... PUBLIK_APP_TOKEN="$(iris-macos/scripts/release-app-token.sh)"
#
# Why this exists at all: macOS releases are cut by hand on this machine (see
# the iris-release-process note), so the PUBLIK_APP_TOKEN repo secret that CI
# reads is unreachable here. The token lives in iris-macos/.publik-app-token,
# which .gitignore excludes — iris is a public repo.
#
# It refuses rather than degrades. A release that ships an empty token still
# builds, still signs, still notarizes, and is broken in exactly one silent
# way: every new install falls back to asking the user to paste a key, and
# nobody finds out until someone installs it. Failing here is the whole point.
# =============================================================================

TOKEN_FILE="$(cd "$(dirname "$0")/.." && pwd)/.publik-app-token"

if [ ! -f "$TOKEN_FILE" ]; then
  cat >&2 <<EOF
release-app-token: no token file at
  $TOKEN_FILE

Mint one for this machine (from the publik repo), writing it straight to the
file so it is never echoed:

  cd ~/publik
  npx tsx scripts/mint-app-token.mts iris --add --label "mac-local-\$(date +%Y-%m-%d)" \\
    > $TOKEN_FILE
  chmod 600 $TOKEN_FILE

--add mints a SIBLING token: every already-shipped build keeps working, which
is the whole reason the gateway mints one per release. Never --rotate for this;
that revokes the tokens live builds are still using.
EOF
  exit 1
fi

TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"

if [ -z "$TOKEN" ]; then
  echo "release-app-token: $TOKEN_FILE is empty." >&2
  exit 1
fi

# The same shape PublikAPIAccount.buildAppToken demands. Catching it here means
# a typo stops the release instead of shipping a build that quietly cannot
# provision.
if [[ "$TOKEN" != pat_iris_* ]]; then
  echo "release-app-token: $TOKEN_FILE does not hold a pat_iris_ token." >&2
  echo "release-app-token: (found ${#TOKEN} characters starting '${TOKEN:0:4}')" >&2
  exit 1
fi

printf '%s' "$TOKEN"

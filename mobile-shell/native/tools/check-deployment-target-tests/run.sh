#!/usr/bin/env bash
# Behaviour tests for check-deployment-target.sh (RC-10). Builds small fake
# project trees in a scratch directory and checks the exit code and the words
# a person would read. The oracle is the expected verdict written here, not
# the script's own arithmetic.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../check-deployment-target.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ok=0; bad=0

make_tree() { # dir required-version pbx-version package-platform
  local d="$1"
  mkdir -p "$d/Sources/Host" "$d/IrisMobileShellApp/App.xcodeproj"
  printf 'enum X { static let m = "Opening apps requires iOS %s or later." }\n' "$2" > "$d/Sources/Host/Msg.swift"
  printf 'x = { IPHONEOS_DEPLOYMENT_TARGET = %s; };\ny = { IPHONEOS_DEPLOYMENT_TARGET = %s; };\n' "$3" "$3" > "$d/IrisMobileShellApp/App.xcodeproj/project.pbxproj"
  printf '// swift-tools-version: 5.9\nlet package = Package(platforms: [ .macOS(.v13), %s ])\n' "$4" > "$d/Package.swift"
}
expect() { # name want-exit want-text dir
  local out code
  out="$("$SCRIPT" --root "$4" 2>&1)"; code=$?
  if [ "$code" -eq "$2" ] && { [ -z "$3" ] || printf '%s' "$out" | grep -q "$3"; }; then echo "OK   $1"; ok=$((ok+1))
  else echo "BAD  $1 (exit=$code want=$2 text=$3)"; printf '%s\n' "$out" | sed 's/^/       /'; bad=$((bad+1)); fi
}

make_tree "$TMP/honest" 18.4 18.4 '.iOS("18.4")';        expect "all at 18.4 passes" 0 "PASS" "$TMP/honest"
make_tree "$TMP/higher" 18.4 26.0 '.iOS("26.0")';        expect "higher than required passes" 0 "PASS" "$TMP/higher"
make_tree "$TMP/old-pbx" 18.4 16.0 '.iOS("18.4")';       expect "pbxproj still at 16.0 fails" 1 "IPHONEOS_DEPLOYMENT_TARGET is 16.0" "$TMP/old-pbx"
make_tree "$TMP/old-pkg" 18.4 18.4 '.iOS(.v16)';         expect "Package.swift still .v16 fails" 1 "Package.swift .iOS platform is 16" "$TMP/old-pkg"
make_tree "$TMP/mid" 18.4 18.0 '.iOS("18.4")';           expect "18.0 is below 18.4 and fails" 1 "requires iOS 18.4" "$TMP/mid"
make_tree "$TMP/v17" 18.4 18.4 '.iOS(.v17)';             expect "Package .v17 fails" 1 "is 17" "$TMP/v17"
make_tree "$TMP/newreq" 26.0 18.4 '.iOS("18.4")';        expect "a newer requirement in the code fails an old target" 1 "requires iOS 26" "$TMP/newreq"
mkdir -p "$TMP/noreq"; make_tree "$TMP/noreq" 18.4 18.4 '.iOS("18.4")'; printf 'enum X {}\n' > "$TMP/noreq/Sources/Host/Msg.swift"
expect "no requirement message anywhere fails closed" 1 "cannot be worked out" "$TMP/noreq"
make_tree "$TMP/nopbx" 18.4 18.4 '.iOS("18.4")'; printf 'nothing\n' > "$TMP/nopbx/IrisMobileShellApp/App.xcodeproj/project.pbxproj"
expect "no target setting found fails closed" 1 "no IPHONEOS_DEPLOYMENT_TARGET" "$TMP/nopbx"
make_tree "$TMP/testfile" 18.4 18.4 '.iOS("18.4")'; printf 'let s = "requires iOS 99 or later"\n' > "$TMP/testfile/Sources/Host/FooTests.swift"
expect "a test file's text does not raise the bar" 0 "PASS" "$TMP/testfile"
make_tree "$TMP/xcc" 18.4 18.4 '.iOS("18.4")'; printf 'IPHONEOS_DEPLOYMENT_TARGET = 17.0\n' > "$TMP/xcc/IrisMobileShellApp/Release.xcconfig"
expect "an xcconfig left at 17.0 fails" 1 "Release.xcconfig" "$TMP/xcc"

echo "---"; echo "check-deployment-target-tests: $ok ok, $bad bad"
[ "$bad" -eq 0 ]

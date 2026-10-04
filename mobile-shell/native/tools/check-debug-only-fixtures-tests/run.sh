#!/usr/bin/env bash
# Behaviour tests for check-debug-only-fixtures.sh: small fake Sources trees.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; S="$HERE/../check-debug-only-fixtures.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; ok=0; bad=0
mk() { mkdir -p "$T/$1/Sources/Host"; printf '%s\n' "$2" > "$T/$1/Sources/Host/$3"; }
expect() { local out code; out="$("$S" --root "$T/$2" 2>&1)"; code=$?
  if [ "$code" -eq "$3" ] && printf '%s' "$out" | grep -q "$4"; then echo "OK   $1"; ok=$((ok+1)); else echo "BAD  $1 (exit=$code)"; printf '%s\n' "$out" | sed 's/^/       /'; bad=$((bad+1)); fi; }
mk good $'import Foundation\n// note\n#if DEBUG\npublic enum F { static let x = 1 }\n#endif' NativeFooUITestFixtures.swift
expect "wrapped whole passes" good 0 "PASS 1"
mk ok2 $'/* block\n comment */\nimport Foundation\n\n#if DEBUG\nenum G {}\n#if os(iOS)\nenum H {}\n#endif\n#endif' MyUITestSeed.swift
expect "nested inner #if is fine" ok2 0 "PASS"
mk noguard $'import Foundation\npublic enum F { static let x = 1 }' NativeFooUITestFixtures.swift
expect "no guard fails" noguard 1 "not \`#if DEBUG\`"
mk partial $'import Foundation\n#if DEBUG\nenum A {}\n#endif\npublic enum B {}' NativeFooUITestFixtures.swift
expect "code after the endif fails" partial 1 "code after the closing"
mk elsebranch $'#if DEBUG\nenum A {}\n#else\nenum A2 {}\n#endif' NativeFooUITestFixtures.swift
expect "an #else branch fails" elsebranch 1 "compiles a branch into Release"
mk wrongflag $'#if TESTING\nenum A {}\n#endif' NativeFooUITestFixtures.swift
expect "a different flag fails" wrongflag 1 "not \`#if DEBUG\`"
mk unrelated $'public enum Plain {}' Plain.swift
expect "no fixture file at all fails closed" unrelated 1 "no UITestFixtures or UITestSeed"
echo "---"; echo "check-debug-only-fixtures-tests: $ok ok, $bad bad"; [ "$bad" -eq 0 ]

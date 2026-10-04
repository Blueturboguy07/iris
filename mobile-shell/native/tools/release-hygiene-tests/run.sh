#!/usr/bin/env bash
# Fixture test runner for release-hygiene.sh (RC-08). For each rule under
# fixtures/<rule>/{pass,fail}, runs the script with --root pointed at that
# fixture and checks the exit code: 0 for pass, 1 for fail. Prints one
# line per fixture and a final summary; exits 1 if any assertion failed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../release-hygiene.sh"
FIXTURES="$HERE/fixtures"

ok=0
bad=0

for rule_dir in "$FIXTURES"/*/; do
  rule="$(basename "$rule_dir")"
  for variant in pass fail; do
    fixture="$rule_dir$variant"
    [ -d "$fixture" ] || { echo "SKIP $rule/$variant (no fixture directory)"; continue; }
    want=0
    [ "$variant" = "fail" ] && want=1
    set +e
    out="$("$SCRIPT" --root "$fixture" 2>&1)"
    code=$?
    set -e
    if [ "$code" -eq "$want" ]; then
      echo "OK   $rule/$variant (exit=$code)"
      ok=$((ok + 1))
    else
      echo "BAD  $rule/$variant (exit=$code, want=$want)"
      echo "$out" | sed 's/^/       /'
      bad=$((bad + 1))
    fi
  done
done

echo "---"
echo "release-hygiene-tests: $ok ok, $bad bad"
[ "$bad" -eq 0 ]

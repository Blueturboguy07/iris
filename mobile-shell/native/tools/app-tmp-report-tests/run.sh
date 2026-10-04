#!/usr/bin/env bash
# Behaviour tests for app-tmp-report.sh: fake app tmp folders with the layouts the
# Simulator really showed (a stream file inside com.apple.WebKit.Networking/, upload
# copies as folders directly in tmp), then read the report as a person would.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; S="$HERE/../app-tmp-report.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; ok=0; bad=0
check() { # name want-exit want-text dir [extra args]
  local name="$1" want="$2" text="$3" dir="$4"; shift 4
  local out code; out="$("$S" --dir "$dir" "$@" 2>&1)"; code=$?
  if [ "$code" -eq "$want" ] && printf '%s' "$out" | grep -q "$text"; then echo "OK   $name"; ok=$((ok+1))
  else echo "BAD  $name (exit=$code want=$want text=$text)"; printf '%s\n' "$out" | sed 's/^/       /'; bad=$((bad+1)); fi
}
old() { touch -t 202601010000 "$1"; }
# 1 clean tmp
mkdir -p "$T/clean"; echo x > "$T/clean/holiday.mov"
check "clean tmp passes expect-clean" 0 "FileSystemWritableStream\* 0 (0 KB); WKFileUploadPanel-\* 0" "$T/clean" --expect-clean
# 2 the real Simulator layout: a stream file inside the WebKit networking folder
mkdir -p "$T/nested/com.apple.WebKit.Networking"; head -c 154686 /dev/zero > "$T/nested/com.apple.WebKit.Networking/FileSystemWritableStreamazvI3G"
check "nested stream file is listed" 0 "STREAM  tmp/com.apple.WebKit.Networking/FileSystemWritableStreamazvI3G" "$T/nested"
check "nested stream file fails expect-clean" 1 "NOT CLEAN" "$T/nested" --expect-clean
# 3 top-level stream file
mkdir -p "$T/top"; head -c 4096 /dev/zero > "$T/top/FileSystemWritableStream-x"
check "top-level stream file fails expect-clean" 1 "1 stream file" "$T/top" --expect-clean
# 4 a fresh upload copy fails, an old one passes (older than the sweep's 15 minutes)
mkdir -p "$T/fresh/WKFileUploadPanel-AAA"; echo x > "$T/fresh/WKFileUploadPanel-AAA/clip.mov"
check "fresh upload copy fails expect-clean" 1 "1 fresh upload" "$T/fresh" --expect-clean
mkdir -p "$T/stale/WKFileUploadPanel-BBB"; old "$T/stale/WKFileUploadPanel-BBB"
check "old upload copy is listed but passes" 0 "WKPANEL tmp/WKFileUploadPanel-BBB" "$T/stale" --expect-clean
# 4b the summary counts the bytes of an upload copy (a 300 KB clip reads as hundreds of KB)
mkdir -p "$T/sized/WKFileUploadPanel-CCC"; head -c 307200 /dev/zero > "$T/sized/WKFileUploadPanel-CCC/clip.mov"; old "$T/sized/WKFileUploadPanel-CCC"
check "summary carries the size of an upload copy" 0 "WKFileUploadPanel-\* 1 ([3-9][0-9][0-9] KB)" "$T/sized"
# 5 other names are ignored
mkdir -p "$T/other/com.apple.WebKit.Networking"; echo x > "$T/other/com.apple.WebKit.Networking/Cache.db"; echo x > "$T/other/notes.txt"
check "unrelated files are not reported" 0 "FileSystemWritableStream\* 0" "$T/other" --expect-clean
# 6 usage
"$S" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && { echo "OK   bad flag exits 2"; ok=$((ok+1)); } || { echo "BAD  bad flag"; bad=$((bad+1)); }
echo "---"; echo "app-tmp-report-tests: $ok ok, $bad bad"; [ "$bad" -eq 0 ]

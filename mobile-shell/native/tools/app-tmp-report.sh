#!/usr/bin/env bash
# app-tmp-report.sh - what WebKit's temp copies look like inside the Iris app's
# tmp folder right now (round 6, integrator-B verifier finding).
#
# Why: importing a long video makes WebKit write a full copy of it
# (WKFileUploadPanel-*, a folder or file directly in tmp) and stage saves
# (FileSystemWritableStream*, a file directly in tmp OR in
# tmp/com.apple.WebKit.Networking/). Iris sweeps both, but only a look at the
# real container shows whether the space came back. Run this right AFTER an
# import ends, not after a relaunch.
#
# Usage:
#   app-tmp-report.sh                      Simulator: the booted device, dev bundle id
#   app-tmp-report.sh --device <udid|name> --bundle-id <id>
#   app-tmp-report.sh --dir <path/to/tmp>  any tmp folder (used by the tests)
#   add --expect-clean to fail (exit 1) when any FileSystemWritableStream* is
#   left, or any WKFileUploadPanel-* is younger than --fresh-minutes (default 15,
#   the sweep's own stale threshold: a younger copy may belong to a running import).
# Prints one line per item and a summary. Exit 0 unless --expect-clean finds something, 2 on usage.
set -uo pipefail
DEVICE="booted"; BUNDLE="com.publikhq.iris.mobileshell.dev"; DIR=""; EXPECT=0; FRESH=15
while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --bundle-id) BUNDLE="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --expect-clean) EXPECT=1; shift ;;
    --fresh-minutes) FRESH="$2"; shift 2 ;;
    *) echo "usage: app-tmp-report.sh [--device D] [--bundle-id ID] [--dir TMP] [--expect-clean] [--fresh-minutes N]" >&2; exit 2 ;;
  esac
done
if [ -z "$DIR" ]; then
  DATA="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data 2>/dev/null)" || { echo "cannot find the app container for $BUNDLE on $DEVICE (is it installed and the Simulator booted?)" >&2; exit 2; }
  DIR="$DATA/tmp"
fi
[ -d "$DIR" ] || { echo "no tmp folder at $DIR" >&2; exit 2; }

now=$(date +%s)
stream_count=0; stream_kb=0; wk_count=0; wk_kb=0; wk_fresh=0
report() { # folder label
  local folder="$1" label="$2" item name kb mtime age
  [ -d "$folder" ] || return 0
  for item in "$folder"/FileSystemWritableStream* "$folder"/WKFileUploadPanel-*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    name="$(basename "$item")"
    kb=$(du -sk "$item" 2>/dev/null | awk '{print $1}'); kb=${kb:-0}
    mtime=$(stat -f %m "$item" 2>/dev/null || echo "$now"); age=$(( (now - mtime) / 60 ))
    case "$name" in
      FileSystemWritableStream*) stream_count=$((stream_count+1)); stream_kb=$((stream_kb+kb)); echo "STREAM  $label/$name  ${kb} KB  idle ${age} min" ;;
      WKFileUploadPanel-*)       wk_count=$((wk_count+1)); wk_kb=$((wk_kb+kb))
        if [ "$age" -lt "$FRESH" ]; then wk_fresh=$((wk_fresh+1)); echo "WKPANEL $label/$name  ${kb} KB  age ${age} min  (fresh)"; else echo "WKPANEL $label/$name  ${kb} KB  age ${age} min"; fi ;;
    esac
  done
}
report "$DIR" "tmp"
report "$DIR/com.apple.WebKit.Networking" "tmp/com.apple.WebKit.Networking"
total_kb=$(du -sk "$DIR" 2>/dev/null | awk '{print $1}')
echo "SUMMARY tmp total ${total_kb:-0} KB; FileSystemWritableStream* ${stream_count} (${stream_kb} KB); WKFileUploadPanel-* ${wk_count} (${wk_kb} KB), fresh under ${FRESH} min: ${wk_fresh}"
if [ "$EXPECT" -eq 1 ] && { [ "$stream_count" -gt 0 ] || [ "$wk_fresh" -gt 0 ]; }; then
  echo "NOT CLEAN: ${stream_count} stream file(s) and ${wk_fresh} fresh upload copy(ies) remain" >&2
  exit 1
fi
exit 0

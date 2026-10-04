#!/bin/zsh
# iOS Simulator UI test run for the mobile shell (owner OK: terminal xcodebuild is allowed for the iOS Simulator app only).
#   mobile-sim-run.sh <label> <UITestClass> [<UITestClass> ...]
# Run it THROUGH the heavy lock, never during a desktop native timing round:
#   IRIS_HEAVY_PRIO=1 iris-heavy-lock.sh nice -n 10 bin/mobile-sim-run.sh keepcount-1 KeepCountUITests StorageUITests
# One Simulator only: iPhone 18 Pro 9A18F112-FCAF-4B0C-8E6B-4FAEE7F42275. Result bundle: scratchpad/sim-<label>.xcresult
LABEL=$1; shift
[[ -z "$LABEL" || $# -lt 1 ]] && { echo "usage: $0 <label> <UITestClass>..."; exit 64; }
S=${IRIS_SCRATCH:-/tmp/iris-scratch}
SIM=9A18F112-FCAF-4B0C-8E6B-4FAEE7F42275
FREE_KB=$(df -k /System/Volumes/Data | tail -1 | awk '{print $4}')
(( FREE_KB < 8000000 )) && { echo "disk under 8 GB free, stopping"; exit 75; }
# only the one authorized Simulator may be booted
for u in $(xcrun simctl list devices booted | grep -o '[0-9A-F]\{8\}-[0-9A-F-]\{27\}'); do
  [[ "$u" != "$SIM" ]] && { echo "shutting down extra simulator $u"; xcrun simctl shutdown $u; }
done
RB=$S/sim-$LABEL.xcresult
rm -rf "$RB"
ARGS=()
for c in "$@"; do ARGS+=(-only-testing:IrisMobileShellUITests/$c); done
xcodebuild test -project ${IRIS_REPO:-$PWD}/mobile-shell/native/IrisMobileShellApp/IrisMobileShellApp.xcodeproj \
  -scheme IrisMobileShellUITests -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath $S/dd-mobile-wfm-r1 -parallel-testing-enabled NO \
  -resultBundlePath "$RB" "${ARGS[@]}"
echo "sim-run exit=$? result=$RB"

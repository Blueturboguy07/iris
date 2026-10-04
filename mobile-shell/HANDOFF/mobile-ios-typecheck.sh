#!/bin/zsh
# iOS-simulator typecheck of the mobile shell (Core module + Host + App entry), no xcodebuild, no signing.
#   mobile-ios-typecheck.sh [repo-root]   default ${IRIS_REPO:-$PWD}
ROOT=${1:-${IRIS_REPO:-$PWD}}
N=$ROOT/mobile-shell/native
HERE=${0:A:h}
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
T=arm64-apple-ios18.4-simulator
OUT=$(mktemp -d -t mobile-ios-tc)
LOG=$OUT/log.txt
{
  echo "== Core module"
  xcrun --sdk iphonesimulator swiftc -emit-module -module-name IrisMobileShellCore -parse-as-library \
    -sdk "$SDK" -target $T -swift-version 5 -emit-module-path $OUT/IrisMobileShellCore.swiftmodule \
    $N/Sources/IrisMobileShellCore/**/*.swift && echo core-ok
  echo "== Host typecheck"
  printf 'import Foundation\nextension Bundle { static var module: Bundle { .main } }\n' > $OUT/BundleModuleShim.swift
  xcrun --sdk iphonesimulator swiftc -typecheck -module-name IrisMobileShellHost -parse-as-library \
    -sdk "$SDK" -target $T -swift-version 5 -I $OUT \
    $N/Sources/IrisMobileShellHost/**/*.swift $OUT/BundleModuleShim.swift && echo host-ok
} > $LOG 2>&1
rc=$?
errs=$(grep -c ' error: ' $LOG)
echo "mobile-ios-typecheck exit=$rc errors=$errs log=$LOG"; grep ' error: ' $LOG | head -30; grep -E '^(core|host)-ok' $LOG
[[ $errs -eq 0 ]] && grep -q host-ok $LOG

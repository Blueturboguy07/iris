#!/bin/zsh
# DEBUG-config variant of mobile-ios-typecheck.sh (adds -D DEBUG to both
# swiftc invocations), for the mobile-integrator-A2 gate that asks for both
# the release/normal config and -D DEBUG. Same structure as the original
# script; not committed into the repo (scratch-only wrapper).
ROOT=${1:-${IRIS_REPO:-$PWD}}
N=$ROOT/mobile-shell/native
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
T=arm64-apple-ios18.4-simulator
OUT=$(mktemp -d -t mobile-ios-tc-debug)
LOG=$OUT/log.txt
{
  echo "== Core module (DEBUG)"
  xcrun --sdk iphonesimulator swiftc -emit-module -module-name IrisMobileShellCore -parse-as-library \
    -sdk "$SDK" -target $T -swift-version 5 -D DEBUG -emit-module-path $OUT/IrisMobileShellCore.swiftmodule \
    $N/Sources/IrisMobileShellCore/**/*.swift && echo core-ok
  echo "== Host typecheck (DEBUG)"
  printf 'import Foundation\nextension Bundle { static var module: Bundle { .main } }\n' > $OUT/BundleModuleShim.swift
  xcrun --sdk iphonesimulator swiftc -typecheck -module-name IrisMobileShellHost -parse-as-library \
    -sdk "$SDK" -target $T -swift-version 5 -D DEBUG -I $OUT \
    $N/Sources/IrisMobileShellHost/**/*.swift $OUT/BundleModuleShim.swift && echo host-ok
} > $LOG 2>&1
rc=$?
errs=$(grep -c ' error: ' $LOG)
echo "mobile-ios-typecheck-debug exit=$rc errors=$errs log=$LOG"; grep ' error: ' $LOG | head -30; grep -E '^(core|host)-ok' $LOG
[[ $errs -eq 0 ]] && grep -q host-ok $LOG

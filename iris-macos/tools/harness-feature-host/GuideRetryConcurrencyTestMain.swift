// Standalone runner for GuideSessionControllerRetryConcurrencyTests.swift.
//
// This file is intentionally not part of build.mjs: it is an @main entry point
// for a separate executable linked against an already-built IrisHarnessNative
// module. Compile it together with the test file and pass the native module
// directory as NATIVE_MODULE_DIR, for example:
//
//   xcrun swiftc -parse-as-library -whole-module-optimization -Onone \
//     -swift-version 5 -default-isolation MainActor \
//     -D IRIS_HARNESS_HEADLESS -D IRIS_HARNESS_STANDALONE -enable-testing \
//     -load-plugin-library \
//     /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib \
//     -I "$NATIVE_MODULE_DIR" -L "$NATIVE_MODULE_DIR" \
//     -lIrisHarnessNative -Xlinker -rpath -Xlinker "$NATIVE_MODULE_DIR" \
//     -Xlinker -rpath -Xlinker \
//     /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
//     -F /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
//     -framework Testing \
//     iris-macos/leanring-buddyTests/GuideSessionControllerRetryConcurrencyTests.swift \
//     iris-macos/tools/harness-feature-host/GuideRetryConcurrencyTestMain.swift \
//     -o /tmp/guide-retry-concurrency-tests
//   /tmp/guide-retry-concurrency-tests
//
// The test file's IRIS_HARNESS_STANDALONE import selects IrisHarnessNative;
// the normal Xcode test target continues to import Iris.

import Testing

@main
struct GuideRetryConcurrencyTestMain {
    static func main() async {
        let _: Never = await Testing.__swiftPMEntryPoint(passing: nil)
    }
}

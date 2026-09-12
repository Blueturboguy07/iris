import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';

// Use an existing headless module built by build.mjs. This script never builds
// or installs the GUI app, changes a registry, or makes model calls.
const destination = realpathSync(process.argv[2] ?? '');
if (!path.basename(destination).startsWith('iris-harness-host-')
    || !existsSync(path.join(destination, 'IrisHarnessNative.swiftmodule'))) {
  throw new Error('Provide the existing iris-harness-host-* module directory.');
}
const developer = execFileSync('xcode-select', ['-p'], { encoding: 'utf8' }).trim();
const frameworks = path.join(developer, 'Platforms/MacOSX.platform/Developer/Library/Frameworks');
const macros = path.join(developer,
  'Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib');
const sources = [
  'iris-macos/leanring-buddyTests/GuideSessionControllerRetryConcurrencyTests.swift',
  'iris-macos/leanring-buddyTests/GuideSessionControllerStaleWorkTests.swift',
  'iris-macos/leanring-buddyTests/GuideAutopilotRunnerTests.swift',
  'iris-macos/leanring-buddyTests/GuideAutopilotShellSessionTests.swift',
  'iris-macos/tools/harness-feature-host/GuideRetryConcurrencyTestMain.swift',
];
const executable = path.join(destination, 'guide-regressions');
const compiled = spawnSync('xcrun', ['swiftc', '-parse-as-library',
  '-whole-module-optimization', '-Onone', '-swift-version', '5',
  '-default-isolation', 'MainActor', '-D', 'IRIS_HARNESS_HEADLESS',
  '-D', 'IRIS_HARNESS_STANDALONE', '-enable-testing',
  '-load-plugin-library', macros, '-I', destination, '-L', destination,
  '-lIrisHarnessNative', '-Xlinker', '-rpath', '-Xlinker', destination,
  '-Xlinker', '-rpath', '-Xlinker', frameworks, '-F', frameworks,
  '-framework', 'Testing', ...sources, '-o', executable],
{ encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, timeout: 120_000 });
writeFileSync(path.join(destination, 'guide-regressions-compile.log'),
  (compiled.stdout ?? '') + (compiled.stderr ?? ''));
if (compiled.status !== 0) {
  console.log(compiled.stderr ?? compiled.error?.message ?? 'Compiler failed');
  process.exit(compiled.status ?? 1);
}
const executed = spawnSync(executable, [], {
  encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: 180_000,
});
const output = (executed.stdout ?? '') + (executed.stderr ?? '');
writeFileSync(path.join(destination, 'guide-regressions-run.log'), output);
const hash = createHash('sha256');
for (const source of sources) hash.update(source).update(readFileSync(source));
console.log(JSON.stringify({
  exit: executed.status,
  error: executed.error?.message ?? null,
  testSourceHash: hash.digest('hex'),
  moduleHash: createHash('sha256')
    .update(readFileSync(path.join(destination, 'libIrisHarnessNative.dylib'))).digest('hex'),
  summaries: output.split('\n').filter(line => /Test run with|recorded an issue|Suite .* failed/.test(line)),
  log: path.join(destination, 'guide-regressions-run.log'),
}));
process.exitCode = executed.status ?? 1;

import { execFileSync, spawnSync } from 'node:child_process';
import { realpathSync, statSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';

// Generated compiler output belongs only in a caller-created scratch folder.
const destination = realpathSync(process.argv[2] ?? '');
if (!statSync(destination).isDirectory() || !path.basename(destination).startsWith('iris-harness-host-')) {
  throw new Error('Provide a fresh iris-harness-host-* scratch directory.');
}
const nativeSources = execFileSync('rg', ['--files', 'iris-macos/leanring-buddy'], {encoding: 'utf8'})
  .trim().split('\n').filter(file => file.endsWith('.swift') && !file.endsWith('/leanring_buddyApp.swift'))
  .map(file => path.resolve(file)).sort();
const executable = path.join(destination, 'iris-harness-feature-host');
const sourceHash = createHash('sha256');
sourceHash.update(readFileSync(import.meta.filename));
sourceHash.update(execFileSync('xcrun', ['swiftc', '--version']));
for (const file of nativeSources) sourceHash.update(file).update(readFileSync(file));
const digest = sourceHash.digest('hex');
const stamp = path.join(destination, 'native-source-hash.txt');
const flags = ['-whole-module-optimization', '-Onone', '-swift-version', '5', '-default-isolation', 'MainActor', '-D', 'IRIS_HARNESS_HEADLESS'];
let compilerOutput = '';
if (!existsSync(stamp) || readFileSync(stamp, 'utf8') !== digest) {
  const library = spawnSync('xcrun', ['swiftc', ...flags, '-enable-testing', '-module-name', 'IrisHarnessNative',
    '-emit-library', '-emit-module', '-emit-module-path', path.join(destination, 'IrisHarnessNative.swiftmodule'),
    ...nativeSources, '-o', path.join(destination, 'libIrisHarnessNative.dylib'),
    '-Xlinker', '-install_name', '-Xlinker', '@rpath/libIrisHarnessNative.dylib'],
    {encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
  compilerOutput += (library.stdout ?? '') + (library.stderr ?? '');
  writeFileSync(path.join(destination, 'native-compiler.log'), compilerOutput);
  if (library.status !== 0) {
    console.log(compilerOutput.split('\n').filter(line => line.includes('error:')).join('\n'));
    process.exit(library.status ?? 1);
  }
  writeFileSync(stamp, digest);
}
const result = spawnSync('xcrun', ['swiftc', '-parse-as-library', ...flags, '-I', destination, '-L', destination,
  '-lIrisHarnessNative', '-Xlinker', '-rpath', '-Xlinker', destination,
  'iris-macos/tools/harness-feature-host/HarnessFeatureHost.swift',
  'iris-macos/tools/harness-feature-host/UsageAttributionChecks.swift',
  'iris-macos/tools/harness-feature-host/HarnessReviewReserveChecks.swift',
  'iris-macos/tools/harness-feature-host/VerificationDiagnosticChecks.swift',
  'iris-macos/tools/harness-feature-host/RepairTestCheckpointChecks.swift',
  'iris-macos/tools/harness-feature-host/CommandFreshnessChecks.swift',
  'iris-macos/tools/harness-feature-host/RepairWindowChecks.swift', '-o', executable],
  {encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
compilerOutput += (result.stdout ?? '') + (result.stderr ?? '');
writeFileSync(path.join(destination, 'compiler.log'), compilerOutput);
console.log(JSON.stringify({exit: result.status, executable, sourceCount: nativeSources.length,
  warnings: compilerOutput.split('\n').filter(line => line.includes('warning:')).length}));
if (result.status !== 0) console.log(compilerOutput.split('\n').filter(line => line.includes('error:')).join('\n'));
process.exitCode = result.status ?? 1;

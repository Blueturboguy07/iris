import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import path from 'node:path';

// An offline environment adapter, not an application build or installation.
// Keep all Test-profile paths below this newly allocated private directory.
const root = mkdtempSync('/Users/Shared/iris-unadmitted-env-');
const sources = execFileSync('rg', ['--files', 'iris-macos/leanring-buddy'], {encoding: 'utf8'})
  .trim().split('\n').filter(file => file.endsWith('.swift')
    && !file.endsWith('/leanring_buddyApp.swift')
    && !file.endsWith('/IrisTestEnvironment.swift')
    && !file.endsWith('/MaintainTierCFixer.swift')).map(file => path.resolve(file)).sort();
const nativeRoot = 'iris-macos/leanring-buddy/';
const environmentSource = readFileSync(nativeRoot + 'IrisTestEnvironment.swift', 'utf8');
const rootProperty = environmentSource.indexOf('    private static var applicationSupportRootDirectory: URL {');
if (rootProperty < 0) throw new Error('Environment adapter anchor changed');
const adapter = environmentSource.slice(0, rootProperty)
  .replace('identity(forBundleIdentifier: Bundle.main.bundleIdentifier)', 'testIdentity') + `
    private static var applicationSupportRootDirectory: URL {
        URL(fileURLWithPath: ${JSON.stringify(root)}).appendingPathComponent("Support")
    }
    private static var logsRootDirectory: URL {
        URL(fileURLWithPath: ${JSON.stringify(root)}).appendingPathComponent("Logs")
    }
}
`;
const adapterPath = path.join(root, 'IrisTestEnvironment.swift');
writeFileSync(adapterPath, adapter);
const currentFixer = readFileSync(nativeRoot + 'MaintainTierCFixer.swift', 'utf8');
const shortcutStart = currentFixer.indexOf('        // Exact input admission can refuse the first repair before transport.');
const shortcutEnd = currentFixer.indexOf('        rejectedReviewAwaitingRepair = nil', shortcutStart);
if (shortcutStart < 0 || shortcutEnd < shortcutStart) throw new Error('Shortcut anchors changed');
const beforeFixer = currentFixer.slice(0, shortcutStart) + currentFixer.slice(shortcutEnd);
const flags = ['-whole-module-optimization', '-Onone', '-swift-version', '5',
  '-default-isolation', 'MainActor', '-D', 'IRIS_TEST_BUILD'];
function execute(command, arguments_, log, options = {}) {
  const result = spawnSync(command, arguments_, {encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, ...options});
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  writeFileSync(log, output);
  return {status: result.status, output};
}
console.log(JSON.stringify({root, mode: 'offline Test environment adapter; before replay disables only the shortcut'}));
for (const [name, fixer] of [['before', beforeFixer], ['after', currentFixer]]) {
  const destination = path.join(root, name);
  mkdirSync(destination);
  const fixerPath = path.join(destination, 'MaintainTierCFixer.swift');
  writeFileSync(fixerPath, fixer);
  const library = execute('xcrun', ['swiftc', ...flags, '-enable-testing', '-module-name', 'IrisHarnessNative',
    '-emit-library', '-emit-module', '-emit-module-path', path.join(destination, 'IrisHarnessNative.swiftmodule'),
    ...sources, adapterPath, fixerPath, '-o', path.join(destination, 'libIrisHarnessNative.dylib'),
    '-Xlinker', '-install_name', '-Xlinker', '@rpath/libIrisHarnessNative.dylib'], path.join(destination, 'library.log'));
  if (library.status !== 0) { console.log(library.output.split('\n').filter(line => line.includes('error:')).join('\n')); process.exit(1); }
  const executable = path.join(destination, 'checks');
  const built = execute('xcrun', ['swiftc', '-parse-as-library', ...flags, '-I', destination, '-L', destination,
    '-lIrisHarnessNative', '-Xlinker', '-rpath', '-Xlinker', destination,
    'iris-macos/tools/harness-feature-host/UnadmittedRepairChecks.swift', '-o', executable], path.join(destination, 'compile.log'));
  if (built.status !== 0) { console.log(built.output); process.exit(1); }
  const checked = execute(executable, [], path.join(destination, 'checks.log'),
    {env: {...process.env, IRIS_UNADMITTED_FIXTURE_ROOT: root}, timeout: 240_000});
  console.log(JSON.stringify({name, status: checked.status, log: path.join(destination, 'checks.log')}));
  console.log(checked.output);
  if (name === 'before' && (checked.status !== 1
      || !checked.output.includes('unadmittedRepair expected 1 native review request(s), got 2'))) {
    throw new Error('Before replay did not reproduce the specific duplicate-review assertion');
  }
  if (name === 'after' && (checked.status !== 0
      || !checked.output.includes('UNADMITTED REPAIR CHECKS PASS: 5'))) process.exitCode = 1;
}

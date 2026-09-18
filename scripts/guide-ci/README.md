# guide-ci — every guide command, on a fresh Mac and a fresh Windows machine

`.github/workflows/guide-ci.yml` fetches every install guide publik serves
(`/api/iris/apps` → `/api/iris/guides/<slug>`), fans out one job per
(guide, platform, target) branch, types each command into the shell Iris
uses on that platform, and folds the results into a scoreboard.

Run it from the Actions tab (**guide-ci → Run workflow**) or:

    gh workflow run guide-ci -R Blueturboguy07/iris -f slugs=cue,openascii -f platforms=macos,windows
    gh run watch -R Blueturboguy07/iris

## What each runner mirrors

**macOS — `run-macos.cjs`** mirrors `iris-macos/…/GuideAutopilotShellSession.swift`
and `GuideAutopilotRunner.swift`: one persistent login+interactive zsh, each
command typed as top-level input with an in-band sentinel for its exit status,
`cd <workingDirectory>` before a step that declares one (refused for system
folders and non-plain paths), a `watch.sensitive` step handed back untyped,
a dev-server command started in a side session and its localhost URL probed,
the risk gate's catastrophe floor enforced, the no-grant tier recorded, and
Iris's 900 s per-command deadline recorded as `exceededIrisDeadline`.

**Windows — `run-windows.cjs`** does not re-implement anything: it compiles
`iris-windows` from the `windows-parity` branch on the runner and drives the
real modules — `resolveGuideRecipe` (fetch + derive, including the POSIX →
PowerShell clone-idiom translation and winget agreement flags),
`runSetupDetour` with the registry-refreshing tool probe, `PowerShellSession`
(one `powershell.exe -EncodedCommand` per step, cwd threaded), and
`AutopilotRunner` with the autonomy grant on. Reader steps are acknowledged
automatically; a surfaced failure is recorded and the run continues past it.

## What it cannot see

The eye and pointing, the watch loop's visual rung, the model fix ladder,
permission dialogs, installers that need a click, and anything behind a
sign-in or an API key. Those steps are recorded as reader steps; a command
that then fails because a key is missing shows up as red with the reason in
its output tail — read the scoreboard's detail section before calling it a
guide bug.

A GitHub runner is fresh but not bare: Homebrew, Node, Rust, Xcode, Git,
Python and CMake are preinstalled, so the prerequisite-install detours are
exercised only on the Windows side (winget) and only when a tool is missing.

## Local use

    node scripts/guide-ci/run-macos.cjs --slug cue --home /tmp/scratch-home --out /tmp/results
    node scripts/guide-ci/report.cjs --in /tmp/results

`--home` points the shell's `~` at a scratch folder so nothing in your real
home is touched. The Windows runner needs a compiled `iris-windows/dist`
(`npm run compile`) and real PowerShell, so it only runs on Windows.

## Result files

One JSON per branch (`<slug>--<platform>--<target>.json`) with the runner
environment, every step's disposition (`ran`, `long-running`, `reader`,
`handed-back-sensitive`, `open`, `noop`, `folder-refused`, `refused-*`,
`setup-not-run`), exit code, duration, output tail, risk tiers, link status
and tool checks; per-step logs under `logs/`; `SCOREBOARD.md` from
`report.cjs`.

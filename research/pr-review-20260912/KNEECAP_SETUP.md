# Kneecap setup: current evidence and remaining work

## What actually failed

The recorded guide reached a source-pin guard and got a nonzero exit. Later,
repeated retry/environment requests were refused because the previous shell
command had not finished. The guide subsequently reached phone Run guidance
despite unresolved prerequisites. A timeout later interrupted the shell.
The output included a multiline shell continuation prompt; its exact initiating
cause is not established.

The current source inspection found a concrete contributing race: Try again
could create multiple asynchronous retries without acquiring ownership before
the first wait. Skip could advance during that wait, and a late retry could
act on a different step. The correction binds a retry to its runner and step,
rejects duplicate/Skip operations while pending, cancels on navigation or Stop,
and requires a successful environment refresh before sending the command.
Its test and installation status must be reported separately from this analysis.

## Existing folders

Fresh read-only check, September 12 at approximately 05:07 UTC:

- The [public version-5 guide](https://publikhq.com/api/iris/guides/kneecap?version=5) is `pilot`, with Mac + iPhone step 6 named `pin-source`. It explicitly runs in `~/kneecap`, not another downloaded copy. Guide body SHA-256: `5c5b9b2e5d8fac0a56192e4278ef4f3d868acf8a7c2121bef58e5507e2046af1`.
- Its exact command has SHA-256 `6c924948a5c4fff369a19868c9f6f6324f7e64eb182934c1c86190d778efc1d0`. It first checks the normalized origin URL, then refuses any `git status --porcelain` output, then would check out `fc48ba487a1e0d0cd10b30d6600acd2895ffdbed`. The checkout command was not executed during diagnosis.
- The expected home-directory checkout exists with `.git`, the matching upstream origin, and HEAD already at that exact guide commit. The present refusal is a dirty working tree: modified `bun.lock`, plus untracked Finder metadata under `packages` and `packages/editor-core`. No files were reset, stashed, renamed, deleted or reinstalled.
- Bun and Node respond in the diagnostic shell. Dependency directories, mobile web assets and the iOS Xcode project exist. Presence is not dependency integrity, a current successful build, or proof that the older Iris terminal had the same PATH.
- The Xcode project contains signing configuration, but there is no observed usable signing identity, trusted physical phone, successful device build or installation from this check.

This distinguishes the current dirty-source refusal from the historical model claim that `.git` was absent. The latter is not established by the present filesystem state. A retry ownership fix cannot resolve local changes or device-signing prerequisites by itself.

A later inspection found an existing checkout with local changes. That does
not prove which condition triggered the earlier source-pin guard. Preserve all
existing folders and edits. Do not reset, stash, move or delete a checkout merely
to make an installation test pass. A clean-copy refusal must name the failed
check and offer a preservation-first route; it must not say the folder is absent.

## Phone route

The repository documents a Mac-to-iPhone source-build route: dependencies,
mobile build, Capacitor sync, Xcode project, signing team and bundle identifier,
connected trusted device, Run, then device developer trust. Those are meaningful
manual platform requirements, not proof of a published signed installer.
Documentation is inconsistent about the mobile app's maturity; inspect the
actual project and current guide rather than claiming a phone build is ready.

No physical phone installation or signed-release acceptance is established by
this package. Iris Test currently blocks marketplace installation, protecting
normal apps. Controller/native-window fixtures can test the retry mechanism;
they cannot be presented as a complete Kneecap installation through Iris Test.

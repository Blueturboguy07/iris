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

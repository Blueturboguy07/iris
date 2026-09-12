# Isolated Iris harness lab

This worktree is the user's separate experimental branch, `codex/iris-harness-lab`.
The working Iris app and usability checkout are not experimental targets.

- Begin from the source snapshot commit `18dd318987c4e00809680a2e9ed8197ec5117ee7`, copied from the 25.27 working source. Preserve the baseline commit for comparisons.
- Current phase: implement the general-purpose harness promptly. Initial route is Astra Medium planning with Astra Low implementation. Luna XHigh comparison and automatic routing are deferred, not delivery prerequisites. On September 8 the user authorized a separate searchable Iris Test application after acceptance. This supersedes the earlier source-only installation restriction, not the isolation requirements below.
- Do not install or launch this worktree's app against the normal Iris profile. Separate source does not isolate macOS preferences, Keychain, application data or target-app delivery.
- Before any experimental app run, provide a separate application identity, state directory, recovery store and fixture-project registry. Disable real publishing, changelog posting and replacement of normal installed apps. Validate those boundaries first.
- Do not modify the separately maintained Iris checkout, installed Iris app,
  WhimprFlow checkout, or older harness-research checkout from this worktree's
  research tasks.
- Before paid model calls or live cross-app paste tests, name fixture targets, bound calls and validate side-effect isolation. A broad comparison runner is not required. Do not interpret unit tests as live feature success or model-efficiency evidence.
- Preserve credential isolation, path confinement, cancellation, dirty-source protection, dependency consent and recoverable delivery. Do not make the harness look faster by bypassing its safety boundaries.
- Keep the existing eye, palette and compact UI. This is a harness experiment, not another visual redesign.
- Follow the additional native-app instructions under `iris-macos/AGENTS.md`. Do not run terminal xcodebuild.
- Never use em dashes in new prose, code or comments.

See `research/harness-v2/PLAN.md` for the current proposal and open user decisions.

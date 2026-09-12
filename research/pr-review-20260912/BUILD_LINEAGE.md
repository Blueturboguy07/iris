# Build and source lineage

This is a draft snapshot, not a release and not an upstream integration.

| Identity | Value |
| --- | --- |
| Original upstream base | `84dd908aa6d3c529f5abfd73158a3781a34c9c15` |
| Latest observed upstream main | `945d135` |
| Local lab history tip before snapshot | `98369a7012680291080b7a2d18ce1134501fdd80` |
| Installed Test dylib SHA-256 | `9fb3ea4e25ff4a5e082f25bc17605f99d3606cbb3e7b9db9818bf3ad95d76ab0` |
| Recorded compiled native source aggregate | `cefdbd032ec94c7ead28c1c7f2b07edda48e7c825b437e5e095a4e140ea9f851` |

The native aggregate includes 174 Swift files, the host build script, compiler
version output and canonical source names. Recomputing it with the original
name normalization against the review snapshot matched exactly before public
test/document portability edits. Absolute machine names are intentionally not
published. The main app entry file was outside that host aggregate; its snapshot
is copied from the same lab source used by the GUI build.

The installed GUI build completed with zero errors and 130 warnings. Signing
and installed artifact digest were checked. Later native-host builds are not
new installed GUI builds. Compiler warnings remain and are not hidden.

The snapshot also includes technical WIP, standalone checks and test utilities.
Their presence does not mean every utility was run or every edge case was tested.
Portability edits to test helpers are reviewed separately and do not alter the
174 production Swift files. No raw model transcripts, profiles, compiled app,
private fixture data, or original lab commit history is uploaded.

The baseline still has the installer retry race. Its correction is a separate
follow-up, with its own execution/build/UI status. Do not attribute that fix to
the installed artifact above until a new artifact has been built and accepted.

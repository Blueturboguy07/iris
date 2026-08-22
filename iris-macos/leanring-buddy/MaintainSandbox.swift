//
//  MaintainSandbox.swift
//  leanring-buddy
//
//  The jail Tier C's exploration and edits run inside. Novel-fix commands
//  come from a model reasoning over the user's own repo — weaker provenance
//  than a version-pinned guide command — so the risk gate is not enough on
//  its own; the sandbox is the compensating boundary the security doc
//  promises.
//
//  Built on macOS's own `sandbox-exec` (Seatbelt), the same mechanism Claude
//  Code and Codex CLI use: no install, ships with the OS. The profile:
//    - allows reads broadly (a build has to read toolchains, headers, caches)
//    - allows the two process-info reads (`process-info-pidinfo`,
//      `process-info-listpids`) that let `ps`, `lsof`, and `sample` see other
//      processes. Diagnosing a hang means asking what the running app is
//      doing, and without these the agent gets an empty process table and
//      concludes, wrongly, that the app is not running. They only READ
//      process metadata — no signalling, no injection, no writes.
//    - allows writes ONLY under the repo root and the system temp dir
//    - DENIES all network by default — the exploration/edit phase must not
//      exfiltrate or fetch-and-run. Dependency resolution that genuinely
//      needs the network happens in the SEPARATE verification build, run
//      through the ordinary runner outside this jail, after the edit is made.
//
//  Seatbelt cannot allowlist network by host, so the split is deliberate:
//  think-and-edit with no network, then build-and-test with network, never
//  both at once. `.git` is stripped before the loop runs (the caller's job)
//  so a clone that already contains the upstream fix can't be mined for the
//  answer — Cursor measured that at 9% of an agent's "solutions".
//

import Foundation

enum MaintainSandbox {

    /// The kernel-canonical path, via realpath(3). Seatbelt enforces on the
    /// fully-resolved real path — `/tmp` IS `/private/tmp`, and Foundation's
    /// `resolvingSymlinksInPath` resolves the wrong way (`/private/tmp` →
    /// `/tmp`), which silently allows nothing. realpath goes toward /private,
    /// which is what the kernel actually checks.
    private static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A Seatbelt profile string confining writes to `repoRootPath` and the
    /// temp dir, denying network entirely. Passed to `sandbox-exec -f`.
    static func writeConfinedNoNetworkProfile(repoRootPath: String) -> String {
        let root = canonicalPath(repoRootPath)
        let tempDir = canonicalPath(NSTemporaryDirectory())
        // Literal subpaths, quoted; a repo path with a quote in it is not a
        // thing that happens, and the standardized path has no traversal.
        return """
        (version 1)
        (deny default)
        (allow process-fork)
        (allow process-exec)
        (allow sysctl-read)
        (allow mach-lookup)
        (allow file-read*)
        (allow process-info-pidinfo)
        (allow process-info-listpids)
        (deny network*)
        (allow file-write*
          (subpath "\(root)")
          (subpath "\(tempDir)")
          (subpath "/dev"))
        """
    }

    /// Wraps a command so it runs under the profile. The profile is written
    /// to a temp file because `-p` inline profiles hit shell-quoting hell;
    /// `-f` takes a file and is clean. The file is the caller's to clean up
    /// via the returned path.
    static func jailedInvocation(
        forCommand commandText: String, repoRootPath: String
    ) -> (invocation: String, profilePath: String)? {
        let profile = writeConfinedNoNetworkProfile(repoRootPath: repoRootPath)
        let profilePath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-sandbox-\(UUID().uuidString).sb")
        guard (try? profile.write(toFile: profilePath, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        // The inner command still runs through zsh -c (inside the jail) so
        // ordinary shell syntax works; sandbox-exec confines the whole tree.
        let escaped = commandText.replacingOccurrences(of: "'", with: "'\\''")
        return (
            "/usr/bin/sandbox-exec -f '\(profilePath)' /bin/zsh -c '\(escaped)'",
            profilePath
        )
    }

    /// True when sandbox-exec is present (it is, on every supported macOS,
    /// but deprecated — so this is checked, and its absence degrades Tier C
    /// to "not available" rather than running a command unjailed).
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
    }
}

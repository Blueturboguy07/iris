//
//  MaintainBuildScriptGuard.swift
//  leanring-buddy
//
//  Pure detection of build-script files in a change.
//
//  The jail confines the EXPLORATION loop: every model command runs under
//  Seatbelt with no network and writes confined to the repo. But verification
//  (build + suite) runs OUTSIDE that jail, networked, through the ordinary
//  runner — it has to, since dependency resolution needs the network. That is
//  safe only because the model authors SOURCE, never the build command string
//  (the code-vs-command authorship split MaintainShellRunner leans on).
//
//  There is one hole in that split: a file the fixed build command EXECUTES.
//  `cargo build` runs `build.rs`. `npm run build` runs `package.json`
//  lifecycle scripts. `make` runs a `Makefile`. If the model EDITED one of
//  those in the loop, the un-jailed verification build then runs model-authored
//  code with the network and no write-confinement — a straight jail escape,
//  and it happens BEFORE the human ever sees the diff.
//
//  So a model edit to a build-script file must be caught BEFORE that build
//  runs. This file is only the pure detector; the coordinator (and the
//  on-demand entry in MaintainTierCFixer) decide what to do with a hit —
//  block outright, or surface it for an explicit, informed approval.
//

import Foundation

enum MaintainBuildScriptGuard {

    /// The subset of `changedPaths` (repo-relative) that are build-script
    /// files — the files a build/package step executes, and therefore the
    /// ones a model must not silently edit before an un-jailed build.
    static func buildScriptFilePaths(inChangedPaths changedPaths: [String]) -> [String] {
        changedPaths.filter { isBuildScriptFile($0) }
    }

    /// True when one repo-relative path is a file the build toolchain runs as
    /// code, rather than compiles as source. Matched on basename/suffix so it
    /// holds wherever the file sits in the tree.
    static func isBuildScriptFile(_ path: String) -> Bool {
        let lowercasedPath = path.lowercased()
        let basename = (lowercasedPath as NSString).lastPathComponent

        // Exact filenames whose very presence means "the build runs this":
        //   build.rs        — a Cargo build script, arbitrary Rust at build time
        //   package.json    — npm preinstall/postinstall/build lifecycle scripts
        //   Cargo.toml      — [build-dependencies] and `build = "…"` pull in code
        //   Makefile        — make targets
        //   *file.js runners— grunt/gulp task files executed by their runner
        let executedFilenames: Set<String> = [
            "build.rs",
            "package.json",
            "cargo.toml",
            "makefile",
            "gnumakefile",
            "rakefile",
            "gemfile",
            "gruntfile.js",
            "gulpfile.js",
            "cmakelists.txt",
        ]
        if executedFilenames.contains(basename) { return true }

        // Suffixes the build machinery executes:
        //   .podspec        — CocoaPods runs it as Ruby
        //   .gyp / .gypi    — node-gyp native build config
        //   .cmake          — included and evaluated by CMake
        //   .mk             — Makefile fragments pulled in by `include`
        let executedSuffixes = [".podspec", ".gyp", ".gypi", ".cmake", ".mk"]
        if executedSuffixes.contains(where: { lowercasedPath.hasSuffix($0) }) { return true }

        return false
    }
}

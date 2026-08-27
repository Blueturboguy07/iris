//
//  CodexCLILogin.swift
//  leanring-buddy
//
//  "Sign in with Codex" — the OpenAI-side sibling of `ClaudeCodeLogin.swift`.
//  The reader authenticates Iris's model work with their existing ChatGPT
//  account by way of the Codex CLI, instead of pasting a raw `sk-…` API key.
//
//  WHY THIS FILE DOES NOT LOOK LIKE ClaudeCodeLogin.swift
//
//  The Claude path scrapes a long-lived `sk-ant-oat…` token out of
//  `claude setup-token` and stores it in the Keychain, because that token is a
//  real credential for `api.anthropic.com` — the same host a pasted API key
//  goes to. Codex has no equivalent. Its ChatGPT login mints a SHORT-LIVED
//  access token (hours) plus a rotating refresh token, and those are NOT
//  api.openai.com credentials at all: they address OpenAI's Codex backend, with
//  an account-id header and an originator the CLI stamps. Verified 2026-08-26:
//  the stored token is useless against `api.openai.com/v1/*`.
//
//  So Iris does not hold this credential. It drives the CLI, which owns the
//  token, performs its own refresh, and is the party OpenAI actually issued it
//  to. Three consequences worth stating plainly, because they are a DIFFERENCE
//  from the Claude route and not an oversight:
//
//    1. NOTHING is stored in the Keychain here. There is no `KeychainSecretKind`
//       for Codex. The credential lives in `~/.codex/auth.json`, mode 0600,
//       written by the CLI. Iris reads it only to answer "is a login present?"
//       and never copies the token anywhere.
//    2. Refresh is free and correct — the CLI does it. The Claude path
//       deliberately does NOT implement refresh (see its notes) and degrades to
//       a 401 when an imported login lapses. This path has no such cliff.
//    3. There is no reverse-engineered endpoint or beta header to rotate. When
//       OpenAI changes the backend protocol, `codex` is updated by its own
//       maintainers and Iris keeps working. The coupling is the CLI's command
//       surface (`codex exec`, `codex login`), which is a documented, stable,
//       non-secret interface.
//
//  HONESTY NOTE, same shape as the Claude one: using a ChatGPT *subscription*
//  to power a third-party app is a gray area under OpenAI's terms, and may be
//  rate-limited or disallowed. A pasted API key remains the unambiguous BYO
//  credential. The UI says so, in the same words the Claude row uses.
//

import Combine
import Foundation

// MARK: - Locating and reading the reader's Codex login

nonisolated enum CodexCLILogin {

    /// What Iris can tell about the reader's Codex setup, read from disk without
    /// spawning anything. Each case is a distinct, honest thing to say in the UI.
    enum ConnectionState: Equatable {
        /// No `codex` executable anywhere Iris knows to look.
        case codexNotInstalled
        /// The CLI is installed but no login has been completed.
        case signedOut
        /// Signed in with a ChatGPT account — the subscription path.
        case signedInWithChatGPT
        /// Signed in with a pasted `sk-…` key held by the CLI (`codex login
        /// --with-api-key`). Still a working credential for Iris's purposes.
        case signedInWithAPIKey

        /// Whether Iris can actually run a model call through Codex right now.
        var isUsable: Bool {
            switch self {
            case .signedInWithChatGPT, .signedInWithAPIKey:
                return true
            case .codexNotInstalled, .signedOut:
                return false
            }
        }
    }

    /// The auth shapes `~/.codex/auth.json` can hold. Parsed defensively:
    /// anything unrecognized is `nil` rather than a crash or a false positive.
    enum StoredAuthShape: Equatable {
        case chatGPTTokens
        case apiKey
    }

    // MARK: Locating the CLI

    /// The `codex` executable, or nil when the CLI is not installed anywhere
    /// Iris can find it.
    ///
    /// This is harder than it looks, and the first version got it wrong in a way
    /// that only showed up on someone else's Mac. A GUI app does not inherit the
    /// PATH a terminal has: launched from Finder or Dock it gets the system
    /// default — `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` and little else.
    /// Everything a developer adds lives in `~/.zshrc`, which a LOGIN shell
    /// (`zsh -l -c`) does not even read, because `.zshrc` is for INTERACTIVE
    /// shells. So the original "ask a login shell" fallback resolved nothing at
    /// all — measured on the author's own machine, where `codex` is installed
    /// and working and `zsh -l -c 'command -v codex'` returns empty. It only
    /// ever appeared to work because one hardcoded path happened to match.
    ///
    /// So the order is: paths that can be DERIVED (npm says where it installs
    /// global binaries, and it is authoritative for the documented install
    /// route), then the well-known fixed locations, then version managers,
    /// then — last, and no longer load-bearing — a shell that actually sources
    /// the interactive config.
    static func locateCodexBinary() -> String? {
        let fileManager = FileManager.default
        let candidates = codexBinaryCandidatePaths()
        for candidatePath in candidates
        where fileManager.isExecutableFile(atPath: candidatePath) {
            return candidatePath
        }
        // Everything above is a handful of stat calls and re-runs freely. What
        // follows is a subprocess and a filesystem walk, and this function is
        // called every time the settings panel appears — so the expensive half
        // runs AT MOST ONCE per launch. A reader who installs codex into any
        // known or discoverable location while Iris is running is still picked
        // up immediately, because the cheap half above always re-runs; only the
        // "we already looked everywhere and it wasn't there" verdict is kept.
        if expensiveLookupHasAlreadyRun {
            return cachedExpensiveLookupResult
        }
        expensiveLookupHasAlreadyRun = true

        if let resolvedOnPath = resolveCodexOnPathViaShell() {
            cachedExpensiveLookupResult = resolvedOnPath
            return resolvedOnPath
        }
        // Nothing named or discovered matched, and the shell does not know
        // either. Stop guessing and LOOK: a bounded scan of the places a binary
        // can live. Measured at ~1.3s across a full home directory, which is
        // affordable exactly once, on the path where the alternative is telling
        // a reader something false about their own machine.
        if let scanned = scanForCodexBinary(home: NSHomeDirectory()) {
            irisTrace("codex: not in any known location — found by scanning at \(scanned)")
            cachedExpensiveLookupResult = scanned
            return scanned
        }
        // Say what was tried. "Codex isn't installed where Iris can find it" is
        // indistinguishable, from the outside, between a reader who has not
        // installed it and a reader whose install is somewhere this does not
        // look — and the second of those is a bug in here, not in their setup.
        // The first version of this lookup shipped with exactly that ambiguity
        // and it took someone else's Mac to expose it.
        irisTrace(
            "codex: not found — tried \(candidates.count) known locations "
            + "and a shell PATH probe. Checked: \(candidates.prefix(6).joined(separator: ", "))"
        )
        return nil
    }

    /// Whether the subprocess-and-filesystem half of the lookup has run in this
    /// process, and what it concluded. Not a general cache: the cheap path
    /// checks above are re-run every time, so this only avoids repeating work
    /// that already came back empty.
    private nonisolated(unsafe) static var expensiveLookupHasAlreadyRun = false
    private nonisolated(unsafe) static var cachedExpensiveLookupResult: String?

    /// Forget the expensive lookup's verdict — for a reader who has just been
    /// told to install the CLI and is about to press the button again.
    static func forgetWhereCodexWasLookedFor() {
        expensiveLookupHasAlreadyRun = false
        cachedExpensiveLookupResult = nil
    }

    /// Every place a user-installed command-line tool could plausibly be,
    /// most-likely first, without running anything.
    ///
    /// Written for `codex` and generalised the moment a second thing needed it.
    /// A GUI app launched from Finder gets a minimal PATH — no `~/.cargo/bin`,
    /// no npm prefix, no version-manager shims — so ANY lookup that trusts
    /// PATH reports a tool the reader plainly has as missing. That cost the
    /// Codex sign-in on two Macs, and it is why the hickeyfield guide walks a
    /// reader who already has Rust through installing it: `ToolVersionService`
    /// had trusted fallbacks for exactly `git` and `node`, so `cargo` was
    /// invisible to every Iris ever shipped.
    ///
    /// Pure and ordered so it can be tested directly.
    static func candidatePaths(
        forExecutableNamed executableName: String,
        home: String = NSHomeDirectory(),
        npmrcContents: String? = nil,
        directoryLister: (String) -> [String] = { path in
            (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        }
    ) -> [String] {
        var paths: [String] = []

        // 1. Wherever npm is configured to put global binaries. `npm install -g
        //    @openai/codex` is the install route the Codex docs give first, and
        //    a user-level prefix is common enough that this machine has one:
        //    `prefix=/Users/…/.npm-global`, which no fixed list would guess.
        //    Read from the file rather than by running `npm`, because npm is
        //    itself often unreachable from a GUI app's PATH.
        let npmrc = npmrcContents
            ?? (try? String(contentsOfFile: "\(home)/.npmrc", encoding: .utf8))
        if let configuredPrefix = npmGlobalPrefix(fromNpmrc: npmrc, home: home) {
            paths.append("\(configuredPrefix)/bin/\(executableName)")
        }

        // 2. Fixed locations: the npm default prefixes, Homebrew on both
        //    architectures, and the runtimes that install their own bin dir.
        paths += [
            "\(home)/.npm-global/bin/\(executableName)",
            "/opt/homebrew/bin/\(executableName)",
            "/usr/local/bin/\(executableName)",
            "\(home)/.local/bin/\(executableName)",
            "\(home)/.bun/bin/\(executableName)",
            "\(home)/.codex/bin/\(executableName)",
            "\(home)/.volta/bin/\(executableName)",
            "\(home)/.yarn/bin/\(executableName)",
            "\(home)/Library/pnpm/\(executableName)",
            "\(home)/.asdf/shims/\(executableName)",
            "\(home)/.local/share/mise/shims/\(executableName)",
            "/opt/local/bin/\(executableName)",
        ]

        // 3. DISCOVERED, not named. Every tool that installs into the home
        //    folder uses the same shape: a directory with `bin` (or `shims`)
        //    inside it. `.volta`, `.bun`, `.yarn`, `.npm-global`, `.local`,
        //    `.deno`, whatever ships next year — enumerating the SHAPE finds
        //    them all without a list anyone has to keep current, and it costs
        //    a directory read rather than a subprocess. Naming them one at a
        //    time is what made this break on someone else's Mac.
        for parent in [home, "/opt", "/usr/local"] {
            for entry in directoryLister(parent).sorted() {
                paths.append("\(parent)/\(entry)/bin/\(executableName)")
                paths.append("\(parent)/\(entry)/shims/\(executableName)")
            }
        }

        // 4. Node version managers keep a bin directory PER INSTALLED VERSION,
        //    so the path cannot be written down — it has to be enumerated.
        //    nvm and fnm between them cover most Macs that have neither a
        //    Homebrew node nor a system one.
        let versionedRoots = [
            "\(home)/.nvm/versions/node",
            "\(home)/Library/Application Support/fnm/node-versions",
            "\(home)/.local/share/fnm/node-versions",
        ]
        for root in versionedRoots {
            for version in directoryLister(root).sorted().reversed() {
                paths.append("\(root)/\(version)/bin/\(executableName)")
                // fnm nests one level deeper than nvm does.
                paths.append("\(root)/\(version)/installation/bin/\(executableName)")
            }
        }

        return paths
    }

    /// Where `codex` specifically might be: everywhere a CLI can live, plus
    /// the application bundles that ship one.
    static func codexBinaryCandidatePaths(
        home: String = NSHomeDirectory(),
        npmrcContents: String? = nil,
        directoryLister: (String) -> [String] = { path in
            (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        }
    ) -> [String] {
        var paths = candidatePaths(
            forExecutableNamed: "codex",
            home: home,
            npmrcContents: npmrcContents,
            directoryLister: directoryLister
        )

        // 5. INSIDE APPLICATION BUNDLES. The ChatGPT desktop app ships the real
        //    CLI at `Contents/Resources/codex` — a 218MB Mach-O that answers
        //    `codex exec` exactly like the npm build — and it writes its OAuth
        //    tokens to the same `~/.codex/auth.json` the CLI reads. So a reader
        //    who has "ChatGPT" installed already has Codex AND is already
        //    signed in, while every lookup above looks only at places a package
        //    manager writes to and concludes they have nothing. That is the
        //    exact report this came from: "Codex isn't installed where Iris can
        //    find it, which is weird because ChatGPT is just in my Applications
        //    folder." They were right and the lookup was wrong.
        //
        //    Enumerated rather than named, for the same reason as section 3:
        //    ChatGPT is the bundle that does this today, not the only one that
        //    ever will. Last in the order on purpose — a CLI somebody chose to
        //    install outranks one that arrived inside an app.
        for applicationsDirectory in ["/Applications", "\(home)/Applications"] {
            for entry in directoryLister(applicationsDirectory).sorted()
            where entry.hasSuffix(".app") {
                paths.append(
                    "\(applicationsDirectory)/\(entry)/Contents/Resources/codex"
                )
            }
        }

        return paths
    }

    /// The `prefix=` line from an npmrc, if it names one. Tilde and `$HOME` are
    /// both expanded because npm accepts either in the file.
    static func npmGlobalPrefix(fromNpmrc contents: String?, home: String) -> String? {
        guard let contents else { return nil }
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"),
                  trimmed.hasPrefix("prefix") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "prefix" else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if value.hasPrefix("~/") { value = "\(home)/\(value.dropFirst(2))" }
            if value.hasPrefix("$HOME/") { value = "\(home)/\(value.dropFirst(6))" }
            while value.hasSuffix("/") { value.removeLast() }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Search the filesystem for `codex`, bounded in depth, breadth and time.
    ///
    /// The backstop for everything above being wrong — and it exists because
    /// the alternative, a list of paths somebody has to keep current, has
    /// already failed once in the field. Three roots, depth-capped, with the
    /// noisy subtrees pruned so this stays near a second rather than a minute.
    private static func scanForCodexBinary(home: String) -> String? {
        let findCommand = "find -L \"\(home)\" /usr/local /opt /Applications -maxdepth 5 "
            + "\\( -name Caches -o -name .Trash -o -name node_modules -o -name .git "
            + "-o -name Containers -o -name '*.photoslibrary' \\) -prune -o "
            + "-name codex -type f -perm -111 -print"
        guard let output = runBounded("/bin/sh", ["-c", findCommand], seconds: 12) else {
            return nil
        }
        let matches = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return rankedCodexPath(from: matches)
    }

    /// Pick the real CLI out of whatever a scan turns up.
    ///
    /// Not every file called `codex` is the command. This machine carries
    /// `~/.codex/plugins/.plugin-appserver/codex`, an internal helper, and a
    /// scan finds it FIRST — taking the first hit would wire Iris to the wrong
    /// binary and fail in a way far more confusing than "not installed". A
    /// command installed to be run lives in a `bin` or `shims` directory;
    /// nothing else is preferred, and shallower wins ties.
    /// How much a path looks like a command somebody is meant to invoke —
    /// lower is better. Three tiers, not two, because two collapses into a
    /// tiebreak on path depth and then on alphabetical order, and
    /// `/Applications/ChatGPT.app/…` and `/Users/x/.npm-global/bin/codex` are
    /// the same depth. Alphabetical order is not a reason to prefer a bundled
    /// CLI over one somebody chose to install.
    ///
    /// 0 — a `bin`/`shims` directory: where package managers put commands.
    /// 1 — `Contents/Resources` in an app bundle: where the ChatGPT app puts
    ///     the real Codex CLI. A command, but not one anybody asked for.
    /// 2 — anything else, which includes internal helpers like
    ///     `~/.codex/plugins/.plugin-appserver/codex` that merely share a name.
    static func commandLikelihoodRank(_ path: String) -> Int {
        if path.hasSuffix("/bin/codex") || path.hasSuffix("/shims/codex") {
            return 0
        }
        return path.hasSuffix(".app/Contents/Resources/codex") ? 1 : 2
    }

    static func rankedCodexPath(from matches: [String]) -> String? {
        codexPathsInPreferenceOrder(matches)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The ordering rule with no filesystem in it, so it can be asserted
    /// directly. `rankedCodexPath` can only ever return a path that exists on
    /// the machine running it, which makes the preference between two paths
    /// untestable through it — a test asserting that an npm install outranks
    /// the ChatGPT bundle silently became a test of whether this Mac happens
    /// to have both.
    static func codexPathsInPreferenceOrder(_ matches: [String]) -> [String] {
        matches.sorted { left, right in
            let leftRank = commandLikelihoodRank(left)
            let rightRank = commandLikelihoodRank(right)
            if leftRank != rightRank { return leftRank < rightRank }
            let leftDepth = left.components(separatedBy: "/").count
            let rightDepth = right.components(separatedBy: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return left < right
        }
    }

    /// Run a command with a hard time limit, returning stdout, or nil if it
    /// failed or overran. Shared by the shell probe and the scan so neither can
    /// hang a settings row.
    private static func runBounded(_ launchPath: String, _ arguments: [String], seconds: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Drain on a background queue. A scan can outproduce the pipe buffer,
        // and a full pipe with nobody reading it deadlocks the child forever —
        // which would turn a bounded scan into a permanent hang.
        var collected = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            collected = outputPipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit(); finished.signal() }
        if finished.wait(timeout: .now() + .seconds(seconds)) == .timedOut {
            process.terminate()
            _ = drained.wait(timeout: .now() + .seconds(2))
            return nil
        }
        _ = drained.wait(timeout: .now() + .seconds(2))
        return String(data: collected, encoding: .utf8)
    }

    /// Last resort: ask a shell that has actually read the reader's config.
    ///
    /// `-i` matters and its absence was the original bug. `.zshrc` — where
    /// nvm, fnm, volta, asdf and hand-rolled PATH edits all live — is sourced
    /// for INTERACTIVE shells only, so `zsh -l -c` sees none of it. The
    /// interactive flag is paired with a scrubbed `ZDOTDIR`-free environment
    /// and a dumb terminal so ZLE does not try to take over a pipe, and the
    /// whole thing is bounded: a reader's `.zshrc` may block on anything, and
    /// this runs while a panel is waiting to draw.
    private static func resolveCodexOnPathViaShell() -> String? {
        let loginShellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Interactive first, then the old login-only form as a fallback for a
        // shell where `-i` misbehaves.
        for arguments in [["-i", "-l", "-c", "command -v codex"], ["-l", "-c", "command -v codex"]] {
            if let resolved = firstExecutablePath(
                fromShell: loginShellPath, arguments: arguments
            ) {
                return resolved
            }
        }
        return nil
    }

    private static func firstExecutablePath(
        fromShell shellPath: String, arguments: [String]
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // A reader's shell config can hang. Give it a bounded window, then
        // kill it — this runs on the path that decides whether a settings row
        // says "connected", and that row must not wait on someone's .zshrc.
        let deadline = DispatchTime.now() + .seconds(6)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        // `command -v` can print several lines when a shim and a real binary
        // both exist; the first executable one is the answer.
        for line in (String(data: outputData, encoding: .utf8) ?? "")
            .components(separatedBy: .newlines) {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty, FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: Where the CLI keeps its login

    /// The directory the CLI treats as its home. `CODEX_HOME` wins when set —
    /// the CLI honors it, so Iris must too, or it would read a different
    /// login than the one `codex exec` is about to use.
    static func codexHomeDirectory() -> String {
        if let overriddenHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !overriddenHome.isEmpty {
            return overriddenHome
        }
        return "\(NSHomeDirectory())/.codex"
    }

    /// The credential file itself. Never read for its token — only for shape.
    static func authFilePath() -> String {
        "\(codexHomeDirectory())/auth.json"
    }

    // MARK: Reading the state

    /// The current state, cheap enough for the settings panel to call on
    /// appear. Touches the filesystem only.
    static func currentState() -> ConnectionState {
        guard locateCodexBinary() != nil else { return .codexNotInstalled }
        guard let authFileData = FileManager.default.contents(atPath: authFilePath()) else {
            return .signedOut
        }
        switch storedAuthShape(inAuthFileContents: authFileData) {
        case .chatGPTTokens:
            return .signedInWithChatGPT
        case .apiKey:
            return .signedInWithAPIKey
        case nil:
            return .signedOut
        }
    }

    /// When the credential file was last written, or nil when there is none.
    /// Used as the "this is a FRESH login" oracle: a reader who was already
    /// signed in when they pressed the button must not be told they succeeded
    /// by the stale file that was already sitting there.
    static func authFileModificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: authFilePath())[.modificationDate] as? Date
    }

    /// Which credential shape `auth.json` holds, if any.
    ///
    /// PURE and total, so it is unit-tested against fixture blobs with no CLI
    /// installed. Deliberately does not return, log, or otherwise surface the
    /// secret material it walks past — the caller only ever learns the shape.
    ///
    /// The file has carried an explicit `auth_mode` since the version this was
    /// written against (0.149.1), but it is treated as a hint rather than the
    /// source of truth: the presence of real material decides, so an older or
    /// newer file that drops or renames the field still reads correctly.
    static func storedAuthShape(inAuthFileContents authFileData: Data) -> StoredAuthShape? {
        guard let json = try? JSONSerialization.jsonObject(with: authFileData) as? [String: Any] else {
            return nil
        }
        if let tokens = json["tokens"] as? [String: Any],
           let accessToken = tokens["access_token"] as? String,
           !accessToken.isEmpty {
            return .chatGPTTokens
        }
        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return .apiKey
        }
        return nil
    }

    /// The ChatGPT account id the login is bound to, when there is one. Shown
    /// nowhere; it exists so a future "which account is this?" row has a value
    /// to render that is not a secret.
    static func accountIdentifier(inAuthFileContents authFileData: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: authFileData) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accountIdentifier = tokens["account_id"] as? String,
              !accountIdentifier.isEmpty else {
            return nil
        }
        return accountIdentifier
    }

    // MARK: Redaction

    /// Redacts anything token-shaped from text bound for the on-screen
    /// transcript. `codex login` is not supposed to print its tokens, but the
    /// panel renders whatever the CLI writes, so this is belt-and-braces in the
    /// same posture as the Claude path's redaction: scrub on the way OUT, never
    /// rely on the other program's discretion.
    ///
    /// Covers the three shapes that could appear: an OpenAI API key, a JWT
    /// (the id/access tokens are JWTs), and the CLI's own `ey…`-prefixed blobs.
    static func redactingAnySecret(in text: String) -> String {
        var redactedText = text
        let secretPatterns = [
            // sk-… and sk-proj-… API keys.
            "sk-[A-Za-z0-9_-]{20,}",
            // A JWT: three base64url segments. The access/id tokens are these.
            "eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}",
        ]
        for pattern in secretPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let wholeRange = NSRange(redactedText.startIndex..., in: redactedText)
            redactedText = regex.stringByReplacingMatches(
                in: redactedText, range: wholeRange, withTemplate: "…[hidden]"
            )
        }
        return redactedText
    }

    // MARK: Disconnecting

    /// Signs the reader out by asking the CLI to forget its own credential —
    /// `codex logout`. Iris does not delete `auth.json` itself: the file is the
    /// CLI's, its exact shape is the CLI's business, and a future version may
    /// keep more than one thing in it.
    ///
    /// Returns whether the CLI reported success. Synchronous and quick (no
    /// network — it is a local file delete on the CLI's side).
    @discardableResult
    static func disconnect() -> Bool {
        guard let codexBinaryPath = locateCodexBinary() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexBinaryPath)
        process.arguments = ["logout"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = environmentForCodex()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: The environment the CLI runs in

    /// The environment `codex` is spawned with: the reader's own, plus a PATH
    /// wide enough to find node and friends when Iris was launched from Finder
    /// (a GUI app inherits a minimal PATH, which is exactly how "works in my
    /// terminal, not in the app" bugs happen).
    static func environmentForCodex() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let home = NSHomeDirectory()
        let broadSearchPath = [
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.local/bin", "\(home)/.bun/bin",
        ].joined(separator: ":")
        if let existingPath = environment["PATH"], !existingPath.isEmpty {
            environment["PATH"] = "\(existingPath):\(broadSearchPath)"
        } else {
            environment["PATH"] = broadSearchPath
        }
        environment["HOME"] = home
        return environment
    }
}

// MARK: - Signing in: `codex login` in a pty

/// Runs `codex login` in a real pty and waits for the browser round trip to
/// land a credential on disk. The reader completes the OpenAI sign-in the CLI
/// opens in their browser; Iris watches for the result.
///
/// HOW SUCCESS IS DETECTED, and why it is not a string match: the CLI prints a
/// success line, but wording is not a contract and Iris would silently stop
/// working the day it changed. The oracle is the credential file itself —
/// `auth.json` going from absent/empty to holding real material is the thing
/// that actually means "signed in", and it is what `codex exec` will read a
/// moment later. The printed output is shown to the reader, never parsed for
/// truth. (This is the same discipline the maintain harness learned the hard
/// way: verify the outcome, not the narration.)
@MainActor
final class CodexCLISignInSession: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// The Codex CLI is not installed where Iris could find it.
        case codexNotFound
        /// `codex login` is running; the reader is completing the browser step.
        case running
        /// A login landed on disk — the reader is connected.
        case connected(CodexCLILogin.ConnectionState)
        /// The command exited without a credential ever appearing (the reader
        /// cancelled the browser step, or the CLI errored).
        case finishedWithoutLogin
        /// Something went wrong starting or running the command.
        case failed(reason: String)
    }

    @Published private(set) var phase: Phase = .idle

    /// The ANSI-stripped, secret-redacted transcript for the panel.
    @Published private(set) var visibleTranscript: String = ""

    private var pseudoTerminal: GuideAutopilotPseudoTerminal?
    private var rawOutputSoFar: String = ""
    private var hasConnected = false
    /// Polls `auth.json` for the moment the browser round trip lands. The pty
    /// gives no event for "the CLI's local callback server got its code", so
    /// the file is what Iris watches.
    private var credentialPollTimer: Timer?

    /// The shape on disk when the session started, so an ALREADY-signed-in
    /// reader re-running sign-in is not instantly reported as success by the
    /// stale file that was there before they began.
    private var authShapeBeforeStarting: CodexCLILogin.StoredAuthShape?
    /// The credential file's write time when this session began, paired with
    /// the shape above to tell "a new login landed" from "one was already here".
    private var authFileModifiedBeforeStarting: Date?

    private static let mostTranscriptCharactersToKeep = 8_000
    private static let credentialPollIntervalSeconds: TimeInterval = 0.75

    var isRunning: Bool { phase == .running }

    /// Spawns `codex login`. No-op if already running.
    func start() {
        // The reader is pressing this deliberately, and the most common reason
        // to press it twice is that they have just installed the CLI after
        // being told it was missing. Throw away the "looked everywhere, not
        // there" verdict so this press actually looks again.
        CodexCLILogin.forgetWhereCodexWasLookedFor()
        guard phase != .running else { return }
        rawOutputSoFar = ""
        visibleTranscript = ""
        hasConnected = false

        guard let codexBinaryPath = CodexCLILogin.locateCodexBinary() else {
            phase = .codexNotFound
            return
        }

        // A stale login must not count as this session's success. The obvious
        // way to guarantee that — `codex logout` first — is WRONG: a reader who
        // then cancels the browser step has lost a login they had when they
        // started. So nothing is destroyed; the file's write time is the oracle
        // instead, and a cancelled attempt leaves the reader exactly as it
        // found them.
        authShapeBeforeStarting = FileManager.default
            .contents(atPath: CodexCLILogin.authFilePath())
            .flatMap { CodexCLILogin.storedAuthShape(inAuthFileContents: $0) }
        authFileModifiedBeforeStarting = CodexCLILogin.authFileModificationDate()

        let terminal = GuideAutopilotPseudoTerminal()
        terminal.onOutput = { [weak self] outputBytes in
            DispatchQueue.main.async { self?.ingest(outputBytes) }
        }
        terminal.onProcessExit = { [weak self] _ in
            DispatchQueue.main.async { self?.handleProcessExit() }
        }

        do {
            try terminal.spawn(
                shellPath: codexBinaryPath,
                arguments: ["login"],
                environment: CodexCLILogin.environmentForCodex()
            )
        } catch {
            phase = .failed(reason: "Iris couldn't start `codex login`.")
            return
        }

        pseudoTerminal = terminal
        phase = .running
        startPollingForCredential()
    }

    /// Forwards a line the reader typed, for any prompt the CLI puts up.
    func sendLine(_ text: String) {
        guard phase == .running else { return }
        pseudoTerminal?.write(text + "\r")
    }

    /// Forwards a bare return.
    func sendReturn() {
        guard phase == .running else { return }
        pseudoTerminal?.write("\r")
    }

    /// Reader gave up. Tears the command down.
    func cancel() {
        stopPollingForCredential()
        pseudoTerminal?.closeSession()
        pseudoTerminal = nil
        if phase == .running { phase = .idle }
    }

    // MARK: - Output handling

    private func ingest(_ outputBytes: [UInt8]) {
        guard let chunk = String(bytes: outputBytes, encoding: .utf8) else { return }
        rawOutputSoFar += chunk
        let cleaned = GuideAutopilotOutputBuffer.strippedOfControlSequences(rawOutputSoFar)
        let redacted = CodexCLILogin.redactingAnySecret(in: cleaned)
        visibleTranscript = String(redacted.suffix(Self.mostTranscriptCharactersToKeep))
    }

    // MARK: - The credential oracle

    private func startPollingForCredential() {
        stopPollingForCredential()
        credentialPollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.credentialPollIntervalSeconds, repeats: true
        ) { [weak self] _ in
            guard let session = self else { return }
            Task { @MainActor in session.checkForLandedCredential() }
        }
    }

    private func stopPollingForCredential() {
        credentialPollTimer?.invalidate()
        credentialPollTimer = nil
    }

    private func checkForLandedCredential() {
        guard !hasConnected else { return }
        let state = CodexCLILogin.currentState()
        guard state.isUsable else { return }
        if authShapeBeforeStarting != nil {
            // There was already a login when this started, so "a credential
            // exists" proves nothing. Only a file written since then does.
            guard let before = authFileModifiedBeforeStarting,
                  let landed = CodexCLILogin.authFileModificationDate(),
                  landed > before else { return }
        }
        hasConnected = true
        phase = .connected(state)
        stopPollingForCredential()
        // The CLI exits on its own after a successful login; closing the pty
        // here keeps a stuck one from lingering.
        pseudoTerminal?.closeSession()
        pseudoTerminal = nil
    }

    private func handleProcessExit() {
        pseudoTerminal = nil
        if hasConnected { return }
        // The CLI can exit a beat before it finishes writing the file; give the
        // oracle one last look before calling it a failure.
        checkForLandedCredential()
        if hasConnected { return }
        stopPollingForCredential()
        if phase == .running {
            phase = .finishedWithoutLogin
        }
    }
}

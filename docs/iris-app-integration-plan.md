# How Iris talks to the catalog apps

Status: **designed, not built.** Nothing in this document exists in code yet.

This is the answer to the last unbuilt item in the original brief — *"make
existing software interface with apps, especially signed packaged"* — and to
the question "should each app expose an MCP server?"

The short answer is no, and the reason is specific enough to be worth keeping.

## What Iris can learn about an app today

| Source | What it gives | What it cannot give |
|---|---|---|
| `AppInventoryService` | installed / version / frontmost, via OS APIs | anything about what the app is *doing* |
| `WatchLoop` + screenshots | what is on screen | anything not on screen |
| Accessibility tree | element roles, labels, rects | internal state; nothing on a canvas |
| `docs/publik-sdk-convention.md` log files | what the developer thought to write down, in the past tense | liveness, follow-up questions, any action |

All of it is passive and one-directional. Iris can watch an app. It cannot ask
an app anything, and it cannot ask it to do anything.

**And none of it is connected**: as of this writing not one of the nine apps
emits a single publik log line. The cheap seam is documented and unimplemented.

## The decision: MCP goes in Iris, not in the apps

Three findings from the August 2026 research kill "embed an MCP server in each
app". They are worth restating because each is easy to rediscover the hard way.

**1. MCP's local transport assumes the client spawns the server.** The
`stdio` transport — the one essentially everybody ships — is defined as
newline-delimited JSON-RPC over a *client-launched subprocess*. Our use case is
the opposite: attach to a GUI app that is *already running* and read its live
state. A spawned `Lunara --mcp-server` is a fresh process holding none of the
running app's memory. To make it useful it must talk to the real app over some
other IPC channel — so the IPC gets built anyway and MCP becomes a façade over
it rather than a replacement for it.

Streamable HTTP does work in-process (Figma's Dev Mode server does exactly
this on `127.0.0.1:3845`), but then MCP has given us a schema and a calling
convention and nothing else.

**2. MCP has no local discovery and no local caller authentication.** Not
"proposed but unshipped" — out of scope. Every MCP host on the market solves
discovery with a human-edited config file. The spec's entire local security
guidance is *use a token, or use a Unix socket*. Both are built by hand either
way. And any process running as the same user can connect to a loopback port;
`Origin` validation defends against browser DNS rebinding, not local processes.

**3. It just went through a clean break, and the Swift story lags.** The
2026-07-28 revision made the protocol **stateless**: no `initialize` handshake,
no sessions, no server-initiated requests (sampling/elicitation/roots are
replaced by Multi Round-Trip Requests), no GET/SSE stream, and Roots, Sampling
and Logging are deprecated. A new `server/discover` RPC is mandatory. MCP was
also donated to the Linux Foundation's Agentic AI Foundation in December 2025,
so it is no longer Anthropic-governed.

Two things temper this. The project now has a published feature-lifecycle and
deprecation policy with a **minimum twelve-month window**, and the maintainers
state that implementers targeting 2026-07-28 should adopt future revisions
without rewriting transport or lifecycle code. So "permanently unstable" is too
strong — but *"build on an SDK, never hand-roll the protocol"* is the lesson,
because this is the second transport rewrite in eighteen months and the ones
who suffered were the hand-rollers.

The sharper problem for us: the **official Swift SDK implements 2025-11-25**,
a full revision behind, and is pre-1.0. A Swift-native MCP server today ships
legacy-era protocol. The TypeScript SDK is current, at v2, and has **split
packages** — `@modelcontextprotocol/server` and `@modelcontextprotocol/client`,
not the old `@modelcontextprotocol/sdk`. Scaffolding from memory installs the
wrong package.

### So

**Iris hosts one MCP server. The nine apps speak a small local protocol.**

That buys: interop with Claude Desktop, Cursor and Raycast for free; one
surface to secure rather than nine; one place to absorb the next breaking
revision without re-notarizing anything; and no HTTP server inside nine small
consumer apps.

**That last point is a security argument, not an aesthetic one.** Local HTTP is
where MCP's CVEs live. The *official* TypeScript SDK shipped DNS-rebinding
protection **off by default** (CVE-2025-66414/66416, CVSS 7.6, fixed in 1.24.0)
— any unauthenticated localhost HTTP MCP server was reachable from a web page
the user merely visited. Anthropic's own MCP Inspector had an RCE via the same
browser pattern (CVE-2025-49596, CVSS 9.4). Stdio transports were unaffected in
both. Nine localhost ports is nine instances of that attack surface.

**The precedent to copy is Xcode 26.3**, which exposes an MCP server via
`xcrun mcpbridge` over **stdio**, registered explicitly by the client with no
auto-discovery, behind *two* consent layers — a settings toggle plus a
per-connection approval dialog — and accepts only local connections. The
counterexample is Figma desktop: plain HTTP on a hardcoded `127.0.0.1:3845`,
no auth, and Figma's own docs steer users to their hosted server instead.

## The local protocol

**Framing: newline-delimited JSON-RPC** — MCP's own stdio framing. The
2026-07-28 spec explicitly blesses reusing it: *custom transports over a
reliable bidirectional byte stream SHOULD reuse the stdio framing, since the
stdio binding is just newline-delimited JSON-RPC over a byte stream.* So the
schema and framing are MCP's; only the transport is ours.

**Transport: Unix domain socket on macOS, named pipe on Windows.**
- UDS gives ~90% of XPC's security for a fraction of the cost, and shares its
  code shape with the Windows side. XPC's named Mach services would need an
  `SMAppService` LaunchAgent per app — nine Login Items entries and nine
  support questions — and is macOS-only.
- Windows: `CreateNamedPipe` with a restrictive SDDL, and
  **`FILE_FLAG_FIRST_PIPE_INSTANCE`** — without it, an attacker who creates the
  pipe name first sets the security descriptor for every later instance. This
  is the named-pipe squatting trap and it is one flag.
- If any app is ever sandboxed, the socket must live in an **App Group
  container**; the sandbox blocks UDS outside the container, and filesystem
  temporary-exception entitlements do not help because they only cover files.

**Discovery: an instance file per running app** — Chrome's
`DevToolsActivePort` pattern, which is what actually works.

Each app, at launch, writes JSON into a `0700` directory:

- macOS: `~/Library/Application Support/publik/run/<bundle-id>.json`
- Windows: `%LOCALAPPDATA%\publik\run\<package>.json`

carrying socket path or pipe name, PID, app version, protocol version, and a
freshly generated per-session token. Removed on clean exit; a file whose PID is
dead is stale. One `readdir` gives Iris discovery, **liveness**, and version
negotiation at once — and liveness is precisely what log files can never
provide.

Not a fixed port (nine apps, collisions). Not Bonjour — on macOS 15+ mDNS
triggers the Local Network prompt, and multicasting to the LAN to find a
process on the same machine is absurd.

**Authentication: verify the peer's code signature.** Every binary is signed
`R5R3ZS54LV`, so identity is checkable rather than claimed.
- macOS: peer audit token via `getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN)` →
  `SecCodeCopyGuestWithAttributes` → `SecCodeCopySigningInformation` → compare
  Team ID. **Use the audit token, never the bare PID** — PIDs wrap and can be
  raced.
- Windows: `GetNamedPipeClientProcessId` → `QueryFullProcessImageName` →
  `WinVerifyTrust` against the publisher cert. If the Windows build is ever
  MSIX-packaged, `GetPackageFamilyName` gives OS-verified caller identity for
  free and is strictly better.
- The session token from the instance file is a cheap second factor, not a
  boundary — any process running as the user can read that file.
- Honest limit: a signature check authenticates the binary on disk, not the
  code executing inside it. Anything able to inject into signed Iris inherits
  its identity. Acceptable for nine small open-source apps; would not be for a
  password manager.

**Consent lives in the target app, and must be built — no OS gives it to us.**
A UDS, a named pipe and a loopback port are all invisible to TCC and to
Windows' permission model. So: on first connection the *target app* shows a
sheet naming the caller **as verified by signature**, never as claimed in a
handshake field. Separate **read** scope from **action** scope, with a distinct
grant for actions. A visible indicator while a session is live. Revocable in
each app's settings. Given same-team signing, defaulting *read* to
on-with-an-indicator is defensible; defaulting *actions* to on is not.

Prior art worth copying: 1Password's app↔extension handshake verifies the
browser's code signature on both platforms before accepting a connection, with
no OS involvement. That is the closest analogue to our situation.

**Lifecycle: never auto-launch.** Iris can start an app trivially and should
not. Launching a GUI app steals focus and repaints the user's screen, which
reads as malware; and a cold-started app has none of the state the question was
about, so nothing is learned. Correct shape: notice the app is absent from the
run directory and *offer* — "Lunara isn't running; open it?"

## What each app implements

One shared library, two targets (Swift package + npm package), used nine times.
Verbs, cheapest-first:

- `describe` — app id, version, protocol version, available scopes
- `get_state` — a small, app-defined snapshot of what the user is doing
- `get_recent_events` — the ring buffer (below)
- `get_last_error` — the most recent failure with enough to reproduce it
- `capture_diagnostics` — a bundle for a bug report
- per-app actions, behind the action scope

**Demote logs to a queryable ring buffer.** Keep the structured events, hold
them in process, and let the IPC layer query them. Same data, present tense,
answerable with follow-up questions. `docs/publik-sdk-convention.md` stays
valid as the *event shape*; the file on disk stops being the only channel.

## Phasing

1. **The shared library** (1–2 weeks): transport, framing, instance file,
   signature verification, consent sheet, ring buffer.
2. **One app end to end** — `cue` is the natural candidate: flagship, owned,
   already notarized. Prove discovery → auth → consent → query before
   committing nine binaries.
3. **Iris as client**, replacing log-file reads with live queries. The breaks
   tally and patch pipeline immediately get better repro data, which is their
   weakest input today.
4. **The remaining eight apps** — roughly half a day each once the library
   exists.
5. **Iris as MCP server**, aggregating the nine sockets into one MCP surface
   for Claude Desktop / Cursor / Raycast. Two constraints from the research
   decide its shape:
   - **stdio, not local HTTP**, and distributed as an **`.mcpb` bundle** — a
     zip of a stdio server plus `manifest.json` that Claude for macOS and
     Windows install in one click with auto-update. (Formerly `.dxt`; renamed
     September 2025, so `@anthropic-ai/dxt` is the stale name.)
   - **Write it in TypeScript, not Swift.** The official Swift SDK is a full
     revision behind and pre-1.0; the TypeScript SDK is current. A small Node
     sidecar shipped alongside Iris speaking the local socket protocol beats a
     Swift server that talks legacy protocol. If the sidecar is bundled inside
     the .app, re-sign every nested binary under `R5R3ZS54LV` — mismatched
     Team IDs trip Library Validation — and expect to need
     `com.apple.security.cs.allow-jit` and `allow-unsigned-executable-memory`,
     the standard Electron pair. Neither blocks notarization.
6. **App Intents in the Swift apps** as a hedge — cheap in Swift, free
   Spotlight/Shortcuts/Siri surface, and it pays off if Apple ships the
   App-Intents-over-MCP bridge that appeared in the 26.1 betas.

## One constraint that shapes everything

**Unix sockets work between our own apps and nobody else's.** App Sandbox
blocks unmediated IPC across Team IDs, and there is no shared writable
location, so a third-party agent — which by definition does not share
`R5R3ZS54LV` — can never reach the app sockets directly. That is not a
limitation to work around; it is the reason the topology is right. Our nine
apps talk to Iris over sockets they are all entitled to use, and everyone else
reaches them through Iris's stdio MCP server, which is exactly where consent,
identity and rate limiting should live anyway.

## Open questions, and one that is twenty minutes of work

- **Does the macOS TCC Automation prompt fire between two apps signed with the
  same Team ID?** Apple's docs are explicit that the *entitlement* is not
  needed for same-team Apple Events; whether the *prompt* is skipped is
  undocumented and widely assumed. Two throwaway signed apps settle it. It is
  the difference between "AppleScript is a free escape hatch" and "nine
  first-run dialogs".
- What belongs in `get_state` per app. Needs a pass per app, and is the part
  that decides whether any of this is useful.
- Whether the Windows builds should be MSIX-packaged, which would upgrade
  caller authentication for free and is a prerequisite for Windows' own
  (still-preview) On-Device Agent Registry.

## What not to do

- MCP servers inside nine shipped binaries — pays an HTTP server, port
  allocation and permanent protocol churn in nine places, for a schema
  obtainable anyway, and still hand-builds discovery, auth, consent, lifecycle.
- XPC named Mach services — best security on the list, worst adoption cost, and
  macOS-only.
- AppleScript as the primary channel, unless the TCC question above resolves
  favourably; and even then it means `sdef` files and `NSScriptCommand`
  plumbing that SwiftUI gives nothing for.
- Bonjour, or a fixed port.
- URL schemes for state queries. Every leg is a LaunchServices dispatch and an
  app activation — focus theft per request, no streaming, no error taxonomy.
  Keep `iris://` for user-facing deep links and the app → Iris direction.

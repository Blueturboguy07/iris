//
//  MaintainModelProvider.swift
//  leanring-buddy
//
//  Tier C runs on the user's OWN model access — never the funded proxy
//  (ratified D4/D5). Providers speak one interface so the fix loop doesn't
//  care which the user brought:
//
//    anthropic   the user's sk-ant key OR their Claude Code login, through
//                the BYO-only ClaudeAPI.
//    openai      the user's sk key, straight to api.openai.com — net-new
//                for Iris, its first non-Anthropic model call, kept behind
//                this seam so nothing else in the app learns a second SDK.
//    codex       the user's ChatGPT account, driven through the Codex CLI
//                they signed in to (2026-08-26). It lives in its own file,
//                `CodexMaintainProvider.swift`, because it is a subprocess
//                rather than an HTTP call — the "agent CLI" shape this
//                interface was always meant to be able to take, and the
//                proof that it can without a caller change.
//    (local models are v1.1.)
//
//  The whole interface is one turn: history in, one assistant text turn out.
//  The ReAct loop that drives it lives in MaintainTierCFixer.
//

import Foundation

/// One conversational turn, provider-agnostic. `role` is "user" or
/// "assistant"; `text` is plain text (the loop has no tool API).
/// `attachedImagePNGData` carries the ONE image the on-demand opening turn may
/// attach — a screenshot of the app's window, so the model sees what the user
/// is looking at. `var`, because the loop strips it after the first reply
/// (replaying a screenshot on all subsequent steps would cost image tokens on
/// EVERY step for context the model has already absorbed).
struct MaintainChatTurn: Sendable {
    let role: String
    let text: String
    var attachedImagePNGData: Data? = nil
}

/// Why a Tier C model call could not be made, in cases that carry the
/// diagnosis and a `userFacingMessage` that lets it out.
///
/// THE CONFORMANCE IS THE FIX. A bare Swift `Error` bridges to an NSError whose
/// domain is this type's name and whose code is the case's RUNTIME index, so
/// `error.localizedDescription` on one of these read, in full:
///
///     "The operation couldn’t be completed.
///      (Iris.MaintainModelProviderError error 0.)"
///
/// That is what a reader was actually shown when an app-edit run died, and
/// their own words afterwards were "I have the codex CLI?" — a fair question,
/// because nothing in that sentence is about a CLI, a login, or anything a
/// person could go and do about it. And "error 0" is `.requestFailed`: Swift
/// numbers the payload-carrying cases first, so the one case that CARRIES the
/// real explanation as a String is precisely the one whose explanation got
/// thrown away on the way out.
///
/// `AssistantTransportError` grew `userFacingMessage` after the identical
/// incident — a reader seeing "(… error 8.)" when their Claude Code token
/// lapsed. This is that fix, carried across to the sibling enum it was never
/// applied to, and held to the same bar: the reader is told what to DO, never
/// a code. `LocalizedError` is conformed as well as the property added because
/// `userFacingMessage` is what call sites SHOULD reach for and
/// `localizedDescription` is what they reach for by accident; with
/// `errorDescription` wired up, the accident now yields the sentence instead of
/// the case index. The alternative — auditing every present and future call
/// site — is the audit that was already missed once here.
enum MaintainModelProviderError: Error, LocalizedError {
    /// No usable credential, and WHICH kind of "no". A single payload-free
    /// `.noCredential` collapsed four unrelated problems — the codex command
    /// isn't where Iris can see it, the codex login isn't active, codex itself
    /// turned the call down, no OpenAI key is saved — into one opaque code, and
    /// a reader can act on exactly one of those at a time. Which one is the
    /// only useful thing Iris knows here, and it used to be the one thing it
    /// did not say.
    case noCredential(MissingCredential)

    /// The call was made and failed. The String is the diagnosis, and carrying
    /// it is the entire reason this case has a payload — so it is written at
    /// the throw site as a SENTENCE THE READER CAN ACT ON, never a bare dump.
    /// That is the contract every construction site below keeps: the payload
    /// is what reaches the reader verbatim, because the alternative is what
    /// they got before, which was the case index instead.
    case requestFailed(String)

    /// The distinct ways a provider ends up with nothing to call the model
    /// with. Each one has a different repair, which is why they are different
    /// cases rather than a shared string.
    enum MissingCredential: Equatable {
        /// `CodexCLILogin.locateCodexBinary()` found no `codex` anywhere it
        /// knows to look. NOT the same as "you never installed it" — an app
        /// launched from Finder gets a minimal PATH, so a perfectly working
        /// codex can be invisible to Iris and visible in the reader's terminal.
        /// The message has to leave room for both, because the reader who hit
        /// this had in fact installed it.
        case codexCommandNotFound
        /// The CLI is there, but `~/.codex/auth.json` holds no usable login.
        case codexLoginNotUsable
        /// The call actually reached codex and codex refused it on credential
        /// grounds. Its own words ride along: Iris is guessing from stderr
        /// heuristics here, and quoting the tool is how a reader can tell
        /// whether the guess was right.
        case codexTurnedTheCallDown(codexSaid: String)
        /// No OpenAI key in the Keychain.
        case openAIKeyNotSaved
    }

    /// What to tell the reader, in the register `AssistantTransportError`
    /// established: lowercase, one problem, one thing to go and do.
    var userFacingMessage: String {
        switch self {
        case .noCredential(let missingCredential):
            return missingCredential.userFacingMessage
        case .requestFailed(let whatWentWrong):
            // Verbatim. The payload is already the sentence (see the case's own
            // note); appending a generic tail here would land it after a quoted
            // stderr block, which reads as a non-sequitur and is how "helpful"
            // wording turns back into noise.
            return whatWentWrong
        }
    }

    var errorDescription: String? { userFacingMessage }
}

extension MaintainModelProviderError.MissingCredential {
    var userFacingMessage: String {
        switch self {
        case .codexCommandNotFound:
            return "iris can't find the `codex` command on this mac. if you've installed it, it's somewhere iris doesn't look — reconnect under \"Sign in with Codex\" in settings; if you haven't, `npm install -g @openai/codex` puts it where iris will."
        case .codexLoginNotUsable:
            return "your codex cli is installed but isn't signed in to anything iris can use. run `codex login` in a terminal, or use \"Sign in with Codex\" in settings, then try again."
        case .codexTurnedTheCallDown(let codexSaid):
            return "codex turned the call down, which usually means its login has lapsed. sign in again with `codex login`, or reconnect under \"Sign in with Codex\" in settings. codex said: \(codexSaid)"
        case .openAIKeyNotSaved:
            return "there's no openai key saved. paste one in settings, or connect a different model, and try again."
        }
    }
}

@MainActor
protocol MaintainModelProviding: Sendable {
    var displayName: String { get }
    /// Stable across launches and independent of `displayName`, which is prose
    /// and will be reworded. This is what a remembered choice is stored as.
    var identifier: String { get }
    var isAvailable: Bool { get }
    func respond(
        systemPrompt: String,
        conversation: [MaintainChatTurn],
        maximumOutputTokens: Int
    ) async throws -> String
}

// MARK: - Anthropic (the user's own key, via the BYO-only ClaudeAPI)

@MainActor
final class AnthropicMaintainProvider: MaintainModelProviding {
    let displayName = "Anthropic (your key)"
    let identifier = "anthropic"

    private lazy var byoOnlyAPI = ClaudeAPI(resolveTransport: {
        // The reader's own credential in either shape — a pasted API key or a
        // connected Claude Code OAuth token — never the funded proxy (D4/D5).
        guard let transport = AnthropicBringYourOwnCredential.currentTransport() else {
            return .failure(.noCredentialsAvailable)
        }
        return .success(transport)
    })

    var isAvailable: Bool { AnthropicBringYourOwnCredential.isAvailable }

    func respond(
        systemPrompt: String,
        conversation: [MaintainChatTurn],
        maximumOutputTokens: Int
    ) async throws -> String {
        let messages = conversation.map { turn in Self.messagePayload(forTurn: turn) }
        let message = try await byoOnlyAPI.continueTextConversation(
            systemPrompt: systemPrompt,
            messages: messages,
            maximumOutputTokens: maximumOutputTokens,
            // Web search, server-side. Tier C was the ONE part of Iris with no
            // way to look anything up — the guide fix ladder and chat both
            // have it — so a request to integrate an API the model does not
            // already know could not succeed by any route. The search runs on
            // Anthropic's side, so this gives the model current knowledge
            // without giving the local jail network access. Codex gets the
            // same capability from its own `--search` flag.
            tools: [GuideAutopilotFixProposer.webSearchTool]
        )
        webSearchQueriesOfTheMostRecentTurn = message.webSearchQueries
        return message.text
    }

    /// The queries this arm searched on its most recent turn, for measurement.
    /// Not read by the edit loop — `ToolInvocationLiveTests` asks whether the
    /// model reached for the tool, which the reply text cannot answer honestly
    /// (a model saying it searched is not evidence that it did).
    private(set) var webSearchQueriesOfTheMostRecentTurn: [String] = []

    /// One turn as Messages-API JSON. A turn with an attached image becomes a
    /// content-block array (image first, then the text — the order the API
    /// docs recommend); a plain turn stays a plain string. Static + pure so
    /// the mapping is unit-testable without a network.
    nonisolated static func messagePayload(forTurn turn: MaintainChatTurn) -> [String: Any] {
        guard let attachedImagePNGData = turn.attachedImagePNGData else {
            return ["role": turn.role, "content": turn.text]
        }
        return ["role": turn.role, "content": [
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": attachedImagePNGData.base64EncodedString(),
                ],
            ] as [String: Any],
            ["type": "text", "text": turn.text] as [String: Any],
        ]]
    }
}

// MARK: - OpenAI (the user's own key, straight to the source)

@MainActor
final class OpenAIMaintainProvider: MaintainModelProviding {
    let displayName = "OpenAI (your key)"
    let identifier = "openai"

    /// The model the fix loop asks for. A capable coding model; the user's
    /// key, the user's spend.
    static let model = "gpt-4o"
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    var isAvailable: Bool { KeychainStore.hasSecret(ofKind: .openAIAPIKey) }

    func respond(
        systemPrompt: String,
        conversation: [MaintainChatTurn],
        maximumOutputTokens: Int
    ) async throws -> String {
        guard let key = KeychainStore.readSecret(ofKind: .openAIAPIKey), !key.isEmpty else {
            throw MaintainModelProviderError.noCredential(.openAIKeyNotSaved)
        }
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        messages.append(contentsOf: conversation.map { Self.messagePayload(forTurn: $0) })

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.model,
            "messages": messages,
            "max_tokens": maximumOutputTokens,
            "temperature": 0,
        ])

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MaintainModelProviderError.requestFailed(
                "openai turned the request down (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)). "
                    + "check the key saved in settings is still active, then try again."
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MaintainModelProviderError.requestFailed(
                "openai sent back a reply iris couldn't read. try again, and if it keeps "
                    + "happening connect a different model in settings."
            )
        }
        return content
    }

    /// One turn as Chat-Completions JSON. A turn with an attached image
    /// becomes the multimodal content-part array (base64 data URL); a plain
    /// turn stays a plain string. Static + pure for unit tests.
    nonisolated static func messagePayload(forTurn turn: MaintainChatTurn) -> [String: Any] {
        guard let attachedImagePNGData = turn.attachedImagePNGData else {
            return ["role": turn.role, "content": turn.text]
        }
        return ["role": turn.role, "content": [
            [
                "type": "image_url",
                "image_url": [
                    "url": "data:image/png;base64,\(attachedImagePNGData.base64EncodedString())",
                ],
            ] as [String: Any],
            ["type": "text", "text": turn.text] as [String: Any],
        ]]
    }
}

// MARK: - Resolution

enum MaintainModelProviderResolver {
    /// The provider to use for Tier C, in descending order of how much Iris can
    /// promise about it. Nil when the user brought no model access at all — the
    /// honest funded-tier ceiling.
    ///
    /// The order is not a quality ranking, it is a confidence ranking:
    ///
    ///   1. Codex login — the reader's ChatGPT account, driven through their
    ///      Codex CLI. First on measured results; see `allAvailable()` for the
    ///      numbers and for what they do not prove.
    ///   2. Anthropic — a pasted key or a Claude Code login, through the BYO
    ///      transport whose isolation property is proven and tested.
    ///   3. OpenAI key — a pasted key, one plain HTTPS call Iris fully controls.
    /// Where a deliberate choice is remembered. Absent means "no preference,
    /// use the confidence order below".
    private static let preferredProviderDefaultsKey = "irisPreferredEditProvider"

    /// The provider the reader chose, if they chose one and it is still usable.
    @MainActor
    static var preferredProviderIdentifier: String? {
        get { UserDefaults.standard.string(forKey: preferredProviderDefaultsKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: preferredProviderDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferredProviderDefaultsKey)
            }
        }
    }

    /// The provider Tier C will actually use.
    ///
    /// A REMEMBERED CHOICE WINS. The order below is a confidence ranking, not a
    /// quality one, and it was silently deciding for readers who had made their
    /// own decision: with a Claude login connected, a reader who had also
    /// connected Codex could never reach it, because nothing consulted them and
    /// nothing said so. That is the wrong default to be confident about — on the
    /// six-task edit battery, measured 2026-08-27 on real repositories with a
    /// held-out grader, Codex solved 6/6 and the Anthropic route 2/6.
    ///
    /// The stored choice is validated on every read rather than trusted: a
    /// reader can disconnect the provider they picked, and a preference for
    /// something no longer connected must fall through instead of failing.
    @MainActor
    static func firstAvailable() -> MaintainModelProviding? {
        let available = allAvailable()
        if let preferredProviderIdentifier,
           let chosen = available.first(where: { $0.identifier == preferredProviderIdentifier }) {
            return chosen
        }
        return available.first
    }

    /// Every provider the reader could currently use, most-preferred first.
    /// The panel uses this to say what Tier C would run on without committing
    /// to a run, and the parity harness uses it to enumerate what to compare.
    @MainActor
    static func allAvailable() -> [MaintainModelProviding] {
        // CODEX LEADS, changed 2026-08-27, and the reason is measurement rather
        // than taste. On the six-task edit battery — real repositories, real
        // defects, each graded by a suite held outside the repo that the agent
        // never sees — Codex solved 6/6 and the Anthropic route 2/6, with the
        // engine's own verdict agreeing with the independent grader on all
        // twelve runs. It was also fewer calls and less wall clock per task.
        //
        // The order used to be a CONFIDENCE ranking: Anthropic first because
        // Iris owns that transport end to end, Codex last because it is a
        // separate program with its own agent instincts. That reasoning is
        // still true and it is still why Codex is a subprocess behind a
        // re-validated read-only sandbox. It is just not a reason to hand a
        // reader the arm that solved a third as many tasks.
        //
        // HONEST LIMITS, because this is a default and defaults are quiet:
        // n = 6, the tasks are ours and were written knowing how the engine
        // works, and the two arms differ in model, reasoning budget, output cap
        // and temperature — so this is a statement about Iris's configuration,
        // not about two vendors. A reader who disagrees can now say so: the
        // picker in the composer writes `preferredProviderIdentifier`, and a
        // stored choice beats this order.
        let candidates: [MaintainModelProviding] = [
            CodexMaintainProvider(),
            AnthropicMaintainProvider(),
            OpenAIMaintainProvider(),
        ]
        return candidates.filter { $0.isAvailable }
    }
}

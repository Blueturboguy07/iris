//
//  MaintainFixAdapter.swift
//  leanring-buddy
//
//  Tier B of the fix ladder: a pooled recipe EXISTS but its exact diff no
//  longer fits this machine's version of the code. One constrained model
//  call adapts it — the pooled diagnosis (root causes outlive line numbers)
//  plus the stale diff plus the local file as it looks today, in; one
//  adapted unified diff, out, through a forced tool call. A fixed pipeline,
//  not an agent: no loop, no exploration, no shell access, hard output cap.
//
//  Ratified D4/D5: this call NEVER touches the funded tier. The provider is
//  built on a transport that is structurally bring-your-own — the resolver
//  returns the user's key or a failure; there is no branch that could reach
//  publik's proxy. Funded users simply don't get Tier B, and the UI says so
//  honestly rather than pretending.
//

import Foundation

/// What the adapter produced: a diff to try, or the honest reasons not to.
enum MaintainFixAdaptation: Sendable {
    case adaptedPatch(unifiedDiff: String)
    case modelCouldNotAdapt(reason: String)
    case noBringYourOwnKeyAvailable
}

@MainActor
protocol MaintainFixAdapting: AnyObject {
    func adaptPatch(
        diagnosis: String?,
        stalePatch: String,
        localFileExcerpts: String,
        appSlug: String
    ) async -> MaintainFixAdaptation
}

@MainActor
final class MaintainFixAdapter: MaintainFixAdapting {

    static let maximumOutputTokensPerAdaptCall = 1500

    /// A ClaudeAPI whose transport resolver ONLY knows the BYO route. No
    /// AccountService, no funded fallback — absence of a key is a terminal
    /// answer, not a reason to try publik's proxy.
    private lazy var bringYourOwnOnlyAPI = ClaudeAPI(resolveTransport: {
        // Either shape of the reader's own Anthropic credential — a pasted API
        // key or a connected Claude Code OAuth token — never the funded proxy.
        guard let transport = AnthropicBringYourOwnCredential.currentTransport() else {
            return .failure(.noCredentialsAvailable)
        }
        return .success(transport)
    })

    var bringYourOwnKeyIsAvailable: Bool {
        AnthropicBringYourOwnCredential.isAvailable
    }

    func adaptPatch(
        diagnosis: String?,
        stalePatch: String,
        localFileExcerpts: String,
        appSlug: String
    ) async -> MaintainFixAdaptation {
        guard bringYourOwnKeyIsAvailable else { return .noBringYourOwnKeyAvailable }

        let systemPrompt = """
        You adapt a known bug fix to a slightly different version of the same \
        codebase. The fix below was verified on other machines; its line \
        anchors no longer match this machine's files. Produce the SAME change \
        re-anchored to the code as it looks now — never a different fix, never \
        additional changes, never touched files the original did not touch. \
        If the code has changed so much that the original fix no longer makes \
        sense, say so via cannot_adapt instead of guessing.
        Call adapt_patch exactly once.
        """

        let report = """
        App: \(appSlug)
        Root-cause diagnosis from the pooled recipe:
        \(diagnosis ?? "(none recorded)")

        The verified-but-stale unified diff:
        ```
        \(String(stalePatch.prefix(8000)))
        ```

        The touched files as they look on THIS machine today:
        ```
        \(String(localFileExcerpts.prefix(12000)))
        ```
        """

        do {
            let message = try await bringYourOwnOnlyAPI.respondWithTools(
                systemPrompt: systemPrompt,
                userMessageText: report,
                tools: [Self.adaptPatchTool],
                toolChoice: ["type": "tool", "name": "adapt_patch"],
                maximumOutputTokens: Self.maximumOutputTokensPerAdaptCall
            )
            guard let toolUse = message.toolUses.first(where: { $0.name == "adapt_patch" }),
                  let input = toolUse.inputObject else {
                return .modelCouldNotAdapt(reason: "no adapt_patch call in the response")
            }
            if let cannotAdapt = input["cannot_adapt"] as? String, !cannotAdapt.isEmpty {
                return .modelCouldNotAdapt(reason: cannotAdapt)
            }
            guard let adapted = input["unified_diff"] as? String,
                  adapted.contains("--- "), adapted.contains("+++ ") else {
                return .modelCouldNotAdapt(reason: "response carried no usable diff")
            }
            return .adaptedPatch(unifiedDiff: adapted)
        } catch {
            return .modelCouldNotAdapt(reason: error.localizedDescription)
        }
    }

    private static let adaptPatchTool: [String: Any] = [
        "name": "adapt_patch",
        "description": "Return the known fix re-anchored to this machine's code, or decline.",
        "input_schema": [
            "type": "object",
            "properties": [
                "unified_diff": [
                    "type": "string",
                    "description": "The adapted fix as a unified diff against the files shown, same change, new anchors.",
                ],
                "cannot_adapt": [
                    "type": "string",
                    "description": "Set INSTEAD of unified_diff when the code has diverged past honest re-anchoring — one sentence why.",
                ],
            ],
        ] as [String: Any],
    ]
}

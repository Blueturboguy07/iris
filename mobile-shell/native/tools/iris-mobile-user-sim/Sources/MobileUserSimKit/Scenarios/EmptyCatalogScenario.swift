import Foundation
import IrisMobileShellCore

/// PLAN.md Phase 0 acceptance S0: "Browse shows the empty-catalog
/// explanation (the public catalog has 0 descriptors)." Exercises the real
/// `PublikMobileCatalogClient.fetchCatalog()` decode path and the real
/// `NativeMobileMarketplacePolicy.isVisibleInBrowse` over a genuinely empty
/// `{"apps":[]}` response, then checks a plain-language explanation exists.
///
/// Scope, stated honestly: this proves the Core decode and marketplace
/// policy behave, not that the real Host catalog view renders an honest
/// empty state instead of a blank screen or an infinite spinner. That is
/// flagged in INTEGRATION_HOOKS.md as a Host-side check for the integrator
/// (or a human on a device), since `NativeShellCatalogView.swift` is not in
/// this package's dependency graph.
public final class EmptyCatalogScenario: MobileScenario {
    public let id = "empty-catalog"
    public let title = "Empty public catalog shows an honest explanation state"
    public let seedString = "empty-catalog"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p1NonTechnical]

    public init(scratchRoot: URL) throws {}

    public func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome {
        env.world.setNetwork(.catalogEmpty)
        env.transport.setLiveCatalog(Data("{\"apps\":[]}".utf8))

        let apps = try await env.catalogClient.fetchCatalog()
        try Oracle.requireEqual(apps.count, 0, "empty-catalog-decodes-to-zero-apps", failureClass: .setupPackaging)

        let visible = apps.filter(NativeMobileMarketplacePolicy.isVisibleInBrowse)
        try Oracle.requireEqual(visible.count, 0, "empty-catalog-nothing-visible-in-browse", failureClass: .hostSide)

        let explanation = PlainLanguage.emptyCatalogExplanation()
        try Oracle.require(
            !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "empty-catalog-has-explanation-text", "the empty-catalog explanation was blank",
            failureClass: .hostSide
        )
        try Oracle.require(
            !explanation.lowercased().contains("error") && !explanation.lowercased().contains("exception"),
            "empty-catalog-explanation-is-plain-language",
            "the explanation reads like a raw error instead of a plain-language state: \(explanation)",
            failureClass: .hostSide
        )

        return ScenarioOutcome(
            passed: true,
            message: "An empty catalog decodes to zero apps and Browse shows a plain-language explanation.",
            personaInterview: PersonaInterview(
                didFinish: true,
                lastHonestMessage: explanation,
                knewWhatToDoNext: true
            ),
            evidence: ["explanation": explanation]
        )
    }
}

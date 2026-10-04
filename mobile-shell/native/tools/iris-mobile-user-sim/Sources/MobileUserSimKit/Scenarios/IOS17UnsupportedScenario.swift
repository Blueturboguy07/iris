import Foundation
import IrisMobileShellCore

/// PLAN.md section 7 edge case: "iOS 17 devices (storage capability only, so
/// Kneecap and FreeHarmony are unsupported and must say so)." Reviews a real
/// package requesting media capabilities under a device world whose
/// capability policy mirrors `NativeWebStorageConfiguration.capabilityPolicy`
/// for iOS 17 (storage only; see `SimulatedOSVersion.mirroredHostCapabilityPolicy`),
/// then checks the real Core refusal and a plain-language explanation.
public final class IOS17UnsupportedScenario: MobileScenario {
    public let id = "ios17-media-unsupported"
    public let title = "iOS 17 device reports media apps as unsupported in plain words"
    public let seedString = "ios17-media-unsupported"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p3EdgeUser]

    private let appId = "publik.ios17mediaapp"
    private let projectId = "publik.ios17mediaapp.mobile"
    private let package: GeneratedPackage
    private let requestedCapabilities = ["web.media.camera", "web.media.export", "web.storage"]

    public init(scratchRoot: URL) throws {
        package = try PackageFixture.generate(
            content: TestContent.html("ios17-media-app-v1"),
            nonce: String(repeating: "7", count: 63) + "0",
            capabilities: requestedCapabilities,
            appId: appId,
            projectId: projectId,
            displayName: "Media App",
            workDirectory: scratchRoot.appendingPathComponent("ios17-media-unsupported/gen-0", isDirectory: true)
        )
    }

    public func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome {
        try Oracle.requireEqual(
            persona.osVersion, .ios17, "ios17-scenario-requires-ios17-persona", failureClass: .setupPackaging
        )
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)

        let review = try await env.coordinator.reviewImport(packageBytes: package.bytes)
        let expectedUnsupported = ["web.media.camera", "web.media.export"]
        try Oracle.requireEqual(
            review.unsupportedCapabilities, expectedUnsupported,
            "ios17-review-flags-unsupported-media-capabilities", failureClass: .appSide
        )

        var thrown: Error?
        do {
            _ = try await env.coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: review.reviewToken,
                packageSHA256: review.packageSHA256
            )
        } catch {
            thrown = error
        }
        guard let thrown else {
            throw OracleFailure(
                "ios17-stage-must-be-refused",
                "staging an app that requests unsupported media capabilities on iOS 17 unexpectedly succeeded",
                failureClass: .appSide
            )
        }
        guard let shellError = thrown as? NativeShellError,
              shellError == .unsupportedCapabilities(expectedUnsupported) else {
            throw OracleFailure(
                "ios17-stage-refusal-reason",
                "expected NativeShellError.unsupportedCapabilities(\(expectedUnsupported)), got \(thrown)",
                failureClass: .appSide
            )
        }

        let explanation = PlainLanguage.unsupportedCapabilitiesExplanation(
            appName: "Media App",
            capabilities: review.unsupportedCapabilities,
            osName: persona.osVersion.plainLanguageName
        )
        try Oracle.require(
            explanation.contains("camera") && explanation.contains("saving exported files"),
            "ios17-explanation-uses-plain-words",
            "expected plain words for the unsupported capabilities, got: \(explanation)",
            failureClass: .hostSide
        )
        try Oracle.require(
            !explanation.contains("web.media"),
            "ios17-explanation-hides-raw-capability-ids",
            "the explanation leaked a raw capability id: \(explanation)",
            failureClass: .hostSide
        )

        // Ground truth: the review-only inspection and the refused stage
        // left nothing installed.
        let library = try await env.coordinator.refreshLibrary()
        try Oracle.requireEqual(library.count, 0, "ios17-nothing-installed-after-refusal", failureClass: .hostSide)
        _ = identity

        return ScenarioOutcome(
            passed: true,
            message: "Media App's camera and export capabilities are correctly reported unsupported on iOS 17, in plain words.",
            personaInterview: PersonaInterview(
                didFinish: false,
                lastHonestMessage: explanation,
                knewWhatToDoNext: true
            ),
            evidence: ["explanation": explanation, "unsupportedCapabilities": expectedUnsupported.joined(separator: ",")]
        )
    }
}

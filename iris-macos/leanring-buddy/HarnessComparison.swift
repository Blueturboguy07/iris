import Foundation
import CryptoKit

/// Fixed requested roles for the first experiment. This is not automatic routing.
nonisolated enum HarnessImplementationArm: String, Codable, CaseIterable, Sendable {
    case astraLow
    case lunaXHigh

    var route: HarnessModelRoute {
        switch self {
        case .astraLow: return HarnessModelRoute(model: "gpt-6-astra", effort: "low")
        case .lunaXHigh: return HarnessModelRoute(model: "gpt-5.6-luna", effort: "xhigh")
        }
    }
}

nonisolated struct HarnessModelRoute: Codable, Equatable, Sendable {
    let model: String
    let effort: String
    static let planner = HarnessModelRoute(model: "gpt-6-astra", effort: "medium")

    var description: String { "Requested: \(model), effort: \(effort)" }
}

/// The evaluator owns these bytes. The builder cannot redefine success by
/// replacing its own plan, starting source or expected results mid-comparison.
nonisolated struct HarnessFrozenComparison: Codable, Equatable, Sendable {
    let caseID: String
    let sourceRevision: String
    let sourceDigest: String
    let acceptedBriefDigest: String
    let acceptanceContractDigest: String
    let plannerRoute: HarnessModelRoute

    enum ValidationError: Error, Equatable {
        case missingIdentity
        case oversizedMaterial
        case changedSource
        case changedBrief
        case changedAcceptanceContract
    }

    init(caseID: String, sourceRevision: String, sourceManifest: Data,
         acceptedBrief: Data, acceptanceContract: Data) throws {
        guard !caseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceManifest.isEmpty, !acceptedBrief.isEmpty, !acceptanceContract.isEmpty else {
            throw ValidationError.missingIdentity
        }
        guard caseID.utf8.count <= 256, sourceRevision.utf8.count <= 256,
              sourceManifest.count <= 1_000_000, acceptedBrief.count <= 64_000,
              acceptanceContract.count <= 256_000 else {
            throw ValidationError.oversizedMaterial
        }
        self.caseID = caseID
        self.sourceRevision = sourceRevision
        self.sourceDigest = Self.digest(sourceManifest)
        self.acceptedBriefDigest = Self.digest(acceptedBrief)
        self.acceptanceContractDigest = Self.digest(acceptanceContract)
        self.plannerRoute = .planner
    }

    func validate(sourceManifest: Data, acceptedBrief: Data, acceptanceContract: Data) throws {
        guard Self.digest(sourceManifest) == sourceDigest else { throw ValidationError.changedSource }
        guard Self.digest(acceptedBrief) == acceptedBriefDigest else { throw ValidationError.changedBrief }
        guard Self.digest(acceptanceContract) == acceptanceContractDigest else {
            throw ValidationError.changedAcceptanceContract
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Builder statements are deliberately absent from the evidence inputs.
/// A host evaluator supplies observed results from outside the editable tree.
nonisolated enum HarnessAcceptanceGate {
    enum Result: String, Codable, Sendable { case passed, failed, notRun }
    struct Check: Codable, Equatable, Sendable {
        let id: String
        let revision: String
        let result: Result
    }
    enum Verdict: Equatable, Sendable {
        case accepted
        case incomplete([String])
        case rejected([String])
    }

    static func evaluate(requiredIDs: [String], revision: String,
                         observed: [Check], scopeIsIntact: Bool) -> Verdict {
        guard scopeIsIntact else { return .rejected(["The allowed edit scope changed."]) }
        guard !revision.isEmpty, !requiredIDs.isEmpty,
              requiredIDs.allSatisfy({ !$0.isEmpty }), Set(requiredIDs).count == requiredIDs.count else {
            return .rejected(["The acceptance contract is missing or invalid."])
        }
        guard Set(observed.map(\.id)).count == observed.count else {
            return .rejected(["Duplicate check results require reconciliation."])
        }
        let failed = observed.filter { requiredIDs.contains($0.id) && $0.revision == revision && $0.result == .failed }
        if !failed.isEmpty { return .rejected(failed.map(\.id)) }
        let missing = requiredIDs.filter { id in
            !observed.contains { $0.id == id && $0.revision == revision && $0.result == .passed }
        }
        return missing.isEmpty ? .accepted : .incomplete(missing)
    }
}

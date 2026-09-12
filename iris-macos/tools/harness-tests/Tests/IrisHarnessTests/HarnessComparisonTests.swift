import Foundation
import Testing
@testable import IrisHarness

@Test func comparisonUsesUserRequestedFixedRoles() {
    #expect(HarnessModelRoute.planner == HarnessModelRoute(model: "gpt-6-astra", effort: "medium"))
    #expect(HarnessImplementationArm.astraLow.route.effort == "low")
    #expect(HarnessImplementationArm.lunaXHigh.route == HarnessModelRoute(model: "gpt-5.6-luna", effort: "xhigh"))
}

@Test func bothArmsMustUseIdenticalStartingMaterial() throws {
    let source = Data("versioned source manifest".utf8)
    let brief = Data("the same accepted plan".utf8)
    let contract = Data("external checks".utf8)
    let frozen = try HarnessFrozenComparison(caseID: "import-duplicates", sourceRevision: "r1",
        sourceManifest: source, acceptedBrief: brief, acceptanceContract: contract)
    for _ in HarnessImplementationArm.allCases {
        try frozen.validate(sourceManifest: source, acceptedBrief: brief, acceptanceContract: contract)
    }
    #expect(throws: HarnessFrozenComparison.ValidationError.changedBrief) {
        try frozen.validate(sourceManifest: source, acceptedBrief: Data("a better plan for just one arm".utf8), acceptanceContract: contract)
    }
    #expect(throws: HarnessFrozenComparison.ValidationError.changedAcceptanceContract) {
        try frozen.validate(sourceManifest: source, acceptedBrief: brief, acceptanceContract: Data("weaker checks".utf8))
    }
    #expect(throws: HarnessFrozenComparison.ValidationError.changedSource) {
        try frozen.validate(sourceManifest: Data("other arm's finished patch".utf8), acceptedBrief: brief, acceptanceContract: contract)
    }
}

@Test func emptyAcceptanceNeverPassesVacuously() {
    #expect(HarnessAcceptanceGate.evaluate(requiredIDs: [], revision: "r1", observed: [], scopeIsIntact: true)
        == .rejected(["The acceptance contract is missing or invalid."]))
}

@Test(arguments: ["search", "import", "background-job", "cross-app", "preferences"])
func buildSuccessDoesNotSubstituteForFeatureBehavior(domain: String) {
    let required = ["\(domain)-new-behavior", "\(domain)-regression"]
    let build = HarnessAcceptanceGate.Check(id: "build", revision: "r2", result: .passed)
    #expect(HarnessAcceptanceGate.evaluate(requiredIDs: required, revision: "r2", observed: [build], scopeIsIntact: true)
        == .incomplete(required))
    let passing = required.map { HarnessAcceptanceGate.Check(id: $0, revision: "r2", result: .passed) }
    #expect(HarnessAcceptanceGate.evaluate(requiredIDs: required, revision: "r2", observed: passing, scopeIsIntact: true) == .accepted)
    #expect(HarnessAcceptanceGate.evaluate(requiredIDs: required, revision: "r3", observed: passing, scopeIsIntact: true)
        == .incomplete(required))
}

@Test func rejectionAndDuplicateEvidenceCannotBeHiddenByPasses() {
    let failed = HarnessAcceptanceGate.Check(id: "payload-integrity", revision: "r1", result: .failed)
    let passed = HarnessAcceptanceGate.Check(id: "payload-integrity", revision: "r1", result: .passed)
    #expect(HarnessAcceptanceGate.evaluate(requiredIDs: [failed.id], revision: "r1", observed: [failed], scopeIsIntact: true)
        == .rejected([failed.id]))
    #expect(HarnessAcceptanceGate.evaluate(requiredIDs: [failed.id], revision: "r1", observed: [failed, passed], scopeIsIntact: true)
        == .rejected(["Duplicate check results require reconciliation."]))
    #expect(HarnessAcceptanceGate.evaluate(requiredIDs: [failed.id], revision: "r1", observed: [passed], scopeIsIntact: false)
        == .rejected(["The allowed edit scope changed."]))
}

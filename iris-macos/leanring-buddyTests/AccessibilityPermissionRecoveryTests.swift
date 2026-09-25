import Testing
#if canImport(IrisUsability)
@testable import IrisUsability
#else
@testable import Iris
#endif

struct AccessibilityPermissionRecoveryTests {
    @Test func repairGuidanceOnlyAppearsWhenAccessibilityIsMissing() {
        #expect(AccessibilityPermissionRecovery.shouldShowRepairInstructions(isGranted: false))
        #expect(!AccessibilityPermissionRecovery.shouldShowRepairInstructions(isGranted: true))
        #expect(AccessibilityPermissionRecovery.Action.allCases.map(\.rawValue)
            == ["Open Settings", "Show Iris"])
        #expect(AccessibilityPermissionRecovery.repairInstructions.contains("minus"))
    }
}

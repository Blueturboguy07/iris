import Testing
#if canImport(Iris)
@testable import Iris
#else
@testable import IrisUsability
#endif

struct EditVerificationReceiptTests {
    @Test func skippedChecksAreNotGreen() {
        let receipt = EditVerificationReceipt(buildPassed: nil, testsPassed: nil)
        #expect(receipt.summary == "Build: Not run. Tests: Not run. Behavior still needs confirmation.")
        #expect(receipt.commitTrailer == "Applied: build-not-run, suite-not-run")
        #expect(!receipt.anyCheckRan)
        #expect(!receipt.hasFailure)
    }

    @Test func buildAloneDoesNotClaimTestsOrBehavior() {
        let receipt = EditVerificationReceipt(buildPassed: true, testsPassed: nil)
        #expect(receipt.commitTrailer == "Applied: build-green, suite-not-run")
        #expect(receipt.summary.contains("Behavior still needs confirmation"))
        #expect(receipt.anyCheckRan)
    }

    @Test func passingChecksDoNotClaimAWorkingFeature() {
        let receipt = EditVerificationReceipt(buildPassed: true, testsPassed: true)
        #expect(receipt.commitTrailer == "Applied: build-green, suite-green")
        #expect(!receipt.summary.contains("Bug repro passed"))
    }

    @Test func failuresRemainExplicit() {
        let receipt = EditVerificationReceipt(buildPassed: false, testsPassed: false)
        #expect(receipt.commitTrailer == "Applied: build-failed, suite-failed")
        #expect(receipt.summary.contains("Build: Failed. Tests: Failed."))
        #expect(receipt.hasFailure)
    }

    @Test func aProvenReproKeepsItsEvidenceWithoutInventingOtherChecks() {
        let receipt = EditVerificationReceipt(buildPassed: nil, testsPassed: true, symptomReproduced: true)
        #expect(receipt.commitTrailer == "Verified: repro-legs, build-not-run, suite-green")
        #expect(receipt.anyCheckRan)
    }

    @Test func packagingInstallationAndBehaviorStartUnconfirmed() {
        let progress = EditDeliveryProgress()
        #expect(!progress.codeSaved)
        #expect(!progress.freshAppBuilt)
        #expect(!progress.installedCopyReplaced)
        #expect(!progress.relaunched)
        #expect(progress.behavior == "Not confirmed")
    }
}

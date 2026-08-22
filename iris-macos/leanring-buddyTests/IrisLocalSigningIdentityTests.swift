//
//  IrisLocalSigningIdentityTests.swift
//  leanring-buddyTests
//
//  The pure, deterministic half of stable code signing for a rebuilt app: which
//  keychain identity gets picked, what a signed bundle's metadata actually says,
//  and the exact sentences a reader is shown about their permissions.
//
//  Nothing here creates a certificate, touches the keychain, or signs anything.
//  Those are the parts that need a real Mac and a real bundle, and they are
//  honestly out of a unit test's reach — so every one of them is behind a
//  process call, and everything on THIS side of that call is tested here.
//

import Foundation
import Testing
@testable import Iris

@MainActor
@Suite struct IrisLocalSigningIdentityTests {

    // MARK: - Picking an identity out of `security find-identity`

    /// The real shape of `security find-identity -v -p codesigning` output on a
    /// Mac that has a Developer ID, an Apple Development identity, and the
    /// certificate Iris made for itself.
    static let findIdentityOutputWithEveryKindOfIdentity = """
      1) 0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F60718293 "Apple Development: Mann Bellani (ABCDE12345)"
      2) A1B2C3D4E5F60718293A4B5C6D7E8F9021324354 "Developer ID Application: Mann Bellani (R5R3ZS54LV)"
      3) 1122334455667788990011223344556677889900 "Iris Local Code Signing"
         3 valid identities found
    """

    @Test func aDeveloperIDIsPreferredOverEveryOtherIdentity() {
        let identity = IrisLocalSigningIdentity.preferredStableIdentity(
            inFindIdentityOutput: Self.findIdentityOutputWithEveryKindOfIdentity
        )
        #expect(identity == .developerID(name: "Developer ID Application: Mann Bellani (R5R3ZS54LV)"))
        // A Developer ID is the one identity a shipped copy of the app would
        // carry, so a rebuild signed with it is closest to the installed app.
        #expect(identity?.isAppleIssuedDeveloperID == true)
    }

    @Test func theIrisLocalCertificateIsUsedWhenThereIsNoDeveloperID() {
        let findIdentityOutput = """
          1) 0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F60718293 "Apple Development: Mann Bellani (ABCDE12345)"
          2) 1122334455667788990011223344556677889900 "Iris Local Code Signing"
             2 valid identities found
        """
        let identity = IrisLocalSigningIdentity.preferredStableIdentity(
            inFindIdentityOutput: findIdentityOutput
        )
        #expect(identity == .irisLocalCertificate(name: "Iris Local Code Signing"))
        // Stable, but NOT an Apple-issued identity — copy must never imply it is.
        #expect(identity?.isAppleIssuedDeveloperID == false)
    }

    @Test func anAppleDevelopmentIdentityAloneIsNotAStableIdentityIrisWillUse() {
        // Deliberate: signing a locally rebuilt copy of someone else's app with
        // the reader's Apple Development identity is not what that identity is
        // for. No stable identity here means "ask, or stay ad-hoc and say so".
        let findIdentityOutput = """
          1) 0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F60718293 "Apple Development: Mann Bellani (ABCDE12345)"
             1 valid identities found
        """
        #expect(IrisLocalSigningIdentity.preferredStableIdentity(
            inFindIdentityOutput: findIdentityOutput
        ) == nil)
    }

    @Test func anEmptyKeychainListingYieldsNoIdentity() {
        #expect(IrisLocalSigningIdentity.preferredStableIdentity(
            inFindIdentityOutput: "     0 valid identities found"
        ) == nil)
        #expect(IrisLocalSigningIdentity.preferredStableIdentity(inFindIdentityOutput: "") == nil)
    }

    @Test func theValidIdentitiesFoundSummaryIsNotMistakenForAnIdentity() {
        let names = IrisLocalSigningIdentity.codesigningIdentityNames(
            inFindIdentityOutput: Self.findIdentityOutputWithEveryKindOfIdentity
        )
        #expect(names.count == 3)
        #expect(!names.contains { $0.contains("valid identities found") })
    }

    @Test func anIdentityNameContainingParenthesesSurvivesParsing() {
        // The team id in every real Developer ID name is parenthesized, so the
        // parser must not stop at the first ")" it sees.
        let names = IrisLocalSigningIdentity.codesigningIdentityNames(
            inFindIdentityOutput: #"  1) AAAA "Developer ID Application: Someone (TEAM1) (TEAM2)""#
        )
        #expect(names == ["Developer ID Application: Someone (TEAM1) (TEAM2)"])
    }

    @Test func theLoginKeychainPathIsReadOutOfItsQuotes() {
        #expect(IrisLocalSigningIdentity.quotedKeychainPath(
            inSecurityKeychainOutput: "    \"/Users/mann/Library/Keychains/login.keychain-db\"\n"
        ) == "/Users/mann/Library/Keychains/login.keychain-db")
        #expect(IrisLocalSigningIdentity.quotedKeychainPath(inSecurityKeychainOutput: "no quotes here") == nil)
    }

    // MARK: - Reading a bundle's entitlements back

    static let entitlementsPropertyListText = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.apple.security.device.camera</key>
        <true/>
        <key>com.apple.security.device.microphone</key>
        <false/>
        <key>com.apple.security.application-groups</key>
        <array><string>group.example</string></array>
    </dict>
    </plist>
    """

    @Test func anEntitlementSetToTrueReadsAsGranted() {
        #expect(IrisLocalSigningIdentity.entitlementsDeclareKeyAsTrue(
            "com.apple.security.device.camera",
            inPropertyListText: Self.entitlementsPropertyListText
        ))
    }

    @Test func anEntitlementSetToFalseOrAbsentDoesNotReadAsGranted() {
        #expect(!IrisLocalSigningIdentity.entitlementsDeclareKeyAsTrue(
            "com.apple.security.device.microphone",
            inPropertyListText: Self.entitlementsPropertyListText
        ))
        #expect(!IrisLocalSigningIdentity.entitlementsDeclareKeyAsTrue(
            "com.apple.security.network.client",
            inPropertyListText: Self.entitlementsPropertyListText
        ))
        // A non-boolean value is not a grant either.
        #expect(!IrisLocalSigningIdentity.entitlementsDeclareKeyAsTrue(
            "com.apple.security.application-groups",
            inPropertyListText: Self.entitlementsPropertyListText
        ))
        #expect(!IrisLocalSigningIdentity.entitlementsDeclareKeyAsTrue(
            "com.apple.security.device.camera", inPropertyListText: ""
        ))
    }

    @Test func aTruncatedEntitlementsPlistStillAnswersFromItsText() {
        // `codesign` output can arrive clipped. The property-list parser rejects
        // it outright, and a rejected parse must not be reported as "the app
        // doesn't have that entitlement" — the fallback text scan answers.
        let clippedPropertyList = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>com.apple.security.device.camera</key>
            <true/>
        """
        #expect(IrisLocalSigningIdentity.entitlementsDeclareKeyAsTrue(
            "com.apple.security.device.camera", inPropertyListText: clippedPropertyList
        ))
    }

    @Test func theEntitlementsPlistIsCutOutOfCodesignsSurroundingNoise() {
        // Older codesign prefixes the XML with a binary blob header, and every
        // version prints its own chatter around it.
        let rawCodesignOutput = "Executable=/Applications/Thing.app/Contents/MacOS/Thing\n"
            + "\u{FADE}\u{7171}\u{0000}"
            + Self.entitlementsPropertyListText
            + "\nWarning: something unrelated\n"
        let extracted = IrisLocalSigningIdentity.propertyListTextExtracted(
            fromCodesignEntitlementsOutput: rawCodesignOutput
        )
        #expect(extracted.hasPrefix("<?xml"))
        #expect(extracted.hasSuffix("</plist>"))
        #expect(IrisLocalSigningIdentity.entitlementsDeclareKeyAsTrue(
            "com.apple.security.device.camera", inPropertyListText: extracted
        ))
    }

    @Test func anUnsignedBundlesEntitlementsOutputExtractsToNothing() {
        #expect(IrisLocalSigningIdentity.propertyListTextExtracted(
            fromCodesignEntitlementsOutput: "code object is not signed at all"
        ).isEmpty)
        #expect(IrisLocalSigningIdentity.propertyListTextExtracted(
            fromCodesignEntitlementsOutput: ""
        ).isEmpty)
    }

    @Test func theDesignatedRequirementIsReadOutOfCodesignOutput() {
        let codesignOutput = """
        Executable=/Applications/Thing.app/Contents/MacOS/Thing
        designated => identifier "com.example.thing" and anchor apple generic and certificate leaf[subject.CN] = "Developer ID Application: Someone (TEAM1)"
        """
        let requirement = IrisLocalSigningIdentity.designatedRequirementText(inCodesignOutput: codesignOutput)
        #expect(requirement?.hasPrefix("identifier \"com.example.thing\"") == true)
        #expect(IrisLocalSigningIdentity.designatedRequirementText(
            inCodesignOutput: "code object is not signed at all"
        ) == nil)
    }

    // MARK: - Packaging expectations (the "verified as a no-op" fix)

    @Test func everyUnmetPackagingExpectationIsNamedInItsOwnFailure() {
        let expectations = PackagingExpectations(
            infoPlistKeysThatMustExist: ["NSCameraUsageDescription", "CFBundleShortVersionString"],
            entitlementKeysThatMustBeTrue: ["com.apple.security.device.camera", "com.apple.security.device.microphone"]
        )
        let failures = IrisLocalSigningIdentity.describePackagingExpectationFailures(
            expectations: expectations,
            infoPlistKeysPresentInArtifact: ["CFBundleShortVersionString"],
            entitlementsPropertyListText: Self.entitlementsPropertyListText
        )
        // The missing Info.plist key and the false entitlement each get their own
        // line; the two that ARE satisfied say nothing.
        #expect(failures.count == 2)
        #expect(failures.contains { $0.contains("NSCameraUsageDescription") })
        #expect(failures.contains { $0.contains("com.apple.security.device.microphone") })
        #expect(!failures.contains { $0.contains("CFBundleShortVersionString") })
        #expect(!failures.contains { $0.contains("com.apple.security.device.camera") })
        // The reader is told what it MEANS, not just which key is absent.
        #expect(failures.allSatisfy { $0.contains("didn't reach the built app") })
    }

    @Test func aPackagedArtifactThatMeetsEveryExpectationReportsNoFailures() {
        let expectations = PackagingExpectations(
            infoPlistKeysThatMustExist: ["NSCameraUsageDescription"],
            entitlementKeysThatMustBeTrue: ["com.apple.security.device.camera"]
        )
        let failures = IrisLocalSigningIdentity.describePackagingExpectationFailures(
            expectations: expectations,
            infoPlistKeysPresentInArtifact: ["NSCameraUsageDescription", "CFBundleIdentifier"],
            entitlementsPropertyListText: Self.entitlementsPropertyListText
        )
        #expect(failures.isEmpty)
    }

    @Test func expectingNothingIsNotAFailure() {
        let noExpectations = PackagingExpectations()
        #expect(noExpectations.isEmpty)
        #expect(IrisLocalSigningIdentity.describePackagingExpectationFailures(
            expectations: noExpectations,
            infoPlistKeysPresentInArtifact: [],
            entitlementsPropertyListText: ""
        ).isEmpty)
    }

    // MARK: - Inside-out signing order

    @Test func nestedCodeIsListedDeepestFirstAndSkipsSymlinksAndTheMainExecutable() throws {
        let bundlePath = try Self.makeFakeApplicationBundle()

        let nestedCodePaths = IrisLocalSigningIdentity
            .nestedCodePathsToSignDeepestFirst(inApplicationBundleAtPath: bundlePath)
        // Compared relative to the bundle, because the scan reports paths the way
        // the directory enumerator spells them (/private/var/… for a temp
        // directory the fixture created as /var/…) — the prefix is not the point
        // of this test, the ORDER is.
        let relativePaths = nestedCodePaths.map { nestedCodePath -> String in
            guard let bundleRange = nestedCodePath.range(of: "/Foo.app/") else { return nestedCodePath }
            return String(nestedCodePath[bundleRange.upperBound...])
        }

        // Deepest first is the whole point: a dylib inside a framework must be
        // signed before the framework, or the framework's seal breaks the moment
        // the dylib changes. Ties are alphabetical so the order is deterministic.
        #expect(relativePaths == [
            "Contents/Frameworks/Bar.framework/Versions/A/Libraries/inner.dylib",
            "Contents/Library/LoginItems/Launcher.app",
            "Contents/Frameworks/Bar.framework",
            "Contents/MacOS/helper-tool",
        ])
        // The app's own executable is signed as part of the app bundle, never on
        // its own, and a framework's Versions/Current shortcut points at code
        // that is already in the list.
        #expect(!relativePaths.contains("Contents/MacOS/Foo"))
        #expect(!relativePaths.contains { $0.hasSuffix("Versions/Current") })
        // A nested bundle's OWN executable is covered by signing that bundle.
        #expect(!relativePaths.contains { $0.contains("Launcher.app/Contents/MacOS") })
    }

    @Test func aPathThatIsNotAnAppBundleHasNoNestedCodeToSign() {
        #expect(IrisLocalSigningIdentity.nestedCodePathsToSignDeepestFirst(
            inApplicationBundleAtPath: "/tmp/definitely-not-here-\(UUID().uuidString).app"
        ).isEmpty)
    }

    // MARK: - What the reader is told about their permissions

    @Test func aSignedRebuildPromisesThePermissionsStay() {
        let summary = AppRelaunchService.signingSummary(
            forSigningOutcome: .signed,
            identity: .developerID(name: "Developer ID Application: Mann Bellani (R5R3ZS54LV)")
        )
        #expect(summary.contains("Developer ID Application: Mann Bellani (R5R3ZS54LV)"))
        #expect(summary.contains("keep this app's existing permissions"))
    }

    @Test func aFailedSigningLeadsWithThePermissionResetNotWithTheToolError() {
        let summary = AppRelaunchService.signingSummary(
            forSigningOutcome: .failed(reason: "resource fork, Finder information, or similar detritus not allowed"),
            identity: .irisLocalCertificate(name: "Iris Local Code Signing")
        )
        // The consequence the reader will actually notice comes first; the tool's
        // complaint is kept, but after it.
        #expect(summary.hasPrefix(AppRelaunchService.adHocSigningSummary))
        #expect(summary.contains("permissions may reset"))
        #expect(summary.contains("detritus not allowed"))
    }

    @Test func packagingWithNoSigningSeamWiredUpStaysHonestlyAdHoc() {
        // The default: no identity resolver injected, so nothing is signed and
        // the summary says exactly that. This is the sentence that keeps the old
        // behavior honest rather than silent.
        #expect(AppRelaunchService.adHocSigningSummary.contains("ad-hoc"))
        #expect(AppRelaunchService.adHocSigningSummary.contains("new app"))
        #expect(AppRelaunchService.adHocSigningSummary.contains("permissions may reset"))
        #expect(AppRelaunchService().resolveSigningIdentity == nil)
    }

    // MARK: - Fixture

    /// A fake `.app` on disk with the nesting a real one has: a versioned
    /// framework with its symlinks, a login item, a helper binary, and the app's
    /// own executable. Nothing here is signed or executed — it exists so the
    /// ORDER of signing can be asserted without a real bundle.
    private static func makeFakeApplicationBundle() throws -> String {
        let fileManager = FileManager.default
        let rootDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("iris-signing-fixture-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = rootDirectoryURL.appendingPathComponent("Foo.app", isDirectory: true)

        let directoriesToCreate = [
            "Contents/MacOS",
            "Contents/Frameworks/Bar.framework/Versions/A/Libraries",
            "Contents/Library/LoginItems/Launcher.app/Contents/MacOS",
        ]
        for relativeDirectory in directoriesToCreate {
            try fileManager.createDirectory(
                at: bundleURL.appendingPathComponent(relativeDirectory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let executableFileAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        let executableRelativePaths = [
            "Contents/MacOS/Foo",
            "Contents/MacOS/helper-tool",
            "Contents/Frameworks/Bar.framework/Versions/A/Bar",
            "Contents/Frameworks/Bar.framework/Versions/A/Libraries/inner.dylib",
            "Contents/Library/LoginItems/Launcher.app/Contents/MacOS/Launcher",
        ]
        for relativePath in executableRelativePaths {
            fileManager.createFile(
                atPath: bundleURL.appendingPathComponent(relativePath).path,
                contents: Data("not really a mach-o".utf8),
                attributes: executableFileAttributes
            )
        }

        // A real versioned framework has exactly these two symlinks, and both
        // point at code already reachable without them.
        try fileManager.createSymbolicLink(
            atPath: bundleURL.appendingPathComponent("Contents/Frameworks/Bar.framework/Versions/Current").path,
            withDestinationPath: "A"
        )
        try fileManager.createSymbolicLink(
            atPath: bundleURL.appendingPathComponent("Contents/Frameworks/Bar.framework/Bar").path,
            withDestinationPath: "Versions/Current/Bar"
        )

        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "Foo",
            "CFBundleIdentifier": "com.example.foo",
        ]
        let infoPlistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist, format: .xml, options: 0
        )
        try infoPlistData.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))

        return bundleURL.path
    }
}

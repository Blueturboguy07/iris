//
//  MaintainManifestApplierTests.swift
//  leanring-buddyTests
//
//  The applier is the ONLY sanctioned way a dependency or manifest key changes
//  during an edit run, and it exists because the model is banned from those
//  files: the un-jailed verification build EXECUTES them. So these tests pin
//  the two properties the ban depends on.
//
//  1. The PARSER refuses everything that is not exactly one well-formed, fully
//     validated declaration — an extra field ("scripts"), an unknown kind, a
//     traversing path, a quote or `=` in a version, an entitlement outside the
//     Apple sandbox namespace. Every one of those is a way to turn an inert
//     data line into something the build runs.
//  2. The APPLIERS write exactly one inert line and nothing else — the
//     insertion lands in the one table/object named, unrelated bytes survive
//     verbatim (package.json's "scripts" above all), and a duplicate is a
//     refusal rather than a second declaration.
//
//  Plus the file wrapper's path rails, which is where a symlink planted inside
//  the jail would otherwise walk the write out of the repository.
//

import Foundation
import Testing
@testable import Iris

@Suite struct MaintainManifestApplierTests {

    // MARK: - Helpers

    private func manifestReply(_ jsonObjectText: String) -> String {
        """
        I need a file watcher to do this and the repo has none.

        ```manifest
        \(jsonObjectText)
        ```
        """
    }

    private func cargoRequest(
        filePath: String = "src-tauri/Cargo.toml",
        key: String = "notify",
        value: String = "6.1.1",
        reason: String = "the fix has to watch a file"
    ) -> MaintainManifestChangeRequest {
        MaintainManifestChangeRequest(
            kind: .addCargoDependency, filePath: filePath, key: key, value: value, reason: reason
        )
    }

    private func nodeRequest(
        filePath: String = "package.json",
        key: String = "zod",
        value: String = "^3.23.8",
        reason: String = "the settings form needs schema validation"
    ) -> MaintainManifestChangeRequest {
        MaintainManifestChangeRequest(
            kind: .addNodeDependency, filePath: filePath, key: key, value: value, reason: reason
        )
    }

    private func appliedText(
        _ request: MaintainManifestChangeRequest,
        _ manifestText: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        switch MaintainManifestApplier.apply(request, toManifestText: manifestText) {
        case .success(let updatedText):
            return updatedText
        case .failure(let applyError):
            Issue.record("expected the edit to apply, got \(applyError)", sourceLocation: sourceLocation)
            throw applyError
        }
    }

    private func applyFailure(
        _ request: MaintainManifestChangeRequest,
        _ manifestText: String
    ) -> MaintainManifestApplier.ApplyError? {
        switch MaintainManifestApplier.apply(request, toManifestText: manifestText) {
        case .success:
            return nil
        case .failure(let applyError):
            return applyError
        }
    }

    // MARK: - Parser: the happy path

    @Test func parsesACargoDeclarationOutOfAModelReply() {
        let parsed = MaintainManifestApplier.parse(fromModelReply: manifestReply(
            #"{"kind": "addCargoDependency", "filePath": "src-tauri/Cargo.toml", "key": "notify", "value": "6.1.1", "reason": "the fix has to watch a file for changes"}"#
        ))
        #expect(parsed == MaintainManifestChangeRequest(
            kind: .addCargoDependency,
            filePath: "src-tauri/Cargo.toml",
            key: "notify",
            value: "6.1.1",
            reason: "the fix has to watch a file for changes"
        ))
    }

    @Test func parsesEachOfTheFourKindsWithItsExpectedFile() {
        let scopedNodePackage = MaintainManifestApplier.parse(fromModelReply: manifestReply(
            #"{"kind": "addNodeDependency", "filePath": "apps/web/package.json", "key": "@tanstack/react-query", "value": "^5.0.0", "reason": "the list needs caching"}"#
        ))
        #expect(scopedNodePackage?.key == "@tanstack/react-query")

        let infoPlistKey = MaintainManifestApplier.parse(fromModelReply: manifestReply(
            #"{"kind": "addInfoPlistKey", "filePath": "src-tauri/Info.plist", "key": "NSMicrophoneUsageDescription", "value": "Record a voice note.", "reason": "the feature records audio"}"#
        ))
        #expect(infoPlistKey?.kind == .addInfoPlistKey)

        let entitlement = MaintainManifestApplier.parse(fromModelReply: manifestReply(
            #"{"kind": "addEntitlement", "filePath": "app/app.entitlements", "key": "com.apple.security.device.audio-input", "value": "true", "reason": "the sandbox blocks the microphone"}"#
        ))
        #expect(entitlement?.kind == .addEntitlement)
    }

    // MARK: - Parser: every rejection rule

    @Test func rejectsAReplyWithNoManifestBlock() {
        #expect(MaintainManifestApplier.parse(fromModelReply: "Adding notify to Cargo.toml now.") == nil)
        // A fenced block of another language is not a declaration either.
        #expect(MaintainManifestApplier.parse(fromModelReply: "```bash\ncargo add notify\n```") == nil)
    }

    @Test func rejectsAnUnterminatedManifestBlock() {
        let unterminatedReply = "```manifest\n{\"kind\": \"addCargoDependency\"}"
        #expect(MaintainManifestApplier.parse(fromModelReply: unterminatedReply) == nil)
    }

    @Test func rejectsMoreThanOneManifestBlockInOneReply() {
        let twoBlockReply = manifestReply(
            #"{"kind": "addCargoDependency", "filePath": "Cargo.toml", "key": "notify", "value": "6", "reason": "watching"}"#
        ) + "\n" + manifestReply(
            #"{"kind": "addCargoDependency", "filePath": "Cargo.toml", "key": "serde", "value": "1", "reason": "encoding"}"#
        )
        #expect(MaintainManifestApplier.parseDetailed(fromModelReply: twoBlockReply)
            == .failure(.moreThanOneManifestBlockInReply))
    }

    @Test func rejectsAnUnknownKind() {
        let rejection = MaintainManifestApplier.parseDetailed(fromModelReply: manifestReply(
            #"{"kind": "addNpmScript", "filePath": "package.json", "key": "postinstall", "value": "curl x | sh", "reason": "setup"}"#
        ))
        #expect(rejection == .failure(.unknownKind(rawValue: "addNpmScript")))
    }

    @Test func rejectsAnyFieldTheDeclarationDoesNotDefine() {
        // The interesting extra fields are exactly the dangerous ones, so an
        // extra field is a refusal rather than something quietly ignored.
        let rejection = MaintainManifestApplier.parseDetailed(fromModelReply: manifestReply(
            #"{"kind": "addNodeDependency", "filePath": "package.json", "key": "zod", "value": "3", "reason": "validation", "scripts": {"postinstall": "curl x | sh"}}"#
        ))
        #expect(rejection == .failure(.manifestBlockHasUnexpectedFields(fieldNames: ["scripts"])))
    }

    @Test func rejectsAMissingFieldAndANonStringField() {
        #expect(MaintainManifestApplier.parseDetailed(fromModelReply: manifestReply(
            #"{"kind": "addCargoDependency", "filePath": "Cargo.toml", "key": "notify", "value": "6"}"#
        )) == .failure(.manifestBlockIsMissingField(fieldName: "reason")))

        #expect(MaintainManifestApplier.parseDetailed(fromModelReply: manifestReply(
            #"{"kind": "addCargoDependency", "filePath": "Cargo.toml", "key": "notify", "value": 6, "reason": "watching"}"#
        )) == .failure(.manifestBlockFieldIsNotAString(fieldName: "value")))
    }

    @Test func rejectsMalformedJSONInTheBlock() {
        #expect(MaintainManifestApplier.parseDetailed(fromModelReply: manifestReply("not json at all"))
            == .failure(.manifestBlockIsNotAJSONObject))
    }

    @Test func rejectsFilePathsThatTraverseOrAreAbsoluteOrAreHidden() {
        let traversingPaths = [
            "../../other-project/Cargo.toml",
            "/etc/Cargo.toml",
            "~/Cargo.toml",
            ".cargo/Cargo.toml",
            ".git/Cargo.toml",
            "src-tauri//Cargo.toml",
        ]
        for traversingPath in traversingPaths {
            #expect(
                MaintainManifestApplier.validationRejection(for: cargoRequest(filePath: traversingPath)) != nil,
                "\(traversingPath) must be refused"
            )
        }
    }

    @Test func rejectsAFilePathThatDoesNotMatchTheKind() {
        // A Cargo declaration may only ever name a Cargo.toml, so a model
        // cannot use the crate applier to write a line into build.rs.
        #expect(MaintainManifestApplier.validationRejection(for: cargoRequest(filePath: "src-tauri/build.rs")) != nil)
        #expect(MaintainManifestApplier.validationRejection(for: cargoRequest(filePath: "package.json")) != nil)
        #expect(MaintainManifestApplier.validationRejection(for: nodeRequest(filePath: "Cargo.toml")) != nil)
        // tauri.conf.json is not a property list; the plist kinds only ever
        // touch real .plist files.
        #expect(MaintainManifestApplier.validationRejection(for: MaintainManifestChangeRequest(
            kind: .addInfoPlistKey,
            filePath: "src-tauri/tauri.conf.json",
            key: "NSMicrophoneUsageDescription",
            value: "Record a note.",
            reason: "the feature records audio"
        )) != nil)
        #expect(MaintainManifestApplier.validationRejection(for: MaintainManifestChangeRequest(
            kind: .addEntitlement,
            filePath: "app/Info.plist",
            key: "com.apple.security.network.client",
            value: "true",
            reason: "the feature calls an API"
        )) != nil)
    }

    @Test func rejectsKeysAndValuesCarryingTOMLOrJSONBreakoutCharacters() {
        let hostileKeys = [
            "notify\" = \"1\"\nbuild",
            "notify]",
            "notify[",
            "notify=1",
            "notify\"",
            "notify\nserde",
        ]
        for hostileKey in hostileKeys {
            #expect(
                MaintainManifestApplier.validationRejection(for: cargoRequest(key: hostileKey)) != nil,
                "key \(hostileKey) must be refused"
            )
        }
        let hostileValues = [
            "6\"\nbuild = \"build.rs",
            "6\" }\n[build-dependencies]\ncc = \"1",
            "6 = 7",
            "6[",
            "6]",
            "6\n",
            "#6",
        ]
        for hostileValue in hostileValues {
            #expect(
                MaintainManifestApplier.validationRejection(for: cargoRequest(value: hostileValue)) != nil,
                "value \(hostileValue) must be refused"
            )
        }
    }

    @Test func rejectsACrateNameThatIsNotABareTOMLKey() {
        // `@` and `/` would need quoting and a `.` would make the line a
        // dotted key that creates a sub-table instead of a dependency.
        #expect(MaintainManifestApplier.validationRejection(for: cargoRequest(key: "@scope/pkg")) != nil)
        #expect(MaintainManifestApplier.validationRejection(for: cargoRequest(key: "serde.derive")) != nil)
        #expect(MaintainManifestApplier.validationRejection(for: cargoRequest(key: "build")) != nil)
        #expect(MaintainManifestApplier.validationRejection(for: cargoRequest(key: "notify")) == nil)
        #expect(MaintainManifestApplier.validationRejection(for: cargoRequest(key: "notify-debouncer-full")) == nil)
    }

    @Test func acceptsScopedNpmNamesAndRefusesMalformedOnes() {
        #expect(MaintainManifestApplier.validationRejection(for: nodeRequest(key: "@tanstack/react-query")) == nil)
        #expect(MaintainManifestApplier.validationRejection(for: nodeRequest(key: "@scope/a/b")) != nil)
        #expect(MaintainManifestApplier.validationRejection(for: nodeRequest(key: "scope/pkg")) != nil)
        #expect(MaintainManifestApplier.validationRejection(for: nodeRequest(key: "pkg@1")) != nil)
    }

    @Test func acceptsOrdinarySemverRangesAsVersions() {
        for acceptableVersion in ["6", "6.1.1", "^3.23.8", "~1.2", "1.2.3-beta.4", "18.x", "*", "<2"] {
            #expect(
                MaintainManifestApplier.validationRejection(for: cargoRequest(value: acceptableVersion)) == nil,
                "\(acceptableVersion) should be an acceptable version requirement"
            )
        }
    }

    @Test func rejectsAnEntitlementOutsideTheAppleSecurityNamespace() {
        let outsideNamespace = MaintainManifestChangeRequest(
            kind: .addEntitlement,
            filePath: "app/app.entitlements",
            key: "com.apple.developer.team-identifier",
            value: "true",
            reason: "signing"
        )
        #expect(MaintainManifestApplier.validationRejection(for: outsideNamespace) != nil)

        let bareNamespace = MaintainManifestChangeRequest(
            kind: .addEntitlement,
            filePath: "app/app.entitlements",
            key: "com.apple.security.",
            value: "true",
            reason: "signing"
        )
        #expect(MaintainManifestApplier.validationRejection(for: bareNamespace) != nil)
    }

    @Test func rejectsAnEntitlementValueOtherThanTrue() {
        // The applier only ever writes <true/>; any other value would imply it
        // might one day write something else.
        let falseEntitlement = MaintainManifestChangeRequest(
            kind: .addEntitlement,
            filePath: "app/app.entitlements",
            key: "com.apple.security.app-sandbox",
            value: "false",
            reason: "the app cannot reach the network"
        )
        #expect(MaintainManifestApplier.validationRejection(for: falseEntitlement) != nil)
    }

    @Test func rejectsAnEmptyOrOverlongReason() {
        #expect(MaintainManifestApplier.validationRejection(for: cargoRequest(reason: "   ")) != nil)
        let overlongReason = String(repeating: "a", count: MaintainManifestApplier.maximumReasonCharacterCount + 1)
        #expect(MaintainManifestApplier.validationRejection(for: cargoRequest(reason: overlongReason))
            == .reasonIsTooLong(characterCount: MaintainManifestApplier.maximumReasonCharacterCount + 1))
        let longestAcceptableReason = String(repeating: "a", count: MaintainManifestApplier.maximumReasonCharacterCount)
        #expect(MaintainManifestApplier.validationRejection(for: cargoRequest(reason: longestAcceptableReason)) == nil)
    }

    @Test func rejectsAnXMLBreakoutInsideAnInfoPlistStringValue() {
        let breakoutValue = MaintainManifestChangeRequest(
            kind: .addInfoPlistKey,
            filePath: "src-tauri/Info.plist",
            key: "NSMicrophoneUsageDescription",
            value: "Record.</string><key>LSEnvironment</key><string>x",
            reason: "the feature records audio"
        )
        #expect(MaintainManifestApplier.validationRejection(for: breakoutValue) != nil)
    }

    // MARK: - Cargo.toml

    private static let cargoManifestWithDependencies = """
    [package]
    name = "whimprflow"
    version = "0.1.0"
    build = "build.rs"

    [build-dependencies]
    tauri-build = { version = "2", features = [] }

    [dependencies]
    tauri = { version = "2", features = ["macos-private-api"] }
    serde_json = "1"

    [dev-dependencies]
    notify = "5"

    """

    @Test func insertsACrateAsTheLastLineOfTheExistingDependenciesTable() throws {
        let updatedText = try appliedText(cargoRequest(), Self.cargoManifestWithDependencies)
        #expect(updatedText == """
        [package]
        name = "whimprflow"
        version = "0.1.0"
        build = "build.rs"

        [build-dependencies]
        tauri-build = { version = "2", features = [] }

        [dependencies]
        tauri = { version = "2", features = ["macos-private-api"] }
        serde_json = "1"
        notify = "6.1.1"

        [dev-dependencies]
        notify = "5"

        """)
    }

    @Test func leavesBuildDependenciesAndThePackageBuildKeyByteForByte() throws {
        let updatedText = try appliedText(cargoRequest(), Self.cargoManifestWithDependencies)
        // The only difference anywhere in the file is the one inserted line.
        let originalLines = Self.cargoManifestWithDependencies.components(separatedBy: "\n")
        let updatedLines = updatedText.components(separatedBy: "\n")
        #expect(updatedLines.count == originalLines.count + 1)
        #expect(updatedLines.filter { $0 == "notify = \"6.1.1\"" }.count == 1)
        #expect(updatedLines.filter { $0 != "notify = \"6.1.1\"" } == originalLines)
        #expect(updatedText.contains("build = \"build.rs\""))
        #expect(updatedText.contains("[build-dependencies]\ntauri-build = { version = \"2\", features = [] }"))
    }

    @Test func createsADependenciesTableWhenTheManifestHasNone() throws {
        let manifestWithoutDependencies = """
        [package]
        name = "tool"
        version = "0.1.0"
        """
        let updatedText = try appliedText(cargoRequest(), manifestWithoutDependencies)
        #expect(updatedText == """
        [package]
        name = "tool"
        version = "0.1.0"

        [dependencies]
        notify = "6.1.1"

        """)
    }

    @Test func refusesACrateThatIsAlreadyDeclared() {
        let alreadyDeclared = """
        [dependencies]
        notify = "5"
        """
        #expect(applyFailure(cargoRequest(), alreadyDeclared) == .dependencyAlreadyDeclared(name: "notify"))

        let declaredAsAWorkspaceInheritance = """
        [dependencies]
        notify.workspace = true
        """
        #expect(applyFailure(cargoRequest(), declaredAsAWorkspaceInheritance)
            == .dependencyAlreadyDeclared(name: "notify"))

        let declaredAsASubTable = """
        [dependencies]
        serde = "1"

        [dependencies.notify]
        version = "5"
        """
        #expect(applyFailure(cargoRequest(), declaredAsASubTable) == .dependencyAlreadyDeclared(name: "notify"))

        let declaredWithAQuotedKey = """
        [dependencies]
        "notify" = "5"
        """
        #expect(applyFailure(cargoRequest(), declaredWithAQuotedKey) == .dependencyAlreadyDeclared(name: "notify"))
    }

    @Test func doesNotMistakeACommentOrAPrefixMatchForADeclaration() throws {
        let manifestWithNearMisses = """
        [dependencies]
        # notify = "5"
        notify-debouncer-full = "0.3"
        """
        let updatedText = try appliedText(cargoRequest(), manifestWithNearMisses)
        #expect(updatedText == """
        [dependencies]
        # notify = "5"
        notify-debouncer-full = "0.3"
        notify = "6.1.1"
        """)
    }

    @Test func doesNotMistakeAQuotedArrayElementForADeclaration() throws {
        // A crate name that happens to appear as a quoted feature on its own
        // line inside a wrapped inline table is not a declaration of it.
        let manifestWithAWrappedInlineTable = """
        [dependencies]
        tauri = { version = "2", features = [
          "notify",
          "macos-private-api"
        ] }
        """
        let updatedText = try appliedText(cargoRequest(), manifestWithAWrappedInlineTable)
        #expect(updatedText == """
        [dependencies]
        tauri = { version = "2", features = [
          "notify",
          "macos-private-api"
        ] }
        notify = "6.1.1"
        """)
    }

    @Test func treatsADependencyInAnotherTableAsUnrelated() throws {
        // A dev-dependency of the same name is a different table; adding the
        // real dependency is correct and must not be refused.
        let updatedText = try appliedText(cargoRequest(), Self.cargoManifestWithDependencies)
        #expect(updatedText.contains("[dev-dependencies]\nnotify = \"5\""))
    }

    // MARK: - package.json

    private static let packageJSONWithScripts = """
    {
      "name": "publikclip",
      "version": "0.2.3",
      "scripts": {
        "build": "vite build",
        "postinstall": "node ./scripts/setup.js"
      },
      "dependencies": {
        "react": "18.3.1",
        "vite": "5.4.0"
      },
      "devDependencies": {
        "typescript": "5.5.4"
      }
    }
    """

    @Test func insertsAPackageIntoDependenciesAndLeavesScriptsUntouched() throws {
        let updatedText = try appliedText(nodeRequest(), Self.packageJSONWithScripts)
        #expect(updatedText == """
        {
          "name": "publikclip",
          "version": "0.2.3",
          "scripts": {
            "build": "vite build",
            "postinstall": "node ./scripts/setup.js"
          },
          "dependencies": {
            "react": "18.3.1",
            "vite": "5.4.0",
            "zod": "^3.23.8"
          },
          "devDependencies": {
            "typescript": "5.5.4"
          }
        }
        """)
        // Said again as a property rather than a golden string: every
        // top-level field except "dependencies" survives identically.
        let originalObject = try #require(jsonObject(from: Self.packageJSONWithScripts))
        let updatedObject = try #require(jsonObject(from: updatedText))
        for (fieldName, originalValue) in originalObject where fieldName != "dependencies" {
            #expect(NSDictionary(dictionary: ["value": originalValue])
                .isEqual(NSDictionary(dictionary: ["value": updatedObject[fieldName] ?? NSNull()])),
                "\(fieldName) must be unchanged")
        }
    }

    @Test func createsADependenciesObjectWhenThePackageJSONHasNone() throws {
        let packageJSONWithoutDependencies = """
        {
          "name": "tool",
          "scripts": {
            "build": "tsc"
          }
        }
        """
        let updatedText = try appliedText(nodeRequest(), packageJSONWithoutDependencies)
        #expect(updatedText == """
        {
          "name": "tool",
          "scripts": {
            "build": "tsc"
          },
          "dependencies": {
            "zod": "^3.23.8"
          }
        }
        """)
    }

    @Test func insertsIntoAnInlineDependenciesObjectWithoutReflowingTheFile() throws {
        let inlinePackageJSON = #"{"name": "tool", "dependencies": {"react": "18"}}"#
        let updatedText = try appliedText(nodeRequest(), inlinePackageJSON)
        #expect(updatedText == #"{"name": "tool", "dependencies": {"react": "18", "zod": "^3.23.8"}}"#)

        let emptyDependenciesObject = #"{"name": "tool", "dependencies": {}}"#
        let updatedEmptyText = try appliedText(nodeRequest(), emptyDependenciesObject)
        #expect(updatedEmptyText == #"{"name": "tool", "dependencies": { "zod": "^3.23.8" }}"#)
    }

    @Test func refusesAPackageThatIsAlreadyADependency() {
        #expect(applyFailure(nodeRequest(key: "react", value: "18.3.1"), Self.packageJSONWithScripts)
            == .dependencyAlreadyDeclared(name: "react"))
    }

    @Test func treatsADevDependencyOfTheSameNameAsUnrelated() throws {
        // The declaration only ever writes "dependencies"; a devDependency of
        // the same name is a different field and must survive untouched.
        let updatedText = try appliedText(nodeRequest(key: "typescript", value: "5.5.4"), Self.packageJSONWithScripts)
        #expect(updatedText.contains("\"devDependencies\": {\n    \"typescript\": \"5.5.4\"\n  }"))
        let updatedObject = try #require(jsonObject(from: updatedText))
        let updatedDependencies = try #require(updatedObject["dependencies"] as? [String: Any])
        #expect(updatedDependencies["typescript"] as? String == "5.5.4")
    }

    @Test func refusesAPackageJSONThatIsNotValidJSON() {
        #expect(applyFailure(nodeRequest(), "{ not json ") == .manifestIsNotValidJSON)
    }

    @Test func refusesAPackageJSONWhoseDependenciesFieldIsNotAnObject() {
        #expect(applyFailure(nodeRequest(), #"{"name": "tool", "dependencies": "all of them"}"#)
            == .manifestDependenciesFieldIsNotAnObject)
    }

    // MARK: - Info.plist

    private static let infoPropertyList = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>CFBundleName</key>
    \t<string>Whimprflow</string>
    \t<key>LSUIElement</key>
    \t<true/>
    </dict>
    </plist>

    """

    private func infoPlistRequest(
        key: String = "NSMicrophoneUsageDescription",
        value: String = "Record a voice note."
    ) -> MaintainManifestChangeRequest {
        MaintainManifestChangeRequest(
            kind: .addInfoPlistKey,
            filePath: "src-tauri/Info.plist",
            key: key,
            value: value,
            reason: "the feature records audio"
        )
    }

    @Test func insertsAnInfoPlistKeyBeforeTheClosingDictionary() throws {
        let updatedText = try appliedText(infoPlistRequest(), Self.infoPropertyList)
        #expect(updatedText == """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>CFBundleName</key>
        \t<string>Whimprflow</string>
        \t<key>LSUIElement</key>
        \t<true/>
        \t<key>NSMicrophoneUsageDescription</key>
        \t<string>Record a voice note.</string>
        </dict>
        </plist>

        """)
    }

    @Test func refusesAnInfoPlistKeyThatIsAlreadyPresent() {
        #expect(applyFailure(infoPlistRequest(key: "LSUIElement", value: "yes"), Self.infoPropertyList)
            == .propertyListKeyAlreadyPresent(key: "LSUIElement"))
    }

    @Test func createsAMinimalPropertyListWhenTheFileTextIsEmpty() throws {
        // Tauri merges src-tauri/Info.plist automatically, and a project
        // frequently has none until a feature needs one.
        let updatedText = try appliedText(infoPlistRequest(), "")
        #expect(updatedText == """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>NSMicrophoneUsageDescription</key>
        \t<string>Record a voice note.</string>
        </dict>
        </plist>

        """)
    }

    @Test func refusesTextThatIsNotAnXMLPropertyList() {
        #expect(applyFailure(infoPlistRequest(), "{\"CFBundleName\": \"Whimprflow\"}")
            == .manifestIsNotAnXMLPropertyList)
    }

    // MARK: - Entitlements

    private static let entitlementsPropertyList = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>com.apple.security.app-sandbox</key>
    \t<true/>
    </dict>
    </plist>

    """

    private func entitlementRequest(
        key: String = "com.apple.security.device.audio-input"
    ) -> MaintainManifestChangeRequest {
        MaintainManifestChangeRequest(
            kind: .addEntitlement,
            filePath: "leanring-buddy/leanring-buddy.entitlements",
            key: key,
            value: "true",
            reason: "the sandbox blocks the microphone"
        )
    }

    @Test func grantsAnEntitlementAsATrueElementAndKeepsTheExistingOnes() throws {
        let updatedText = try appliedText(entitlementRequest(), Self.entitlementsPropertyList)
        #expect(updatedText == """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>com.apple.security.app-sandbox</key>
        \t<true/>
        \t<key>com.apple.security.device.audio-input</key>
        \t<true/>
        </dict>
        </plist>

        """)
    }

    @Test func refusesAnEntitlementThatIsAlreadyGranted() {
        #expect(applyFailure(entitlementRequest(key: "com.apple.security.app-sandbox"), Self.entitlementsPropertyList)
            == .propertyListKeyAlreadyPresent(key: "com.apple.security.app-sandbox"))
    }

    @Test func refusesAnEntitlementOutsideTheNamespaceEvenWhenAppliedDirectly() {
        // `apply` re-runs validation, so a request built in code — a replayed
        // recipe, a test — cannot skip the namespace rule by not being parsed.
        let outsideNamespace = MaintainManifestChangeRequest(
            kind: .addEntitlement,
            filePath: "app/app.entitlements",
            key: "com.example.anything",
            value: "true",
            reason: "because"
        )
        switch MaintainManifestApplier.apply(outsideNamespace, toManifestText: Self.entitlementsPropertyList) {
        case .success:
            Issue.record("an entitlement outside com.apple.security. must never be applied")
        case .failure(let applyError):
            #expect(applyError.readerFacingMessage.contains("com.apple.security"))
        }
    }

    // MARK: - applyToRepo

    private func makeTemporaryDirectory() throws -> URL {
        let temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("iris-manifest-applier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        return temporaryDirectoryURL
    }

    @Test func writesTheCrateIntoTheRealManifestOnDisk() throws {
        let repositoryRootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repositoryRootURL) }
        let cargoDirectoryURL = repositoryRootURL.appendingPathComponent("src-tauri", isDirectory: true)
        try FileManager.default.createDirectory(at: cargoDirectoryURL, withIntermediateDirectories: true)
        let cargoManifestURL = cargoDirectoryURL.appendingPathComponent("Cargo.toml")
        try Self.cargoManifestWithDependencies.write(to: cargoManifestURL, atomically: true, encoding: .utf8)

        let outcome = MaintainManifestApplier.applyToRepo(cargoRequest(), repoRootPath: repositoryRootURL.path)
        #expect(try outcome.get() == "Added the Rust crate notify 6.1.1 to src-tauri/Cargo.toml")
        let writtenText = try String(contentsOf: cargoManifestURL, encoding: .utf8)
        #expect(writtenText.contains("[dependencies]\ntauri = { version = \"2\", features = [\"macos-private-api\"] }\nserde_json = \"1\"\nnotify = \"6.1.1\"\n"))
    }

    @Test func createsAnAbsentInfoPlistButNeverAnAbsentCargoManifest() throws {
        let repositoryRootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repositoryRootURL) }
        let tauriDirectoryURL = repositoryRootURL.appendingPathComponent("src-tauri", isDirectory: true)
        try FileManager.default.createDirectory(at: tauriDirectoryURL, withIntermediateDirectories: true)

        let plistOutcome = MaintainManifestApplier.applyToRepo(
            infoPlistRequest(), repoRootPath: repositoryRootURL.path
        )
        #expect((try? plistOutcome.get()) == "Added the Info.plist key NSMicrophoneUsageDescription to src-tauri/Info.plist")
        let createdPropertyListText = try String(
            contentsOf: tauriDirectoryURL.appendingPathComponent("Info.plist"), encoding: .utf8
        )
        #expect(createdPropertyListText.contains("<key>NSMicrophoneUsageDescription</key>"))

        // A Cargo.toml that does not exist is a wrong declaration, not an
        // invitation to invent a crate manifest.
        let cargoOutcome = MaintainManifestApplier.applyToRepo(cargoRequest(), repoRootPath: repositoryRootURL.path)
        #expect(failure(of: cargoOutcome) == .manifestFileDoesNotExist(path: "src-tauri/Cargo.toml"))
    }

    @Test func refusesToWriteWhenTheParentDirectoryDoesNotExist() throws {
        let repositoryRootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repositoryRootURL) }
        let outcome = MaintainManifestApplier.applyToRepo(infoPlistRequest(), repoRootPath: repositoryRootURL.path)
        #expect(failure(of: outcome) == .parentDirectoryDoesNotExist(path: "src-tauri/Info.plist"))
    }

    @Test func refusesAPathThatTraversesOutOfTheRepository() throws {
        let repositoryRootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repositoryRootURL) }
        // Validation catches this before any file is touched — the traversal
        // never reaches the read/write step at all.
        let outcome = MaintainManifestApplier.applyToRepo(
            cargoRequest(filePath: "../Cargo.toml"), repoRootPath: repositoryRootURL.path
        )
        switch outcome {
        case .success:
            Issue.record("a traversing path must never be applied")
        case .failure(let applyError):
            #expect(applyError == .requestFailedValidation(
                explanation: MaintainManifestApplier.ParseRejection
                    .invalidFilePath(explanation: "it contains ..").modelFacingMessage
            ))
        }
    }

    @Test func refusesAManifestReachedThroughASymbolicLinkOutOfTheRepository() throws {
        // The model can create symlinks inside the jail. A directory symlink
        // that points out of the repo must not turn an in-repo-looking path
        // into a write anywhere on the machine.
        let repositoryRootURL = try makeTemporaryDirectory()
        let outsideDirectoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: repositoryRootURL)
            try? FileManager.default.removeItem(at: outsideDirectoryURL)
        }
        let outsideManifestURL = outsideDirectoryURL.appendingPathComponent("Cargo.toml")
        try "[dependencies]\n".write(to: outsideManifestURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: repositoryRootURL.appendingPathComponent("src-tauri"),
            withDestinationURL: outsideDirectoryURL
        )

        let outcome = MaintainManifestApplier.applyToRepo(cargoRequest(), repoRootPath: repositoryRootURL.path)
        #expect(failure(of: outcome) == .pathEscapesRepositoryRoot(path: "src-tauri/Cargo.toml"))
        // And the file outside the repository is untouched.
        #expect(try String(contentsOf: outsideManifestURL, encoding: .utf8) == "[dependencies]\n")
    }

    @Test func refusesAManifestThatIsItselfASymbolicLink() throws {
        let repositoryRootURL = try makeTemporaryDirectory()
        let outsideDirectoryURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: repositoryRootURL)
            try? FileManager.default.removeItem(at: outsideDirectoryURL)
        }
        let cargoDirectoryURL = repositoryRootURL.appendingPathComponent("src-tauri", isDirectory: true)
        try FileManager.default.createDirectory(at: cargoDirectoryURL, withIntermediateDirectories: true)
        let outsideManifestURL = outsideDirectoryURL.appendingPathComponent("Cargo.toml")
        try "[dependencies]\n".write(to: outsideManifestURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: cargoDirectoryURL.appendingPathComponent("Cargo.toml"),
            withDestinationURL: outsideManifestURL
        )

        let outcome = MaintainManifestApplier.applyToRepo(cargoRequest(), repoRootPath: repositoryRootURL.path)
        // Either rail may catch it first; both refuse, and nothing is written.
        #expect(outcome.isFailure)
        #expect(try String(contentsOf: outsideManifestURL, encoding: .utf8) == "[dependencies]\n")
    }

    @Test func leavesTheManifestUnchangedWhenTheChangeIsRefused() throws {
        let repositoryRootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repositoryRootURL) }
        let packageJSONURL = repositoryRootURL.appendingPathComponent("package.json")
        try Self.packageJSONWithScripts.write(to: packageJSONURL, atomically: true, encoding: .utf8)

        let outcome = MaintainManifestApplier.applyToRepo(
            nodeRequest(key: "react", value: "19"), repoRootPath: repositoryRootURL.path
        )
        #expect(failure(of: outcome) == .dependencyAlreadyDeclared(name: "react"))
        #expect(try String(contentsOf: packageJSONURL, encoding: .utf8) == Self.packageJSONWithScripts)
    }

    // MARK: - Summaries and the guard bridge

    @Test func summarizesEachKindForTheConsentCard() {
        #expect(MaintainManifestApplier.humanReadableSummary(cargoRequest())
            == "Add the Rust crate notify 6.1.1 to src-tauri/Cargo.toml — the fix has to watch a file")
        #expect(MaintainManifestApplier.humanReadableSummary(nodeRequest())
            == "Add the npm package zod ^3.23.8 to package.json — the settings form needs schema validation")
        #expect(MaintainManifestApplier.humanReadableSummary(entitlementRequest())
            == "Grant the entitlement com.apple.security.device.audio-input in leanring-buddy/leanring-buddy.entitlements — the sandbox blocks the microphone")
    }

    @Test func collapsesAMultiLineReasonIntoOneSentenceOnTheCard() {
        let wrappedReason = cargoRequest(reason: "the fix has to\n  watch a file\tfor changes")
        #expect(MaintainManifestApplier.humanReadableSummary(wrappedReason)
            == "Add the Rust crate notify 6.1.1 to src-tauri/Cargo.toml — the fix has to watch a file for changes")
    }

    @Test func exemptsOnlyTheExactConsentedManifestPathsFromTheBuildScriptGuard() {
        let changedPaths = [
            "src-tauri/Cargo.toml",
            "./package.json",
            "src-tauri/build.rs",
            "src/main.rs",
        ]
        let remainingPaths = MaintainManifestApplier.changedPathsExcludingConsentedManifestChanges(
            changedPaths,
            consentedManifestPaths: ["src-tauri/Cargo.toml", "package.json"]
        )
        #expect(remainingPaths == ["src-tauri/build.rs", "src/main.rs"])
        // The guard still sees the build script the model edited on its own.
        #expect(MaintainBuildScriptGuard.buildScriptFilePaths(inChangedPaths: remainingPaths)
            == ["src-tauri/build.rs"])
    }

    // MARK: - Small test helpers

    private func jsonObject(from text: String) -> [String: Any]? {
        guard let textData = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: textData)) as? [String: Any]
    }

    private func failure(of outcome: Result<String, MaintainManifestApplier.ApplyError>)
        -> MaintainManifestApplier.ApplyError? {
        switch outcome {
        case .success:
            return nil
        case .failure(let applyError):
            return applyError
        }
    }
}

private extension Result {
    var isFailure: Bool {
        switch self {
        case .success: return false
        case .failure: return true
        }
    }
}

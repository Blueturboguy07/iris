//
//  MaintainManifestApplier.swift
//  leanring-buddy
//
//  The one sanctioned way a dependency or a manifest key ever changes during
//  an Iris edit run — and the model never writes a character of it.
//
//  Why the model cannot be trusted with these files: verification (build +
//  test suite) runs OUTSIDE the Seatbelt jail, networked, because dependency
//  resolution needs the network. That is only safe because the model authors
//  SOURCE, never anything the build EXECUTES. `cargo build` runs `build.rs`
//  and honours `[build-dependencies]`; `npm run build` runs package.json
//  lifecycle scripts. So `MaintainBuildScriptGuard` bans model edits to those
//  files outright, and the Tier C loop restores any it catches.
//
//  That ban is correct and stays. But it left a real dead end: a run found the
//  right fix, needed one crate to express it, and had no legal way to say so —
//  it edited Cargo.toml and lost all 46 steps. This file is the escape valve
//  with the authorship split intact:
//
//      the model DECLARES  →  a person CONSENTS  →  IRIS's own code APPLIES
//
//  The declaration is a closed, typed value (four kinds, five string fields),
//  not a diff and not a command. Everything the applier can emit is an INERT
//  DATA LINE — `name = "1.2"`, `"name": "1.2"`, `<key>K</key><string>V</string>`,
//  `<key>com.apple.security.x</key><true/>`. There is no reachable path in this
//  file that writes a script, a hook, a `build = ` key, a `scripts` entry, a
//  `postinstall`, a `[build-dependencies]` line, or any key the caller did not
//  name — the validator rejects the characters that would be needed to express
//  one, each applier writes into exactly one hard-coded table/object, and every
//  applier finishes by re-parsing its own output and refusing the edit unless
//  the parsed manifest is byte-for-byte the original plus the single declared
//  entry. A model that smuggles `"; rm -rf /"` into a version string never gets
//  past validation; one that gets creative about WHERE the entry lands never
//  gets past the post-condition.
//
//  Everything here is pure text-in/text-out except `applyToRepo`, the thin
//  file-reading/atomic-writing wrapper, which additionally refuses any path
//  that resolves (symlinks included) outside the repository root.
//

import Foundation

// MARK: - The declaration

/// One manifest change the model has DECLARED and Iris may apply on its
/// behalf after an explicit, per-run consent. Deliberately a closed value type
/// rather than a patch: the model chooses a kind, a file, a key, a value and a
/// justification — it never chooses the surrounding text, the table, or the
/// insertion point, so there is nothing to smuggle a script into.
nonisolated struct MaintainManifestChangeRequest: Codable, Equatable, Sendable {

    /// The complete set of manifest changes Iris will make on a model's
    /// behalf. Adding a case here is a security decision — each one is a new
    /// kind of line written into a file the un-jailed build reads — so the
    /// list stays short and every case writes an inert declaration only.
    nonisolated enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        /// A crate under Cargo.toml's plain `[dependencies]` table. Never
        /// `[build-dependencies]` (build-time code execution) and never
        /// `[package] build = …` (names a build script).
        case addCargoDependency

        /// A package under package.json's top-level `"dependencies"` object.
        /// Never `"scripts"`, never `"devDependencies"`.
        case addNodeDependency

        /// A `<key>`/`<string>` pair in an XML Info.plist — the usage-string
        /// and capability declarations a feature needs at runtime. Tauri v2
        /// has no `infoPlist` config key; it merges `src-tauri/Info.plist`
        /// automatically, so a Tauri app's request names THAT file and the
        /// applier creates it when it is absent. One mechanism, XML plists.
        case addInfoPlistKey

        /// A `<key>`/`<true/>` pair in an XML `.entitlements` plist, limited
        /// to the `com.apple.security.` namespace (sandbox / hardened runtime).
        case addEntitlement
    }

    /// Which of the four sanctioned changes this is.
    let kind: Kind

    /// Repo-relative path of the manifest to change, e.g. `src-tauri/Cargo.toml`.
    /// Validated against the kind (a Cargo declaration may only name a
    /// Cargo.toml) and against path traversal before anything reads it.
    let filePath: String

    /// The crate / package / plist key being declared.
    let key: String

    /// The version requirement (Cargo, npm), the string value (Info.plist), or
    /// empty / "true" (entitlement, which is always written as `<true/>`).
    let value: String

    /// One short sentence of justification, shown verbatim on the consent card
    /// so the person approving knows WHY. Display-only: it is never written
    /// into a manifest, which is what lets it hold free text safely.
    let reason: String
}

// MARK: - The applier

nonisolated enum MaintainManifestApplier {

    // MARK: Rejections

    /// Why a model's manifest block was not accepted. Every case carries text
    /// aimed at the MODEL, because the useful thing to do with a rejection is
    /// tell the model exactly what to fix rather than silently drop its turn.
    nonisolated enum ParseRejection: Error, Equatable, Sendable {
        case noManifestBlockInReply
        case moreThanOneManifestBlockInReply
        case manifestBlockIsNotAJSONObject
        case manifestBlockHasUnexpectedFields(fieldNames: [String])
        case manifestBlockIsMissingField(fieldName: String)
        case manifestBlockFieldIsNotAString(fieldName: String)
        case unknownKind(rawValue: String)
        case invalidFilePath(explanation: String)
        case invalidKey(explanation: String)
        case invalidValue(explanation: String)
        case reasonIsEmpty
        case reasonIsTooLong(characterCount: Int)

        var modelFacingMessage: String {
            switch self {
            case .noManifestBlockInReply:
                return "no ```manifest block found in the reply"
            case .moreThanOneManifestBlockInReply:
                return "a reply may declare at most ONE manifest change; found several"
            case .manifestBlockIsNotAJSONObject:
                return "the manifest block must contain a single JSON object"
            case .manifestBlockHasUnexpectedFields(let fieldNames):
                return "the manifest block carries fields that do not exist: \(fieldNames.joined(separator: ", ")). Only kind, filePath, key, value and reason are allowed."
            case .manifestBlockIsMissingField(let fieldName):
                return "the manifest block is missing the required field \(fieldName)"
            case .manifestBlockFieldIsNotAString(let fieldName):
                return "the manifest field \(fieldName) must be a JSON string"
            case .unknownKind(let rawValue):
                return "\(rawValue) is not a manifest change Iris can make. Use one of: \(MaintainManifestChangeRequest.Kind.allCases.map(\.rawValue).joined(separator: ", "))."
            case .invalidFilePath(let explanation):
                return "the manifest filePath is not usable: \(explanation)"
            case .invalidKey(let explanation):
                return "the manifest key is not usable: \(explanation)"
            case .invalidValue(let explanation):
                return "the manifest value is not usable: \(explanation)"
            case .reasonIsEmpty:
                return "the manifest reason must say, in one sentence, why the change is needed"
            case .reasonIsTooLong(let characterCount):
                return "the manifest reason is \(characterCount) characters; keep it under \(maximumReasonCharacterCount)"
            }
        }
    }

    /// Why an accepted declaration could not be applied. These are reader
    /// facing: they surface on the consent card / run log after a person has
    /// already said yes, so they explain the manifest's state, not the model's.
    nonisolated enum ApplyError: Error, Equatable, Sendable {
        case requestFailedValidation(explanation: String)
        case dependencyAlreadyDeclared(name: String)
        case propertyListKeyAlreadyPresent(key: String)
        case manifestIsNotValidJSON
        case manifestDependenciesFieldIsNotAnObject
        case manifestIsNotAnXMLPropertyList
        case manifestHasNoClosingDictionaryTag
        case editWouldChangeUnrelatedContent
        case manifestFileDoesNotExist(path: String)
        case manifestFileCouldNotBeRead(path: String)
        case manifestFileCouldNotBeWritten(path: String)
        case parentDirectoryDoesNotExist(path: String)
        case pathEscapesRepositoryRoot(path: String)
        case pathIsASymbolicLink(path: String)

        var readerFacingMessage: String {
            switch self {
            case .requestFailedValidation(let explanation):
                return "Iris refused the declared change: \(explanation)."
            case .dependencyAlreadyDeclared(let name):
                return "\(name) is already a dependency of this project."
            case .propertyListKeyAlreadyPresent(let key):
                return "\(key) is already set in that file."
            case .manifestIsNotValidJSON:
                return "That manifest is not valid JSON, so Iris will not edit it."
            case .manifestDependenciesFieldIsNotAnObject:
                return "That package.json's \"dependencies\" field is not an object."
            case .manifestIsNotAnXMLPropertyList:
                return "That file is not an XML property list, so Iris will not edit it."
            case .manifestHasNoClosingDictionaryTag:
                return "That property list has no closing </dict>, so Iris will not edit it."
            case .editWouldChangeUnrelatedContent:
                return "The edit would have changed more than the one declared entry, so Iris backed out."
            case .manifestFileDoesNotExist(let path):
                return "There is no \(path) in this project."
            case .manifestFileCouldNotBeRead(let path):
                return "Iris could not read \(path)."
            case .manifestFileCouldNotBeWritten(let path):
                return "Iris could not write \(path)."
            case .parentDirectoryDoesNotExist(let path):
                return "The folder that would hold \(path) does not exist."
            case .pathEscapesRepositoryRoot(let path):
                return "\(path) resolves outside the project folder."
            case .pathIsASymbolicLink(let path):
                return "\(path) is a symbolic link; Iris only writes real files inside the project."
            }
        }
    }

    // MARK: Limits

    /// A justification longer than this is prose, not a reason, and it has to
    /// fit on a consent card the person actually reads.
    static let maximumReasonCharacterCount = 300

    /// Long enough for any real crate/package name or plist key, short enough
    /// that a pathological name cannot bloat a manifest line.
    static let maximumKeyCharacterCount = 128

    /// Long enough for a semver range or a usage-description sentence.
    static let maximumValueCharacterCount = 200

    /// Repo-relative manifest paths are shallow in every real project.
    static let maximumFilePathCharacterCount = 256

    // MARK: - Parsing a declaration out of a model reply

    /// The declaration the model writes, byte for byte:
    ///
    ///     ```manifest
    ///     {"kind": "...", "filePath": "...", "key": "...", "value": "...", "reason": "..."}
    ///     ```
    ///
    /// Returns nil for anything that is not exactly one well-formed, fully
    /// valid declaration — the caller treats nil as "this reply declared
    /// nothing" and carries on with its normal handling.
    static func parse(fromModelReply reply: String) -> MaintainManifestChangeRequest? {
        switch parseDetailed(fromModelReply: reply) {
        case .success(let request):
            return request
        case .failure:
            return nil
        }
    }

    /// The same parse, keeping the reason for a refusal. The Tier C loop uses
    /// this one so a model that emits a nearly-right block is told what to fix
    /// instead of being ignored (an ignored declaration reliably becomes an
    /// illegal hand edit two steps later).
    static func parseDetailed(
        fromModelReply reply: String
    ) -> Result<MaintainManifestChangeRequest, ParseRejection> {
        let manifestBlocks = manifestBlockBodies(inModelReply: reply)
        guard !manifestBlocks.isEmpty else { return .failure(.noManifestBlockInReply) }
        guard manifestBlocks.count == 1 else { return .failure(.moreThanOneManifestBlockInReply) }

        guard let blockData = manifestBlocks[0].data(using: .utf8),
              let decodedObject = (try? JSONSerialization.jsonObject(with: blockData)) as? [String: Any] else {
            return .failure(.manifestBlockIsNotAJSONObject)
        }

        // Strict field set. An extra field is not ignored, it is a refusal:
        // the interesting extra fields a model might try ("scripts",
        // "devDependencies", "build") are exactly the ones that must never
        // reach a manifest, and silently dropping them would teach it that
        // asking costs nothing.
        let allowedFieldNames: Set<String> = ["kind", "filePath", "key", "value", "reason"]
        let unexpectedFieldNames = decodedObject.keys.filter { !allowedFieldNames.contains($0) }.sorted()
        guard unexpectedFieldNames.isEmpty else {
            return .failure(.manifestBlockHasUnexpectedFields(fieldNames: unexpectedFieldNames))
        }

        var fieldValues: [String: String] = [:]
        for fieldName in allowedFieldNames.sorted() {
            guard let rawFieldValue = decodedObject[fieldName] else {
                return .failure(.manifestBlockIsMissingField(fieldName: fieldName))
            }
            guard let stringFieldValue = rawFieldValue as? String else {
                return .failure(.manifestBlockFieldIsNotAString(fieldName: fieldName))
            }
            fieldValues[fieldName] = stringFieldValue
        }

        guard let kind = MaintainManifestChangeRequest.Kind(rawValue: fieldValues["kind"] ?? "") else {
            return .failure(.unknownKind(rawValue: fieldValues["kind"] ?? ""))
        }

        let request = MaintainManifestChangeRequest(
            kind: kind,
            filePath: fieldValues["filePath"] ?? "",
            key: fieldValues["key"] ?? "",
            value: fieldValues["value"] ?? "",
            reason: fieldValues["reason"] ?? ""
        )
        if let rejection = validationRejection(for: request) {
            return .failure(rejection)
        }
        return .success(request)
    }

    /// Every fenced ```manifest block body in a reply, in order. Fences are
    /// matched on whole trimmed lines so a mention of the word inside prose
    /// cannot open one, and an unterminated block is not a declaration at all.
    private static func manifestBlockBodies(inModelReply reply: String) -> [String] {
        let normalizedReply = reply.replacingOccurrences(of: "\r\n", with: "\n")
        var blockBodies: [String] = []
        var currentBlockLines: [String] = []
        var isInsideManifestBlock = false

        for line in normalizedReply.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if isInsideManifestBlock {
                if trimmedLine == "```" {
                    blockBodies.append(currentBlockLines.joined(separator: "\n"))
                    currentBlockLines = []
                    isInsideManifestBlock = false
                } else {
                    currentBlockLines.append(String(line))
                }
            } else if trimmedLine == "```manifest" {
                isInsideManifestBlock = true
            }
        }
        return blockBodies
    }

    // MARK: - Validation

    /// Everything a declaration must satisfy before Iris will even show it on
    /// a consent card. Runs on the parse path AND again inside `apply`, so a
    /// request built in code (a replayed pool recipe, a test) cannot skip it.
    /// Returns nil when the request is acceptable.
    static func validationRejection(for request: MaintainManifestChangeRequest) -> ParseRejection? {
        if let filePathRejection = filePathRejection(for: request) { return filePathRejection }
        if let keyRejection = keyRejection(for: request) { return keyRejection }
        if let valueRejection = valueRejection(for: request) { return valueRejection }

        let trimmedReason = request.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedReason.isEmpty { return .reasonIsEmpty }
        if request.reason.count > maximumReasonCharacterCount {
            return .reasonIsTooLong(characterCount: request.reason.count)
        }
        return nil
    }

    private static func filePathRejection(
        for request: MaintainManifestChangeRequest
    ) -> ParseRejection? {
        let filePath = request.filePath
        if filePath.isEmpty { return .invalidFilePath(explanation: "it is empty") }
        if filePath.count > maximumFilePathCharacterCount {
            return .invalidFilePath(explanation: "it is longer than \(maximumFilePathCharacterCount) characters")
        }
        if filePath.hasPrefix("/") {
            return .invalidFilePath(explanation: "it must be relative to the project folder, not absolute")
        }
        if filePath.hasPrefix("~") {
            return .invalidFilePath(explanation: "it must be relative to the project folder")
        }
        if filePath.contains("..") {
            return .invalidFilePath(explanation: "it contains ..")
        }
        let filePathContainsAControlCharacter = filePath.unicodeScalars.contains { unicodeScalar in
            unicodeScalar.value < 0x20 || unicodeScalar.value == 0x7F
        }
        if filePathContainsAControlCharacter {
            return .invalidFilePath(explanation: "it contains a control character")
        }
        if filePath.contains("\\") {
            return .invalidFilePath(explanation: "it contains a backslash")
        }
        // Every component must be an ordinary visible name. Refusing any
        // component that starts with a dot rules out `..`, `./`, `.git/…` and
        // `.github/workflows/…` in one rule — none of which is ever a manifest.
        let pathComponents = filePath.split(separator: "/", omittingEmptySubsequences: false)
        for pathComponent in pathComponents {
            if pathComponent.isEmpty {
                return .invalidFilePath(explanation: "it has an empty path component")
            }
            if pathComponent.hasPrefix(".") {
                return .invalidFilePath(explanation: "no path component may start with a dot")
            }
        }

        let fileName = String(pathComponents[pathComponents.count - 1])
        switch request.kind {
        case .addCargoDependency:
            if fileName != "Cargo.toml" {
                return .invalidFilePath(explanation: "a Cargo dependency can only be added to a file named Cargo.toml")
            }
        case .addNodeDependency:
            if fileName != "package.json" {
                return .invalidFilePath(explanation: "an npm dependency can only be added to a file named package.json")
            }
        case .addInfoPlistKey:
            // One mechanism only: XML property lists. Tauri v2 has no
            // `infoPlist` config key — it merges `src-tauri/Info.plist` into
            // the bundle automatically — so a Tauri request names that file
            // and never tauri.conf.json, which carries bundle/build settings
            // Iris will not touch on a model's say-so.
            if !fileName.hasSuffix(".plist") {
                return .invalidFilePath(explanation: "an Info.plist key can only be added to a .plist file (for a Tauri app that is src-tauri/Info.plist, which Tauri merges automatically)")
            }
        case .addEntitlement:
            if !fileName.hasSuffix(".entitlements") {
                return .invalidFilePath(explanation: "an entitlement can only be added to a .entitlements file")
            }
        }
        return nil
    }

    private static func keyRejection(
        for request: MaintainManifestChangeRequest
    ) -> ParseRejection? {
        let key = request.key
        if key.isEmpty { return .invalidKey(explanation: "it is empty") }
        if key.count > maximumKeyCharacterCount {
            return .invalidKey(explanation: "it is longer than \(maximumKeyCharacterCount) characters")
        }

        switch request.kind {
        case .addCargoDependency:
            // TOML bare-key safe on purpose: `@` and `/` would need quoting
            // and a `.` would turn the line into a dotted key that creates a
            // SUB-TABLE rather than a dependency. Crates.io names are
            // [A-Za-z0-9_-] anyway, so nothing real is lost.
            guard containsOnlyCharacters(inSet: cargoCrateNameAllowedCharacters, key),
                  let firstCharacter = key.unicodeScalars.first,
                  asciiLetterAndDigitCharacters.contains(firstCharacter) else {
                return .invalidKey(explanation: "a crate name may contain only letters, digits, underscores and hyphens, and must start with a letter or digit")
            }
            // Defence in depth: these are not crate names anyone needs, and
            // they are the words a smuggler would reach for inside a manifest.
            if ["build", "package", "workspace"].contains(key) {
                return .invalidKey(explanation: "\(key) is a reserved manifest word, not a crate Iris will add")
            }
        case .addNodeDependency:
            guard containsOnlyCharacters(inSet: nodePackageNameAllowedCharacters, key) else {
                return .invalidKey(explanation: "an npm package name may contain only letters, digits and _ . @ / -")
            }
            if key.hasPrefix("@") {
                let scopedNameParts = key.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
                guard scopedNameParts.count == 2,
                      !scopedNameParts[0].isEmpty,
                      !scopedNameParts[1].isEmpty,
                      !key.dropFirst().contains("@") else {
                    return .invalidKey(explanation: "a scoped npm package must look like @scope/name")
                }
            } else if key.contains("@") || key.contains("/") {
                return .invalidKey(explanation: "only a scoped package may contain @ or /")
            }
        case .addInfoPlistKey:
            guard containsOnlyCharacters(inSet: propertyListKeyAllowedCharacters, key) else {
                return .invalidKey(explanation: "a property-list key may contain only letters, digits and _ . -")
            }
        case .addEntitlement:
            guard containsOnlyCharacters(inSet: propertyListKeyAllowedCharacters, key) else {
                return .invalidKey(explanation: "an entitlement key may contain only letters, digits and _ . -")
            }
            // The sandbox / hardened-runtime namespace and nothing else. An
            // entitlement outside it (a private Apple one, a team-prefixed
            // one) is not something Iris grants on a model's request.
            guard key.hasPrefix("com.apple.security."), key.count > "com.apple.security.".count else {
                return .invalidKey(explanation: "Iris only adds entitlements in the com.apple.security. namespace")
            }
        }
        return nil
    }

    private static func valueRejection(
        for request: MaintainManifestChangeRequest
    ) -> ParseRejection? {
        let value = request.value
        if value.count > maximumValueCharacterCount {
            return .invalidValue(explanation: "it is longer than \(maximumValueCharacterCount) characters")
        }

        switch request.kind {
        case .addCargoDependency, .addNodeDependency:
            if value.isEmpty {
                return .invalidValue(explanation: "a dependency needs a version requirement")
            }
            // The banned characters are precisely the ones that would let a
            // version string stop being a version: a quote or `=` breaks out
            // of the TOML/JSON string, `[`/`]` opens a table, `{`/`}` an
            // inline table, `#` a comment, and a newline starts a new key.
            guard containsOnlyCharacters(inSet: versionRequirementAllowedCharacters, value) else {
                return .invalidValue(explanation: "a version requirement may contain only letters, digits and . _ - + * ^ ~ < >")
            }
        case .addInfoPlistKey:
            if value.isEmpty {
                return .invalidValue(explanation: "an Info.plist string value must not be empty")
            }
            guard containsOnlyPrintableASCIIWithoutXMLHazards(value) else {
                return .invalidValue(explanation: "a property-list string value must be printable ASCII without < > & or \"")
            }
        case .addEntitlement:
            // The applier always writes <true/>; accepting any other value
            // would imply Iris might write something else one day.
            if !(value.isEmpty || value == "true") {
                return .invalidValue(explanation: "an entitlement is always granted as true; leave value empty or set it to true")
            }
        }
        return nil
    }

    // MARK: Character sets

    private static let asciiLetterCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let asciiDigitCharacters = "0123456789"

    private static let asciiLetterAndDigitCharacters =
        CharacterSet(charactersIn: asciiLetterCharacters + asciiDigitCharacters)

    private static let cargoCrateNameAllowedCharacters =
        CharacterSet(charactersIn: asciiLetterCharacters + asciiDigitCharacters + "_-")

    private static let nodePackageNameAllowedCharacters =
        CharacterSet(charactersIn: asciiLetterCharacters + asciiDigitCharacters + "_.@/-")

    private static let versionRequirementAllowedCharacters =
        CharacterSet(charactersIn: asciiLetterCharacters + asciiDigitCharacters + "._-+*^~<>")

    private static let propertyListKeyAllowedCharacters =
        CharacterSet(charactersIn: asciiLetterCharacters + asciiDigitCharacters + "._-")

    private static func containsOnlyCharacters(inSet allowedCharacters: CharacterSet, _ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    /// Printable ASCII with the four characters that would end the XML text
    /// node (or the attribute it might one day sit in) removed. Escaping them
    /// instead would work, but refusing them keeps the written line provably
    /// identical to the declared value.
    private static func containsOnlyPrintableASCIIWithoutXMLHazards(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { unicodeScalar in
            guard unicodeScalar.value >= 0x20, unicodeScalar.value < 0x7F else { return false }
            return unicodeScalar != "<" && unicodeScalar != ">" && unicodeScalar != "&" && unicodeScalar != "\""
        }
    }

    // MARK: - Pure appliers

    /// Apply a declaration to the TEXT of its manifest. Pure: no file system,
    /// no network, no model. Returns the complete new file text.
    static func apply(
        _ request: MaintainManifestChangeRequest,
        toManifestText manifestText: String
    ) -> Result<String, ApplyError> {
        if let rejection = validationRejection(for: request) {
            return .failure(.requestFailedValidation(explanation: rejection.modelFacingMessage))
        }
        switch request.kind {
        case .addCargoDependency:
            return applyCargoDependency(
                crateName: request.key,
                versionRequirement: request.value,
                toCargoTomlText: manifestText
            )
        case .addNodeDependency:
            return applyNodeDependency(
                packageName: request.key,
                versionRequirement: request.value,
                toPackageJSONText: manifestText
            )
        case .addInfoPlistKey:
            return applyPropertyListKey(
                keyName: request.key,
                valueElementXML: "<string>\(request.value)</string>",
                expectedParsedValue: request.value,
                toPropertyListText: manifestText
            )
        case .addEntitlement:
            return applyPropertyListKey(
                keyName: request.key,
                valueElementXML: "<true/>",
                expectedParsedValue: true,
                toPropertyListText: manifestText
            )
        }
    }

    // MARK: Cargo.toml

    /// Inserts `name = "version"` as the last entry of the plain
    /// `[dependencies]` table, creating that table at the end of the file when
    /// it is absent. Every other byte of the file is preserved: the applier
    /// works line-by-line and rewrites nothing it did not insert, so
    /// `[build-dependencies]`, `[package]`, a `build = "build.rs"` key and any
    /// `[target.…]` table are untouched by construction — they are simply
    /// never the table this function writes into.
    private static func applyCargoDependency(
        crateName: String,
        versionRequirement: String,
        toCargoTomlText cargoTomlText: String
    ) -> Result<String, ApplyError> {
        var manifestLines = cargoTomlText.components(separatedBy: "\n")

        // A `[dependencies.<crate>]` sub-table declares the same dependency in
        // long form; adding a second declaration would be a TOML conflict.
        let subTableHeader = "[dependencies.\(crateName)]"
        if manifestLines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == subTableHeader }) {
            return .failure(.dependencyAlreadyDeclared(name: crateName))
        }

        // The plain `[dependencies]` header and nothing that merely looks like
        // it: `[build-dependencies]`, `[dev-dependencies]` and
        // `[target.'cfg(unix)'.dependencies]` are different tables and are not
        // matched by this equality.
        let dependenciesTableHeaderLineIndex = manifestLines.firstIndex {
            $0.trimmingCharacters(in: .whitespaces) == "[dependencies]"
        }

        guard let headerLineIndex = dependenciesTableHeaderLineIndex else {
            var updatedText = cargoTomlText
            if !updatedText.isEmpty && !updatedText.hasSuffix("\n") { updatedText += "\n" }
            if !updatedText.isEmpty { updatedText += "\n" }
            updatedText += "[dependencies]\n\(crateName) = \"\(versionRequirement)\"\n"
            return .success(updatedText)
        }

        // The table body runs from the line after its header to the line
        // before the next table header (or the end of the file).
        var tableBodyEndIndexExclusive = manifestLines.count
        var lineIndex = headerLineIndex + 1
        while lineIndex < manifestLines.count {
            if manifestLines[lineIndex].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                tableBodyEndIndexExclusive = lineIndex
                break
            }
            lineIndex += 1
        }

        var lastNonBlankBodyLineIndex: Int? = nil
        for bodyLineIndex in (headerLineIndex + 1)..<tableBodyEndIndexExclusive {
            let bodyLine = manifestLines[bodyLineIndex]
            if tomlLineDeclaresKey(bodyLine, keyName: crateName) {
                return .failure(.dependencyAlreadyDeclared(name: crateName))
            }
            if !bodyLine.trimmingCharacters(in: .whitespaces).isEmpty {
                lastNonBlankBodyLineIndex = bodyLineIndex
            }
        }

        // Append as the last line of the table — after the final real entry,
        // never after the blank lines that separate this table from the next.
        let insertionLineIndex = (lastNonBlankBodyLineIndex ?? headerLineIndex) + 1
        let insertedLineIndentation = lastNonBlankBodyLineIndex.map {
            leadingWhitespace(of: manifestLines[$0])
        } ?? ""
        manifestLines.insert(
            "\(insertedLineIndentation)\(crateName) = \"\(versionRequirement)\"",
            at: insertionLineIndex
        )
        return .success(manifestLines.joined(separator: "\n"))
    }

    /// True when one TOML line declares `keyName` — bare, quoted, or as the
    /// head of a dotted key such as `serde.workspace = true`.
    private static func tomlLineDeclaresKey(_ line: String, keyName: String) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        if trimmedLine.hasPrefix("#") { return false }

        for quoteCharacter in ["\"", "'"] where trimmedLine.hasPrefix(quoteCharacter) {
            let afterOpeningQuote = trimmedLine.dropFirst()
            guard let closingQuoteIndex = afterOpeningQuote.firstIndex(of: Character(quoteCharacter)) else {
                return false
            }
            guard String(afterOpeningQuote[afterOpeningQuote.startIndex..<closingQuoteIndex]) == keyName else {
                return false
            }
            // A quoted key is only a declaration when an `=` (or a dotted key
            // path) follows it. Without this check a crate name quoted inside
            // a wrapped inline table — a `features = [\n  "notify"\n]` array
            // element on its own line — would read as a declaration and the
            // real dependency could never be added.
            let remainderAfterQuotedKey = afterOpeningQuote[afterOpeningQuote.index(after: closingQuoteIndex)...]
                .trimmingCharacters(in: .whitespaces)
            return remainderAfterQuotedKey.hasPrefix("=") || remainderAfterQuotedKey.hasPrefix(".")
        }

        guard trimmedLine.hasPrefix(keyName) else { return false }
        let remainderAfterKey = trimmedLine
            .dropFirst(keyName.count)
            .trimmingCharacters(in: .whitespaces)
        return remainderAfterKey.hasPrefix("=") || remainderAfterKey.hasPrefix(".")
    }

    private static func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    // MARK: package.json

    /// Inserts `"name": "version"` into the top-level `"dependencies"` object,
    /// creating that object as the last top-level key when it is absent.
    ///
    /// This is a MINIMAL TEXTUAL insertion rather than a decode/re-encode on
    /// purpose. Re-serialising through JSONSerialization would reorder keys
    /// and reformat the whole file, turning a one-line dependency addition
    /// into a whole-file diff — on the exact file that is under the most
    /// suspicion, and that a person is about to review on a consent card. The
    /// text is parsed first (so a broken package.json is refused), the
    /// insertion point is found with a small brace/string-aware scanner, and
    /// the RESULT is parsed again and compared field-by-field against the
    /// original: anything but "identical plus one dependency" is backed out.
    /// That post-condition is what proves `"scripts"` was not touched.
    private static func applyNodeDependency(
        packageName: String,
        versionRequirement: String,
        toPackageJSONText packageJSONText: String
    ) -> Result<String, ApplyError> {
        guard let originalData = packageJSONText.data(using: .utf8),
              let originalObject = (try? JSONSerialization.jsonObject(with: originalData)) as? [String: Any] else {
            return .failure(.manifestIsNotValidJSON)
        }

        var originalDependencies: [String: Any] = [:]
        if let existingDependenciesValue = originalObject["dependencies"] {
            guard let existingDependencies = existingDependenciesValue as? [String: Any] else {
                return .failure(.manifestDependenciesFieldIsNotAnObject)
            }
            if existingDependencies[packageName] != nil {
                return .failure(.dependencyAlreadyDeclared(name: packageName))
            }
            originalDependencies = existingDependencies
        }

        guard let rootObjectLayout = layoutOfRootJSONObject(in: packageJSONText) else {
            return .failure(.manifestIsNotValidJSON)
        }

        let dependencyEntryText = "\"\(packageName)\": \"\(versionRequirement)\""
        var updatedText: String

        if let dependenciesEntry = rootObjectLayout.entries.first(where: { $0.keyName == "dependencies" }) {
            guard packageJSONText[dependenciesEntry.valueStartIndex] == "{" else {
                return .failure(.manifestDependenciesFieldIsNotAnObject)
            }
            let dependenciesCloseBraceIndex = packageJSONText.index(before: dependenciesEntry.valueEndIndexExclusive)
            updatedText = insertingEntry(
                dependencyEntryText,
                intoJSONObjectWithOpenBrace: dependenciesEntry.valueStartIndex,
                closeBrace: dependenciesCloseBraceIndex,
                in: packageJSONText
            )
        } else {
            let rootIsWrittenOnOneLine = !packageJSONText[
                packageJSONText.index(after: rootObjectLayout.openBraceIndex)..<rootObjectLayout.closeBraceIndex
            ].contains("\n")
            let lastTopLevelEntryIndentation = rootObjectLayout.entries.last.map {
                lineIndentation(ofLineContaining: $0.valueStartIndex, in: packageJSONText)
            } ?? defaultIndentationUnit
            let dependenciesObjectText: String
            if rootIsWrittenOnOneLine {
                dependenciesObjectText = "\"dependencies\": {\(dependencyEntryText)}"
            } else {
                dependenciesObjectText = """
                "dependencies": {
                \(lastTopLevelEntryIndentation)\(defaultIndentationUnit)\(dependencyEntryText)
                \(lastTopLevelEntryIndentation)}
                """
            }
            updatedText = insertingEntry(
                dependenciesObjectText,
                intoJSONObjectWithOpenBrace: rootObjectLayout.openBraceIndex,
                closeBrace: rootObjectLayout.closeBraceIndex,
                in: packageJSONText
            )
        }

        // Post-condition: the file now parses, and differs from the original
        // by exactly the one dependency. Anything else — a mangled scripts
        // block, a duplicated key, a lost field — fails here and the caller
        // keeps the original file.
        var expectedDependencies = originalDependencies
        expectedDependencies[packageName] = versionRequirement
        var expectedObject = originalObject
        expectedObject["dependencies"] = expectedDependencies
        guard let updatedData = updatedText.data(using: .utf8),
              let updatedObject = (try? JSONSerialization.jsonObject(with: updatedData)) as? [String: Any],
              NSDictionary(dictionary: updatedObject).isEqual(NSDictionary(dictionary: expectedObject)) else {
            return .failure(.editWouldChangeUnrelatedContent)
        }
        return .success(updatedText)
    }

    private static let defaultIndentationUnit = "  "

    /// Inserts one entry as the last member of a JSON object, matching how the
    /// object is already written (inline objects stay inline; multi-line
    /// objects get a new line indented like their existing members).
    private static func insertingEntry(
        _ entryText: String,
        intoJSONObjectWithOpenBrace openBraceIndex: String.Index,
        closeBrace closeBraceIndex: String.Index,
        in text: String
    ) -> String {
        let interiorRange = text.index(after: openBraceIndex)..<closeBraceIndex
        let objectIsWrittenOnOneLine = !text[interiorRange].contains("\n")
        var updatedText = text

        if let lastNonWhitespaceIndex = lastNonWhitespaceIndex(in: text, within: interiorRange) {
            let insertionIndex = text.index(after: lastNonWhitespaceIndex)
            let insertedText: String
            if objectIsWrittenOnOneLine {
                insertedText = ", \(entryText)"
            } else {
                let existingEntryIndentation = lineIndentation(ofLineContaining: lastNonWhitespaceIndex, in: text)
                insertedText = ",\n\(existingEntryIndentation)\(entryText)"
            }
            updatedText.replaceSubrange(insertionIndex..<insertionIndex, with: insertedText)
            return updatedText
        }

        // The object is empty.
        if objectIsWrittenOnOneLine {
            updatedText.replaceSubrange(interiorRange, with: " \(entryText) ")
            return updatedText
        }
        let closingBraceIndentation = lineIndentation(ofLineContaining: closeBraceIndex, in: text)
        updatedText.replaceSubrange(
            interiorRange,
            with: "\n\(closingBraceIndentation)\(defaultIndentationUnit)\(entryText)\n\(closingBraceIndentation)"
        )
        return updatedText
    }

    // MARK: JSON layout scanner

    private struct JSONTopLevelEntryLayout {
        let keyName: String
        let valueStartIndex: String.Index
        let valueEndIndexExclusive: String.Index
    }

    private struct JSONObjectLayout {
        let openBraceIndex: String.Index
        let closeBraceIndex: String.Index
        let entries: [JSONTopLevelEntryLayout]
    }

    /// Where the root object's braces and each of its top-level keys sit in the
    /// raw text. String-literal aware, so a `{` inside a script string cannot
    /// throw the depth off. Only ever called on text JSONSerialization has
    /// already accepted, so it can be strict and bail on anything unexpected.
    private static func layoutOfRootJSONObject(in text: String) -> JSONObjectLayout? {
        var currentIndex = indexAfterWhitespace(from: text.startIndex, in: text)
        guard currentIndex < text.endIndex, text[currentIndex] == "{" else { return nil }
        let openBraceIndex = currentIndex
        currentIndex = text.index(after: currentIndex)

        var entries: [JSONTopLevelEntryLayout] = []
        while true {
            currentIndex = indexAfterWhitespace(from: currentIndex, in: text)
            guard currentIndex < text.endIndex else { return nil }
            if text[currentIndex] == "}" {
                return JSONObjectLayout(
                    openBraceIndex: openBraceIndex,
                    closeBraceIndex: currentIndex,
                    entries: entries
                )
            }
            guard text[currentIndex] == "\"",
                  let scannedKey = scanJSONStringLiteral(startingAtOpeningQuote: currentIndex, in: text) else {
                return nil
            }
            currentIndex = indexAfterWhitespace(from: scannedKey.indexAfterClosingQuote, in: text)
            guard currentIndex < text.endIndex, text[currentIndex] == ":" else { return nil }
            currentIndex = indexAfterWhitespace(from: text.index(after: currentIndex), in: text)
            let valueStartIndex = currentIndex
            guard let valueEndIndexExclusive = indexAfterJSONValue(startingAt: currentIndex, in: text) else {
                return nil
            }
            entries.append(JSONTopLevelEntryLayout(
                keyName: scannedKey.contents,
                valueStartIndex: valueStartIndex,
                valueEndIndexExclusive: valueEndIndexExclusive
            ))
            currentIndex = indexAfterWhitespace(from: valueEndIndexExclusive, in: text)
            guard currentIndex < text.endIndex else { return nil }
            if text[currentIndex] == "," {
                currentIndex = text.index(after: currentIndex)
                continue
            }
            if text[currentIndex] == "}" {
                return JSONObjectLayout(
                    openBraceIndex: openBraceIndex,
                    closeBraceIndex: currentIndex,
                    entries: entries
                )
            }
            return nil
        }
    }

    private static func scanJSONStringLiteral(
        startingAtOpeningQuote openingQuoteIndex: String.Index,
        in text: String
    ) -> (contents: String, indexAfterClosingQuote: String.Index)? {
        guard openingQuoteIndex < text.endIndex, text[openingQuoteIndex] == "\"" else { return nil }
        var currentIndex = text.index(after: openingQuoteIndex)
        var contents = ""
        while currentIndex < text.endIndex {
            let character = text[currentIndex]
            if character == "\\" {
                let escapedCharacterIndex = text.index(after: currentIndex)
                guard escapedCharacterIndex < text.endIndex else { return nil }
                contents.append(character)
                contents.append(text[escapedCharacterIndex])
                currentIndex = text.index(after: escapedCharacterIndex)
                continue
            }
            if character == "\"" {
                return (contents, text.index(after: currentIndex))
            }
            contents.append(character)
            currentIndex = text.index(after: currentIndex)
        }
        return nil
    }

    private static func indexAfterJSONValue(startingAt startIndex: String.Index, in text: String) -> String.Index? {
        guard startIndex < text.endIndex else { return nil }
        let firstCharacter = text[startIndex]
        if firstCharacter == "\"" {
            return scanJSONStringLiteral(startingAtOpeningQuote: startIndex, in: text)?.indexAfterClosingQuote
        }
        if firstCharacter == "{" || firstCharacter == "[" {
            var containerDepth = 0
            var currentIndex = startIndex
            while currentIndex < text.endIndex {
                let character = text[currentIndex]
                if character == "\"" {
                    guard let scannedString = scanJSONStringLiteral(startingAtOpeningQuote: currentIndex, in: text) else {
                        return nil
                    }
                    currentIndex = scannedString.indexAfterClosingQuote
                    continue
                }
                if character == "{" || character == "[" { containerDepth += 1 }
                if character == "}" || character == "]" {
                    containerDepth -= 1
                    if containerDepth == 0 { return text.index(after: currentIndex) }
                }
                currentIndex = text.index(after: currentIndex)
            }
            return nil
        }
        // A number, true, false or null: it ends at the next structural
        // character or whitespace.
        var currentIndex = startIndex
        while currentIndex < text.endIndex {
            let character = text[currentIndex]
            if character == "," || character == "}" || character == "]" || character.isWhitespace {
                return currentIndex
            }
            currentIndex = text.index(after: currentIndex)
        }
        return nil
    }

    private static func indexAfterWhitespace(from startIndex: String.Index, in text: String) -> String.Index {
        var currentIndex = startIndex
        while currentIndex < text.endIndex, text[currentIndex].isWhitespace {
            currentIndex = text.index(after: currentIndex)
        }
        return currentIndex
    }

    private static func lastNonWhitespaceIndex(in text: String, within range: Range<String.Index>) -> String.Index? {
        var currentIndex = range.upperBound
        while currentIndex > range.lowerBound {
            let previousIndex = text.index(before: currentIndex)
            if !text[previousIndex].isWhitespace { return previousIndex }
            currentIndex = previousIndex
        }
        return nil
    }

    private static func lineIndentation(ofLineContaining index: String.Index, in text: String) -> String {
        var lineStartIndex = index
        while lineStartIndex > text.startIndex {
            let previousIndex = text.index(before: lineStartIndex)
            if text[previousIndex] == "\n" { break }
            lineStartIndex = previousIndex
        }
        var indentation = ""
        var currentIndex = lineStartIndex
        while currentIndex < text.endIndex, text[currentIndex] == " " || text[currentIndex] == "\t" {
            indentation.append(text[currentIndex])
            currentIndex = text.index(after: currentIndex)
        }
        return indentation
    }

    // MARK: XML property lists

    /// The skeleton an absent Info.plist / entitlements file starts from. Only
    /// ever used when the target file does not exist at all.
    static let minimalPropertyListSkeleton = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    </dict>
    </plist>

    """

    /// Inserts `<key>K</key>` + the given value element immediately before the
    /// top-level dict's closing `</dict>` — the last `</dict>` in a well-formed
    /// plist, since every nested dict closes before it.
    private static func applyPropertyListKey(
        keyName: String,
        valueElementXML: String,
        expectedParsedValue: Any,
        toPropertyListText propertyListText: String
    ) -> Result<String, ApplyError> {
        let textToEdit = propertyListText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? minimalPropertyListSkeleton
            : propertyListText

        guard let originalObject = parsedXMLPropertyListDictionary(from: textToEdit) else {
            return .failure(.manifestIsNotAnXMLPropertyList)
        }

        // Refuse if the key exists ANYWHERE in the file, nested dicts included:
        // a duplicate deeper in the tree means the model's mental model of the
        // file is wrong, and quietly adding a second one is the worse outcome.
        let escapedKeyName = NSRegularExpression.escapedPattern(for: keyName)
        if let duplicateKeyExpression = try? NSRegularExpression(pattern: "<key>\\s*\(escapedKeyName)\\s*</key>"),
           duplicateKeyExpression.firstMatch(
               in: textToEdit,
               range: NSRange(textToEdit.startIndex..., in: textToEdit)
           ) != nil {
            return .failure(.propertyListKeyAlreadyPresent(key: keyName))
        }

        guard let closingDictionaryTagRange = textToEdit.range(of: "</dict>", options: .backwards) else {
            return .failure(.manifestHasNoClosingDictionaryTag)
        }
        let closingTagIndentation = lineIndentation(
            ofLineContaining: closingDictionaryTagRange.lowerBound,
            in: textToEdit
        )
        let insertedChildIndentation = closingTagIndentation + "\t"
        let insertionIndex = indexOfLineStart(containing: closingDictionaryTagRange.lowerBound, in: textToEdit)

        var updatedText = textToEdit
        updatedText.replaceSubrange(
            insertionIndex..<insertionIndex,
            with: "\(insertedChildIndentation)<key>\(keyName)</key>\n\(insertedChildIndentation)\(valueElementXML)\n"
        )

        // Post-condition: the result still parses as an XML plist and is the
        // original dictionary plus exactly the one declared key.
        var expectedObject = originalObject
        expectedObject[keyName] = expectedParsedValue
        guard let updatedObject = parsedXMLPropertyListDictionary(from: updatedText),
              NSDictionary(dictionary: updatedObject).isEqual(NSDictionary(dictionary: expectedObject)) else {
            return .failure(.editWouldChangeUnrelatedContent)
        }
        return .success(updatedText)
    }

    /// Parses text as an XML property list whose root is a dictionary. The
    /// format check is deliberate: a binary plist must never be text-edited,
    /// and the OpenStep format would let a non-plist file slip through.
    private static func parsedXMLPropertyListDictionary(from text: String) -> [String: Any]? {
        guard let textData = text.data(using: .utf8) else { return nil }
        var detectedFormat = PropertyListSerialization.PropertyListFormat.xml
        guard let parsedPropertyList = try? PropertyListSerialization.propertyList(
            from: textData,
            options: [],
            format: &detectedFormat
        ) else { return nil }
        guard detectedFormat == .xml else { return nil }
        return parsedPropertyList as? [String: Any]
    }

    private static func indexOfLineStart(containing index: String.Index, in text: String) -> String.Index {
        var lineStartIndex = index
        while lineStartIndex > text.startIndex {
            let previousIndex = text.index(before: lineStartIndex)
            if text[previousIndex] == "\n" { break }
            lineStartIndex = previousIndex
        }
        return lineStartIndex
    }

    // MARK: - The file-applying wrapper

    /// Reads the declared manifest out of the repository, applies the change,
    /// and writes it back atomically. The only impure entry point, and the
    /// only place a manifest is ever written.
    ///
    /// Path safety, in order: the request is re-validated (so `..`, absolute
    /// paths and dot components are already gone), the path is standardised
    /// AND symlink-resolved and must still sit under the repository root (a
    /// model can create symlinks inside the jail, so a `src-tauri` symlinked
    /// out of the repo has to fail here), and the target itself must not be a
    /// symlink. Only the two property-list kinds may create a missing file,
    /// and never a missing directory.
    ///
    /// On success, returns the one-line past-tense summary for the run log.
    static func applyToRepo(
        _ request: MaintainManifestChangeRequest,
        repoRootPath: String
    ) -> Result<String, ApplyError> {
        if let rejection = validationRejection(for: request) {
            return .failure(.requestFailedValidation(explanation: rejection.modelFacingMessage))
        }

        let repositoryRootURL = URL(fileURLWithPath: repoRootPath, isDirectory: true).standardizedFileURL
        let manifestFileURL = repositoryRootURL.appendingPathComponent(request.filePath).standardizedFileURL
        let repositoryRootPathWithSeparator = repositoryRootURL.path.hasSuffix("/")
            ? repositoryRootURL.path
            : repositoryRootURL.path + "/"
        guard manifestFileURL.path.hasPrefix(repositoryRootPathWithSeparator) else {
            return .failure(.pathEscapesRepositoryRoot(path: request.filePath))
        }

        let symlinkResolvedRootPath = repositoryRootURL.resolvingSymlinksInPath().path
        let symlinkResolvedRootPathWithSeparator = symlinkResolvedRootPath.hasSuffix("/")
            ? symlinkResolvedRootPath
            : symlinkResolvedRootPath + "/"
        let symlinkResolvedManifestPath = manifestFileURL.resolvingSymlinksInPath().path
        guard symlinkResolvedManifestPath.hasPrefix(symlinkResolvedRootPathWithSeparator) else {
            return .failure(.pathEscapesRepositoryRoot(path: request.filePath))
        }

        let fileManager = FileManager.default
        let manifestFileExists = fileManager.fileExists(atPath: manifestFileURL.path)
        if manifestFileExists {
            let fileAttributes = try? fileManager.attributesOfItem(atPath: manifestFileURL.path)
            if fileAttributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                return .failure(.pathIsASymbolicLink(path: request.filePath))
            }
        }

        var parentDirectoryIsADirectory: ObjCBool = false
        let parentDirectoryPath = manifestFileURL.deletingLastPathComponent().path
        guard fileManager.fileExists(atPath: parentDirectoryPath, isDirectory: &parentDirectoryIsADirectory),
              parentDirectoryIsADirectory.boolValue else {
            return .failure(.parentDirectoryDoesNotExist(path: request.filePath))
        }

        let manifestText: String
        if manifestFileExists {
            guard let existingText = try? String(contentsOf: manifestFileURL, encoding: .utf8) else {
                return .failure(.manifestFileCouldNotBeRead(path: request.filePath))
            }
            manifestText = existingText
        } else {
            switch request.kind {
            case .addInfoPlistKey, .addEntitlement:
                // The only creation Iris performs: a Tauri app frequently has
                // no src-tauri/Info.plist until something needs one.
                manifestText = ""
            case .addCargoDependency, .addNodeDependency:
                return .failure(.manifestFileDoesNotExist(path: request.filePath))
            }
        }

        switch apply(request, toManifestText: manifestText) {
        case .failure(let applyError):
            return .failure(applyError)
        case .success(let updatedManifestText):
            do {
                try updatedManifestText.write(to: manifestFileURL, atomically: true, encoding: .utf8)
            } catch {
                return .failure(.manifestFileCouldNotBeWritten(path: request.filePath))
            }
            return .success(appliedSummaryLine(request))
        }
    }

    // MARK: - Summaries

    /// The one sentence the consent card shows before anything is written.
    /// Imperative and specific, because this is the whole basis on which a
    /// person says yes: what is being added, where, and why.
    static func humanReadableSummary(_ request: MaintainManifestChangeRequest) -> String {
        let collapsedReason = request.reason
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return "\(imperativeChangeDescription(request)) — \(collapsedReason)"
    }

    /// The past-tense line the run log records once the change is applied.
    /// Carries no reason: by then the reason is already in the transcript.
    static func appliedSummaryLine(_ request: MaintainManifestChangeRequest) -> String {
        switch request.kind {
        case .addCargoDependency:
            return "Added the Rust crate \(request.key) \(request.value) to \(request.filePath)"
        case .addNodeDependency:
            return "Added the npm package \(request.key) \(request.value) to \(request.filePath)"
        case .addInfoPlistKey:
            return "Added the Info.plist key \(request.key) to \(request.filePath)"
        case .addEntitlement:
            return "Added the entitlement \(request.key) to \(request.filePath)"
        }
    }

    private static func imperativeChangeDescription(_ request: MaintainManifestChangeRequest) -> String {
        switch request.kind {
        case .addCargoDependency:
            return "Add the Rust crate \(request.key) \(request.value) to \(request.filePath)"
        case .addNodeDependency:
            return "Add the npm package \(request.key) \(request.value) to \(request.filePath)"
        case .addInfoPlistKey:
            return "Add the Info.plist key \(request.key) (\(request.value)) to \(request.filePath)"
        case .addEntitlement:
            return "Grant the entitlement \(request.key) in \(request.filePath)"
        }
    }

    // MARK: - Keeping the build-script guard honest

    /// Removes the manifests Iris itself wrote — after consent — from a list
    /// of changed paths, so `MaintainBuildScriptGuard` still sees every model
    /// edit and none of Iris's own. Without this the guard would discard the
    /// whole run for the very Cargo.toml line the person just approved.
    ///
    /// `consentedManifestPaths` holds the repo-relative paths of applied
    /// declarations. Only an EXACT match is exempt: a model edit to any other
    /// build-script file still trips the guard, and a later model edit to the
    /// same file is invisible here by design — the caller must re-check the
    /// applied file's content, which is why the applier returns a summary the
    /// run log can diff against.
    static func changedPathsExcludingConsentedManifestChanges(
        _ changedPaths: [String],
        consentedManifestPaths: Set<String>
    ) -> [String] {
        changedPaths.filter { changedPath in
            let normalizedPath = changedPath.hasPrefix("./")
                ? String(changedPath.dropFirst(2))
                : changedPath
            return !consentedManifestPaths.contains(normalizedPath)
        }
    }

    // MARK: - What the model is told

    /// Appended to the on-demand system prompt next to the build-script ban.
    /// The ban alone produces a model that quietly gives up (or edits the file
    /// anyway and loses the run); the ban plus this escape valve produces one
    /// that asks. It states the shape exactly, and states plainly that Iris —
    /// not the model — makes the change, after asking the person.
    static let modelFacingProtocolPromptAddendum = """
    THE ONE EXCEPTION: if the change genuinely cannot be made with what the \
    repo already has, do not edit the build file — DECLARE the change and let \
    Iris make it. Emit exactly one block, alone in the reply, with no bash \
    block and no DONE:

    ```manifest
    {"kind": "addCargoDependency", "filePath": "src-tauri/Cargo.toml", "key": "notify", "value": "6", "reason": "the fix has to watch a file for changes and the repo has no watcher"}
    ```

    All five fields are required and must be JSON strings; no other field is \
    allowed. Valid kinds: addCargoDependency (a crate in Cargo.toml's \
    [dependencies]), addNodeDependency (a package in package.json's \
    "dependencies"), addInfoPlistKey (a key and string value in a .plist — for \
    a Tauri app that is src-tauri/Info.plist, which Tauri merges into the \
    bundle automatically), addEntitlement (a com.apple.security.* key in a \
    .entitlements file). Iris asks the person for permission, makes the edit \
    itself, and tells you the result — you never write these files, and you \
    never declare a script, a lifecycle hook, or a build-dependency.
    """
}

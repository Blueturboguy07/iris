//
//  IrisLocalSigningIdentity.swift
//  leanring-buddy
//
//  Why this file exists: TCC (Screen Recording, Accessibility, camera, mic,
//  Files-and-Folders) grants are keyed to an app's CODE SIGNATURE, not to its
//  bundle id or its path. The on-demand edit tool's Option-A relaunch packages a
//  fresh `.app` straight out of the reader's own source clone, and a packaging
//  build with no signing identity produces an AD-HOC signature ("-") that is a
//  different signature every single time. macOS therefore treats every rebuild
//  as a brand new app and drops every permission the reader already granted —
//  the exact churn `scripts/deploy-iris-local.sh` was written to avoid for Iris
//  itself. That script is the proven recipe and this file is its in-app twin:
//  find (or, with consent, create) ONE identity that stays the same across
//  rebuilds, then sign the packaged bundle inside-out with it.
//
//  Two other consequences of ad-hoc signing motivated this file:
//    • A packaging-metadata edit (an Info.plist key, an entitlement) verifies as
//      a NO-OP, because the verification build is a compile check and never
//      looks at the packaged bundle. `verifyPackagedMetadata` is the check that
//      actually reads the artifact, so "I added the camera entitlement" can be
//      contradicted by evidence instead of believed.
//    • Nothing ever recorded what the resulting signature actually IS.
//      `designatedRequirement(ofBundleAtPath:)` reads it back for the log.
//
//  Every process here is launched argv-array style through `Process` with an
//  absolute executable path. There is no shell anywhere in this file, so no
//  identity name, keychain path, or bundle path is ever parsed as a command —
//  and the generated certificate's passphrase never reaches a command line that
//  another user's `ps` could read it from... with one honest exception noted at
//  `createPersistentLocalCodeSigningCertificate`.
//
//  Honest limits (see also the report in AGENTS.md):
//    • Signing runs UN-JAILED, exactly like the packaging build it follows. It
//      is code-authored (no model input reaches an argument) and it only ever
//      touches the bundle the packaging step just produced.
//    • `--timestamp=none` is deliberate: a secure timestamp requires a network
//      round-trip to Apple, and this step must work offline and never hang.
//    • After creating a local certificate, the FIRST `codesign` that uses it may
//      raise the system "codesign wants to use a key in your keychain" prompt
//      once. Silencing that needs `security set-key-partition-list`, which needs
//      the login keychain PASSWORD — Iris does not have it and will not ask for
//      it, so the one-time prompt stands.
//

import Foundation

/// A code-signing identity that stays the SAME across rebuilds, which is the
/// whole point: a stable signature is what lets macOS carry the reader's already
/// granted permissions over to the freshly built copy of their app.
enum StableSigningIdentity: Sendable, Equatable {
    /// A real Apple-issued "Developer ID Application: …" identity already in the
    /// reader's keychain. Always preferred — it is what a shipped app is signed
    /// with, so a build signed with it is closest to the installed one.
    case developerID(name: String)
    /// The self-signed certificate Iris created (with consent) for this Mac.
    /// Not trusted by Gatekeeper for distribution, but perfectly stable, which
    /// is the only property TCC cares about for a locally built app.
    case irisLocalCertificate(name: String)

    /// The exact string handed to `codesign --sign`. `codesign` matches an
    /// identity by (a prefix of) its common name, which is what both cases hold.
    var codesignIdentityName: String {
        switch self {
        case .developerID(let name): return name
        case .irisLocalCertificate(let name): return name
        }
    }

    /// True only for an Apple-issued Developer ID. Used for user-facing copy —
    /// a locally created certificate is stable but is NOT a notarizable identity
    /// and must never be described as one.
    var isAppleIssuedDeveloperID: Bool {
        switch self {
        case .developerID: return true
        case .irisLocalCertificate: return false
        }
    }
}

/// The outcome of signing a packaged bundle. A failure is never fatal to
/// packaging — the caller keeps the ad-hoc artifact and says so honestly.
enum SigningOutcome: Sendable, Equatable {
    case signed
    case failed(reason: String)
}

/// What the packaged artifact must actually contain for a packaging-metadata
/// edit to count as real. Both lists are code- or caller-authored; the model
/// never writes one.
struct PackagingExpectations: Sendable, Equatable {
    /// Top-level `Info.plist` keys that must exist in the packaged bundle (for
    /// example `NSCameraUsageDescription` after an edit that added camera use).
    /// Checked with `plutil -extract <key> raw`, which treats a dot as a keypath
    /// separator — so these must be TOP-LEVEL keys, not nested keypaths.
    let infoPlistKeysThatMustExist: [String]
    /// Entitlement keys that must be present AND set to `<true/>` in the signed
    /// bundle's entitlements.
    let entitlementKeysThatMustBeTrue: [String]

    init(infoPlistKeysThatMustExist: [String] = [], entitlementKeysThatMustBeTrue: [String] = []) {
        self.infoPlistKeysThatMustExist = infoPlistKeysThatMustExist
        self.entitlementKeysThatMustBeTrue = entitlementKeysThatMustBeTrue
    }

    /// Nothing to check. `verifyPackagedMetadata` short-circuits on this rather
    /// than spawning processes to prove an empty claim.
    var isEmpty: Bool {
        infoPlistKeysThatMustExist.isEmpty && entitlementKeysThatMustBeTrue.isEmpty
    }
}

/// What one argv-invoked tool run produced. File-scope (not nested inside the
/// `@MainActor` enum) so it stays non-isolated and `Sendable`, which is what
/// lets the blocking runner hand it back across the detached-task boundary.
private struct IrisSigningToolInvocationResult: Sendable {
    let exitStatus: Int32
    let standardOutputText: String
    let standardErrorText: String

    var succeeded: Bool { exitStatus == 0 }

    /// The shortest honest thing to show a human about a failed run: the tail of
    /// stderr (where every tool here puts its complaint), falling back to stdout.
    var shortFailureDescription: String {
        let complaint = standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? standardOutputText
            : standardErrorText
        let trimmed = complaint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "no output" : String(trimmed.suffix(300))
    }

    static func launchFailure(executablePath: String) -> IrisSigningToolInvocationResult {
        IrisSigningToolInvocationResult(
            exitStatus: -1,
            standardOutputText: "",
            standardErrorText: "couldn't run \(executablePath)"
        )
    }
}

/// Somewhere for the two pipe-reading queues to put what they read. A reference
/// type on purpose: each field is written by exactly one queue and read only
/// after `DispatchGroup.wait()` has ordered both writes before it. That ordering
/// argument is the safety argument, and it is one the compiler cannot check —
/// hence `@unchecked Sendable` rather than actor isolation, which would stop the
/// two queues from writing at all.
private nonisolated final class IrisSigningCollectedToolOutput: @unchecked Sendable {
    var standardOutput = Data()
    var standardError = Data()
}

@MainActor
enum IrisLocalSigningIdentity {

    // MARK: - Constants

    /// The common name of the certificate Iris creates for this Mac. Also the
    /// name it looks for on every later run, which is what makes the identity
    /// persistent instead of one-shot.
    static let irisLocalCertificateCommonName = "Iris Local Code Signing"

    /// The prefix Apple gives every Developer ID application-signing identity.
    static let developerIDIdentityNamePrefix = "Developer ID Application:"

    private static let codesignToolPath = "/usr/bin/codesign"
    private static let securityToolPath = "/usr/bin/security"
    private static let plutilToolPath = "/usr/bin/plutil"

    /// Candidate `openssl` binaries, most capable first. Homebrew's OpenSSL 3 is
    /// tried before the system LibreSSL because `req -addext` (how the
    /// codeSigning EKU gets into the certificate) is better supported there; the
    /// system binary is the always-present fallback, and a certificate that
    /// comes out without the EKU is rejected rather than used.
    private static let opensslToolPathCandidates = [
        "/opt/homebrew/bin/openssl",
        "/usr/local/bin/openssl",
        "/usr/bin/openssl",
    ]

    /// Signing a large Electron bundle walks hundreds of nested items, so the
    /// per-invocation ceiling is generous; the short one covers the keychain and
    /// metadata queries, which answer in milliseconds when they answer at all.
    private static let signingToolTimeoutSeconds: TimeInterval = 300
    private static let quickToolTimeoutSeconds: TimeInterval = 60

    // MARK: - Resolving a stable identity

    /// Find an identity whose signature will be identical on the next rebuild,
    /// creating one only if the reader says yes.
    ///
    /// Order, best first:
    ///   1. An Apple-issued `Developer ID Application: …` already in the keychain.
    ///   2. A previously created `Iris Local Code Signing` certificate.
    ///   3. Ask, and on a yes create #2 and use it.
    ///
    /// Returns nil when there is nothing to use and nothing was consented to —
    /// the caller then keeps the ad-hoc artifact and must say so honestly rather
    /// than pretend permissions will survive.
    static func resolveStableIdentity(
        requestConsentToCreateLocalCertificate: @MainActor () async -> Bool
    ) async -> StableSigningIdentity? {
        if let identityAlreadyInKeychain = await findStableIdentityInKeychain() {
            return identityAlreadyInKeychain
        }

        let readerConsentedToCertificateCreation = await requestConsentToCreateLocalCertificate()
        guard readerConsentedToCertificateCreation else { return nil }

        guard await createPersistentLocalCodeSigningCertificate() else { return nil }

        // Re-ask the keychain rather than assuming: writing certificate files is
        // not the same as the keychain reporting a usable codesigning identity,
        // and signing with an identity `codesign` cannot resolve would fail later
        // and more confusingly.
        return await findStableIdentityInKeychain()
    }

    /// The best stable identity already present in the keychain, or nil.
    static func findStableIdentityInKeychain() async -> StableSigningIdentity? {
        let identityListing = await runTool(
            executablePath: securityToolPath,
            arguments: ["find-identity", "-v", "-p", "codesigning"],
            timeoutSeconds: quickToolTimeoutSeconds
        )
        let listingText = identityListing.standardOutputText.isEmpty
            ? identityListing.standardErrorText
            : identityListing.standardOutputText
        return preferredStableIdentity(inFindIdentityOutput: listingText)
    }

    /// Pure: pick the identity Iris should sign with out of the text
    /// `security find-identity -v -p codesigning` prints. A Developer ID always
    /// wins; the Iris local certificate is the fallback; anything else (Apple
    /// Development, third-party installer identities) is deliberately ignored,
    /// because those are not what a locally rebuilt app should claim to be.
    static func preferredStableIdentity(inFindIdentityOutput findIdentityOutput: String) -> StableSigningIdentity? {
        let identityNames = codesigningIdentityNames(inFindIdentityOutput: findIdentityOutput)

        if let developerIDName = identityNames.first(where: { $0.hasPrefix(developerIDIdentityNamePrefix) }) {
            return .developerID(name: developerIDName)
        }
        if let irisLocalName = identityNames.first(where: { $0.hasPrefix(irisLocalCertificateCommonName) }) {
            return .irisLocalCertificate(name: irisLocalName)
        }
        return nil
    }

    /// Pure: every quoted identity name in `security find-identity` output, in
    /// the order the tool listed them. Each identity line looks like
    /// `  1) A1B2…40 hex chars… "Developer ID Application: Someone (TEAMID)"`,
    /// and the trailing `N valid identities found` summary carries no quotes, so
    /// requiring both a leading index and a quoted span is enough to tell them
    /// apart without a regex.
    static func codesigningIdentityNames(inFindIdentityOutput findIdentityOutput: String) -> [String] {
        var collectedIdentityNames: [String] = []
        for rawLine in findIdentityOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let firstCharacter = line.first, firstCharacter.isNumber, line.contains(")") else { continue }
            guard let openingQuoteIndex = line.firstIndex(of: "\""),
                  let closingQuoteIndex = line.lastIndex(of: "\""),
                  openingQuoteIndex < closingQuoteIndex else { continue }
            let identityName = String(line[line.index(after: openingQuoteIndex)..<closingQuoteIndex])
            guard !identityName.isEmpty else { continue }
            collectedIdentityNames.append(identityName)
        }
        return collectedIdentityNames
    }

    // MARK: - Creating the persistent local certificate

    /// Create a self-signed code-signing certificate named
    /// `Iris Local Code Signing` and import it into the login keychain so it is
    /// there for every future rebuild. Returns whether the import reported
    /// success; the caller still re-queries the keychain before trusting it.
    ///
    /// The one honest exposure: `security import -P <passphrase>` puts a
    /// throwaway passphrase on a command line. It protects a PKCS#12 file that
    /// exists for milliseconds in a 0700 temp directory and is deleted
    /// immediately, and it is freshly random per run, so its only value to an
    /// observer is the file that is already gone.
    private static func createPersistentLocalCodeSigningCertificate() async -> Bool {
        let fileManager = FileManager.default
        let workingDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("iris-local-signing-\(UUID().uuidString)", isDirectory: true)
        guard (try? fileManager.createDirectory(
            at: workingDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )) != nil else { return false }
        // The private key, the certificate and the PKCS#12 bundle are all
        // transient — the keychain is the only place any of them should persist.
        defer { try? fileManager.removeItem(at: workingDirectoryURL) }

        let privateKeyURL = workingDirectoryURL.appendingPathComponent("private-key.pem")
        let certificateURL = workingDirectoryURL.appendingPathComponent("certificate.pem")
        let packagedIdentityURL = workingDirectoryURL.appendingPathComponent("identity.p12")
        let packagedIdentityPassphrase = randomPassphrase()

        guard let opensslToolPath = await generateSelfSignedCodeSigningCertificate(
            privateKeyURL: privateKeyURL, certificateURL: certificateURL
        ) else { return false }

        guard await packageCertificateAndKeyAsPKCS12(
            opensslToolPath: opensslToolPath,
            privateKeyURL: privateKeyURL,
            certificateURL: certificateURL,
            packagedIdentityURL: packagedIdentityURL,
            passphrase: packagedIdentityPassphrase
        ) else { return false }

        let loginKeychainPath = await resolveLoginKeychainPath()
        let importResult = await runTool(
            executablePath: securityToolPath,
            arguments: [
                "import", packagedIdentityURL.path,
                "-k", loginKeychainPath,
                "-P", packagedIdentityPassphrase,
                "-f", "pkcs12",
                // Let `codesign` use the key, and allow it without a per-use
                // prompt where macOS honors the ACL. `set-key-partition-list`
                // would make that unconditional, but it requires the login
                // keychain password, which Iris neither has nor asks for — so a
                // single system prompt on the first sign is expected.
                "-T", "/usr/bin/codesign",
                "-A",
            ],
            timeoutSeconds: quickToolTimeoutSeconds
        )
        return importResult.succeeded
    }

    /// Run `openssl req -x509` against each candidate binary until one produces
    /// both files, and return the binary that worked (the PKCS#12 step must use
    /// the same one). Nil when no available openssl could do it — which is a
    /// clean "fall back to ad-hoc", never a half-made identity.
    private static func generateSelfSignedCodeSigningCertificate(
        privateKeyURL: URL,
        certificateURL: URL
    ) async -> String? {
        let fileManager = FileManager.default
        for opensslToolPath in opensslToolPathCandidates where fileManager.isExecutableFile(atPath: opensslToolPath) {
            let generation = await runTool(
                executablePath: opensslToolPath,
                arguments: [
                    "req", "-x509",
                    "-newkey", "rsa:2048",
                    // Without -nodes openssl would encrypt the key and block
                    // forever waiting for a passphrase on a terminal this app
                    // does not have.
                    "-nodes",
                    "-days", "3650",
                    "-keyout", privateKeyURL.path,
                    "-out", certificateURL.path,
                    "-subj", "/CN=\(irisLocalCertificateCommonName)",
                    // The codeSigning EKU is what makes `security find-identity
                    // -p codesigning` list this certificate at all.
                    "-addext", "extendedKeyUsage=codeSigning",
                    "-addext", "keyUsage=digitalSignature",
                ],
                timeoutSeconds: quickToolTimeoutSeconds
            )
            let bothFilesExist = fileManager.fileExists(atPath: privateKeyURL.path)
                && fileManager.fileExists(atPath: certificateURL.path)
            if generation.succeeded && bothFilesExist {
                return opensslToolPath
            }
            // A partial attempt must not poison the next candidate's check.
            try? fileManager.removeItem(at: privateKeyURL)
            try? fileManager.removeItem(at: certificateURL)
        }
        return nil
    }

    /// Pack the certificate + key into a PKCS#12 the keychain will accept.
    /// Tried twice on purpose: OpenSSL 3 defaults to encryption parameters that
    /// older Keychain importers reject, so the first attempt pins the widely
    /// understood SHA1/3DES parameters and the second falls back to whatever the
    /// local openssl defaults to (which is what LibreSSL needs when it does not
    /// recognize the pinned flags).
    private static func packageCertificateAndKeyAsPKCS12(
        opensslToolPath: String,
        privateKeyURL: URL,
        certificateURL: URL,
        packagedIdentityURL: URL,
        passphrase: String
    ) async -> Bool {
        let sharedArguments = [
            "pkcs12", "-export",
            "-inkey", privateKeyURL.path,
            "-in", certificateURL.path,
            "-out", packagedIdentityURL.path,
            "-name", irisLocalCertificateCommonName,
            "-passout", "pass:\(passphrase)",
        ]
        let widelyCompatibleEncryptionArguments = [
            "-keypbe", "PBE-SHA1-3DES",
            "-certpbe", "PBE-SHA1-3DES",
            "-macalg", "sha1",
        ]

        for argumentVariant in [sharedArguments + widelyCompatibleEncryptionArguments, sharedArguments] {
            let packaging = await runTool(
                executablePath: opensslToolPath,
                arguments: argumentVariant,
                timeoutSeconds: quickToolTimeoutSeconds
            )
            if packaging.succeeded && FileManager.default.fileExists(atPath: packagedIdentityURL.path) {
                return true
            }
            try? FileManager.default.removeItem(at: packagedIdentityURL)
        }
        return false
    }

    /// The login keychain `security import` should write into. `security
    /// login-keychain` prints it quoted; the conventional path is the fallback
    /// so an unparseable answer still lands the certificate somewhere usable.
    private static func resolveLoginKeychainPath() async -> String {
        let keychainQuery = await runTool(
            executablePath: securityToolPath,
            arguments: ["login-keychain"],
            timeoutSeconds: quickToolTimeoutSeconds
        )
        if let quotedPath = quotedKeychainPath(inSecurityKeychainOutput: keychainQuery.standardOutputText) {
            return quotedPath
        }
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Keychains/login.keychain-db")
    }

    /// Pure: the path inside the quotes of `security login-keychain` output.
    static func quotedKeychainPath(inSecurityKeychainOutput securityKeychainOutput: String) -> String? {
        guard let openingQuoteIndex = securityKeychainOutput.firstIndex(of: "\""),
              let closingQuoteIndex = securityKeychainOutput.lastIndex(of: "\""),
              openingQuoteIndex < closingQuoteIndex else { return nil }
        let path = String(securityKeychainOutput[
            securityKeychainOutput.index(after: openingQuoteIndex)..<closingQuoteIndex
        ]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    /// A fresh random passphrase for the throwaway PKCS#12 file. Alphanumeric so
    /// nothing in it can be mistaken for shell syntax if it is ever logged by a
    /// tool Iris does not control.
    private static func randomPassphrase() -> String {
        let allowedCharacters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<32).map { _ in allowedCharacters.randomElement() ?? "x" })
    }

    // MARK: - Signing a packaged bundle, inside out

    /// Sign `applicationBundlePath` with `identity`, deepest nested code first,
    /// then the bundle itself, then verify. This is the same order
    /// `scripts/deploy-iris-local.sh` relies on Xcode to perform: a bundle whose
    /// outer signature is applied before its nested frameworks is invalid the
    /// moment those frameworks are re-signed, so the order is load-bearing, not
    /// stylistic.
    static func signApplicationBundle(
        atPath applicationBundlePath: String,
        identity: StableSigningIdentity
    ) async -> SigningOutcome {
        var pathIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: applicationBundlePath, isDirectory: &pathIsDirectory),
              pathIsDirectory.boolValue else {
            return .failed(reason: "there is no app bundle at that path to sign")
        }

        // Read the entitlements the packaging build already gave the app BEFORE
        // re-signing. `codesign --force --sign` without `--entitlements` drops
        // them silently, which would strip capabilities the app needs — the
        // quietest possible way to break someone's build.
        let existingEntitlementsText = await entitlementsPropertyListText(ofBundleAtPath: applicationBundlePath)
        let entitlementsFileURL = existingEntitlementsText.isEmpty
            ? nil
            : writeTemporaryEntitlementsFile(containing: existingEntitlementsText)
        defer {
            if let entitlementsFileURL {
                try? FileManager.default.removeItem(at: entitlementsFileURL)
            }
        }

        // Nested code first. A single stubborn nested item is recorded rather
        // than thrown, because the final `--verify --deep --strict` is the real
        // judge — and if it passes anyway, an unsignable stray file was never
        // load-bearing.
        var nestedSigningComplaints: [String] = []
        for nestedCodePath in nestedCodePathsToSignDeepestFirst(inApplicationBundleAtPath: applicationBundlePath) {
            let nestedSigning = await runTool(
                executablePath: codesignToolPath,
                arguments: [
                    "--force",
                    "--sign", identity.codesignIdentityName,
                    "--timestamp=none",
                    "--preserve-metadata=entitlements",
                    nestedCodePath,
                ],
                timeoutSeconds: signingToolTimeoutSeconds
            )
            if !nestedSigning.succeeded {
                let nestedItemName = (nestedCodePath as NSString).lastPathComponent
                nestedSigningComplaints.append("\(nestedItemName): \(nestedSigning.shortFailureDescription)")
            }
        }

        var applicationSigningArguments = [
            "--force",
            "--sign", identity.codesignIdentityName,
            "--timestamp=none",
            "--options", "runtime",
        ]
        if let entitlementsFileURL {
            applicationSigningArguments += ["--entitlements", entitlementsFileURL.path]
        }
        applicationSigningArguments.append(applicationBundlePath)

        var applicationSigning = await runTool(
            executablePath: codesignToolPath,
            arguments: applicationSigningArguments,
            timeoutSeconds: signingToolTimeoutSeconds
        )
        if !applicationSigning.succeeded {
            // The hardened runtime can be refused for an app that loads an
            // unsigned library or ships an old-format binary. A STABLE signature
            // without the hardened runtime is still the whole point of this
            // step, so retry without it rather than give up on the identity.
            let argumentsWithoutHardenedRuntime = applicationSigningArguments.filter {
                $0 != "--options" && $0 != "runtime"
            }
            applicationSigning = await runTool(
                executablePath: codesignToolPath,
                arguments: argumentsWithoutHardenedRuntime,
                timeoutSeconds: signingToolTimeoutSeconds
            )
        }
        guard applicationSigning.succeeded else {
            return .failed(reason: applicationSigning.shortFailureDescription)
        }

        let verification = await runTool(
            executablePath: codesignToolPath,
            arguments: ["--verify", "--deep", "--strict", applicationBundlePath],
            timeoutSeconds: signingToolTimeoutSeconds
        )
        guard verification.succeeded else {
            let nestedDetail = nestedSigningComplaints.isEmpty
                ? ""
                : " (nested code that wouldn't sign: \(nestedSigningComplaints.joined(separator: "; ")))"
            return .failed(reason: verification.shortFailureDescription + nestedDetail)
        }
        return .signed
    }

    /// Every nested code item inside the bundle, DEEPEST FIRST — a dylib buried
    /// in a framework is signed before the framework, which is signed before the
    /// app. Symlinks are skipped (a framework's `Versions/Current` and its
    /// top-level shortcut both point at something already in this list, and
    /// signing through them would sign the same code twice).
    static func nestedCodePathsToSignDeepestFirst(
        inApplicationBundleAtPath applicationBundlePath: String
    ) -> [String] {
        let fileManager = FileManager.default
        let contentsDirectoryURL = URL(
            fileURLWithPath: (applicationBundlePath as NSString).appendingPathComponent("Contents"),
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: contentsDirectoryURL.path) else { return [] }

        let mainExecutableName = mainExecutableName(ofBundleAtPath: applicationBundlePath)
        let requestedResourceKeys: [URLResourceKey] = [
            .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .isExecutableKey,
        ]
        guard let directoryEnumerator = fileManager.enumerator(
            at: contentsDirectoryURL,
            includingPropertiesForKeys: requestedResourceKeys,
            options: []
        ) else { return [] }

        var nestedCodePaths: [String] = []
        for case let candidateURL as URL in directoryEnumerator {
            let resourceValues = try? candidateURL.resourceValues(forKeys: Set(requestedResourceKeys))
            if resourceValues?.isSymbolicLink == true { continue }
            let candidatePath = candidateURL.path

            if nestedCodeBundleSuffixes.contains(where: { candidatePath.hasSuffix($0) }) {
                nestedCodePaths.append(candidatePath)
                continue
            }

            // A loose helper binary sitting next to the app's own executable in
            // its Contents/MacOS. Two exclusions: the app's own main executable
            // (signed as part of the app bundle itself, not separately), and the
            // Contents/MacOS of any NESTED bundle — a nested `.app` or `.xpc` is
            // already in this list, and signing it covers its executable.
            //
            // "Directly inside the app's own MacOS directory" is decided by the
            // enumerator's own depth (Contents/ is the root, so MacOS is level 1
            // and a file in it is level 2) plus the parent's NAME. Deliberately
            // NOT an absolute-path comparison: the enumerator spells paths
            // differently from the caller (it returns /private/var/… for a bundle
            // the caller named /var/…), so a string compare against a composed
            // path matches nothing and every helper binary silently goes unsigned.
            let parentDirectoryName = (candidatePath as NSString)
                .deletingLastPathComponent
                .components(separatedBy: "/").last
            let isDirectlyInsideTheAppsOwnExecutablesDirectory =
                directoryEnumerator.level == 2 && parentDirectoryName == "MacOS"
            if resourceValues?.isRegularFile == true,
               resourceValues?.isExecutable == true,
               isDirectlyInsideTheAppsOwnExecutablesDirectory,
               candidateURL.lastPathComponent != mainExecutableName {
                nestedCodePaths.append(candidatePath)
            }
        }

        // Deepest first, then alphabetical so the order is deterministic (and so
        // a test can assert it).
        return nestedCodePaths.sorted { leftPath, rightPath in
            let leftDepth = leftPath.split(separator: "/").count
            let rightDepth = rightPath.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            return leftPath < rightPath
        }
    }

    /// Path suffixes that mean "this is code with its own signature".
    static let nestedCodeBundleSuffixes = [
        ".framework", ".dylib", ".so", ".xpc", ".appex", ".bundle", ".app",
    ]

    /// The bundle's own main executable name, from `CFBundleExecutable`. Nil when
    /// the Info.plist cannot be read, in which case nothing in Contents/MacOS is
    /// excluded — signing the main executable separately is harmless, whereas
    /// guessing its name from the bundle name would sometimes be wrong.
    private static func mainExecutableName(ofBundleAtPath applicationBundlePath: String) -> String? {
        let infoPlistPath = (applicationBundlePath as NSString)
            .appendingPathComponent("Contents/Info.plist")
        guard let infoPlistData = FileManager.default.contents(atPath: infoPlistPath),
              let infoPlist = try? PropertyListSerialization.propertyList(
                  from: infoPlistData, format: nil
              ) as? [String: Any],
              let executableName = infoPlist["CFBundleExecutable"] as? String,
              !executableName.isEmpty else { return nil }
        return executableName
    }

    /// Write the entitlements plist somewhere `codesign --entitlements` can read
    /// it. Nil when it cannot be written, which simply means the app is re-signed
    /// without re-applying entitlements.
    private static func writeTemporaryEntitlementsFile(containing entitlementsText: String) -> URL? {
        let entitlementsFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-resign-entitlements-\(UUID().uuidString).plist")
        do {
            try entitlementsText.write(to: entitlementsFileURL, atomically: true, encoding: .utf8)
            return entitlementsFileURL
        } catch {
            return nil
        }
    }

    // MARK: - Reading a bundle's signature back

    /// The designated requirement of a signed bundle — the sentence macOS itself
    /// uses to decide "is this the same app as before". Logged after a relaunch
    /// so a permissions reset can be explained instead of guessed at.
    static func designatedRequirement(ofBundleAtPath bundlePath: String) async -> String? {
        let requirementQuery = await runTool(
            executablePath: codesignToolPath,
            arguments: ["-d", "-r-", bundlePath],
            timeoutSeconds: quickToolTimeoutSeconds
        )
        // `codesign -d` prints its findings on stderr and the requirement on
        // stdout depending on version, so both are searched.
        return designatedRequirementText(
            inCodesignOutput: requirementQuery.standardOutputText + "\n" + requirementQuery.standardErrorText
        )
    }

    /// Pure: the requirement text after the `designated =>` marker.
    static func designatedRequirementText(inCodesignOutput codesignOutput: String) -> String? {
        for rawLine in codesignOutput.split(separator: "\n") {
            let line = String(rawLine)
            guard let markerRange = line.range(of: "designated =>") else { continue }
            let requirement = line[markerRange.upperBound...].trimmingCharacters(in: .whitespaces)
            return requirement.isEmpty ? nil : requirement
        }
        return nil
    }

    /// The entitlements plist of a bundle as XML text, or "" when it has none.
    static func entitlementsPropertyListText(ofBundleAtPath bundlePath: String) async -> String {
        let entitlementsQuery = await runTool(
            executablePath: codesignToolPath,
            arguments: ["-d", "--entitlements", ":-", bundlePath],
            timeoutSeconds: quickToolTimeoutSeconds
        )
        return propertyListTextExtracted(
            fromCodesignEntitlementsOutput: entitlementsQuery.standardOutputText
                + "\n" + entitlementsQuery.standardErrorText
        )
    }

    /// Pure: pull the plist out of whatever `codesign -d --entitlements :-`
    /// printed. Older codesign versions prefix the XML with a binary blob header
    /// and every version interleaves its own `Executable=…` chatter, so the text
    /// is cut down to exactly the `<?xml … </plist>` span.
    static func propertyListTextExtracted(fromCodesignEntitlementsOutput codesignOutput: String) -> String {
        guard let xmlDeclarationRange = codesignOutput.range(of: "<?xml"),
              let plistClosingRange = codesignOutput.range(of: "</plist>", options: .backwards),
              xmlDeclarationRange.lowerBound < plistClosingRange.upperBound else { return "" }
        return String(codesignOutput[xmlDeclarationRange.lowerBound..<plistClosingRange.upperBound])
    }

    /// Pure: whether an entitlements plist really grants `entitlementKey`. Parsed
    /// properly first; the text scan is the fallback for output that is truncated
    /// or wrapped in a way the parser rejects, because a truncated answer must
    /// still be able to say "yes, this key is there and true" rather than
    /// silently report a missing entitlement.
    static func entitlementsDeclareKeyAsTrue(
        _ entitlementKey: String,
        inPropertyListText entitlementsPropertyListText: String
    ) -> Bool {
        if let entitlementsData = entitlementsPropertyListText.data(using: .utf8),
           let parsedEntitlements = try? PropertyListSerialization.propertyList(
               from: entitlementsData, format: nil
           ) as? [String: Any],
           let declaredValue = parsedEntitlements[entitlementKey] {
            if let booleanValue = declaredValue as? Bool { return booleanValue }
            if let numberValue = declaredValue as? NSNumber { return numberValue.boolValue }
            return false
        }

        guard let keyRange = entitlementsPropertyListText.range(of: "<key>\(entitlementKey)</key>") else {
            return false
        }
        let textAfterKey = entitlementsPropertyListText[keyRange.upperBound...]
        let valueElement = textAfterKey.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        return valueElement.hasPrefix("<true/>")
    }

    // MARK: - Packaging-metadata verification

    /// Prove (or disprove) that the packaged artifact really carries the
    /// packaging metadata an edit claimed to add. This exists because the
    /// verification build is a COMPILE CHECK: an Info.plist key or an entitlement
    /// that was added, misspelled, or written into the wrong file compiles
    /// perfectly and would otherwise pass as done. Returns one description per
    /// failure; an empty array means every expectation held.
    static func verifyPackagedMetadata(
        artifactPath: String,
        expectations: PackagingExpectations
    ) async -> [String] {
        guard !expectations.isEmpty else { return [] }

        var infoPlistKeysPresentInArtifact: Set<String> = []
        let infoPlistPath = (artifactPath as NSString).appendingPathComponent("Contents/Info.plist")
        for infoPlistKey in expectations.infoPlistKeysThatMustExist {
            let extraction = await runTool(
                executablePath: plutilToolPath,
                arguments: ["-extract", infoPlistKey, "raw", infoPlistPath],
                timeoutSeconds: quickToolTimeoutSeconds
            )
            if extraction.succeeded {
                infoPlistKeysPresentInArtifact.insert(infoPlistKey)
            }
        }

        let entitlementsText = expectations.entitlementKeysThatMustBeTrue.isEmpty
            ? ""
            : await entitlementsPropertyListText(ofBundleAtPath: artifactPath)

        return describePackagingExpectationFailures(
            expectations: expectations,
            infoPlistKeysPresentInArtifact: infoPlistKeysPresentInArtifact,
            entitlementsPropertyListText: entitlementsText
        )
    }

    /// Pure: turn "what was expected" plus "what the artifact actually has" into
    /// human-readable failures. Kept separate from the process spawning above so
    /// the wording — the part a reader actually sees — is unit-testable.
    static func describePackagingExpectationFailures(
        expectations: PackagingExpectations,
        infoPlistKeysPresentInArtifact: Set<String>,
        entitlementsPropertyListText: String
    ) -> [String] {
        var failureDescriptions: [String] = []

        for infoPlistKey in expectations.infoPlistKeysThatMustExist
        where !infoPlistKeysPresentInArtifact.contains(infoPlistKey) {
            failureDescriptions.append(
                "the packaged app's Info.plist has no \(infoPlistKey) key — that edit didn't reach the built app"
            )
        }

        for entitlementKey in expectations.entitlementKeysThatMustBeTrue
        where !entitlementsDeclareKeyAsTrue(entitlementKey, inPropertyListText: entitlementsPropertyListText) {
            failureDescriptions.append(
                "the packaged app isn't signed with the \(entitlementKey) entitlement — that edit didn't reach the built app"
            )
        }

        return failureDescriptions
    }

    // MARK: - Running a tool (argv array, never a shell)

    /// Await a tool run off the main actor. Every caller in this file is
    /// main-actor isolated, and `codesign` over a large bundle takes seconds to
    /// minutes, so the blocking work is pushed to a detached task and only the
    /// result comes back.
    private static func runTool(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async -> IrisSigningToolInvocationResult {
        await Task.detached(priority: .userInitiated) {
            runToolBlocking(
                executablePath: executablePath,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds
            )
        }.value
    }

    /// Launch one tool by absolute path with an argument array — no shell, so
    /// nothing in an argument can be reinterpreted as a command.
    ///
    /// This does not reuse `ToolVersionService.runCommand` for one reason: a
    /// TIMEOUT. `codesign` using a freshly imported key can raise the system
    /// "allow access to your keychain" panel and then sit there until a human
    /// answers, and a rebuild must not be able to wedge forever on a dialog the
    /// reader may never see. So this runner owns the process and can kill it.
    private nonisolated static func runToolBlocking(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) -> IrisSigningToolInvocationResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        // A tool that decides to prompt on stdin would otherwise wait forever on
        // a terminal this app does not have.
        process.standardInput = FileHandle.nullDevice
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        do {
            try process.run()
        } catch {
            return .launchFailure(executablePath: executablePath)
        }

        // Both pipes are drained concurrently: reading one to completion first
        // deadlocks the moment the tool fills the other pipe's buffer. The
        // group's wait is the barrier that makes both reads visible here.
        let collectedOutput = IrisSigningCollectedToolOutput()
        let pipeReadingGroup = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: pipeReadingGroup) {
            collectedOutput.standardOutput = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .userInitiated).async(group: pipeReadingGroup) {
            collectedOutput.standardError = standardErrorPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let processIdentifier = process.processIdentifier
        let askTheProcessToStop = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        // SIGTERM is ignorable, and something blocked on a modal keychain panel
        // may well ignore it, so a second shot follows that cannot be ignored.
        let killTheProcessOutright = DispatchWorkItem {
            if process.isRunning { kill(processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: askTheProcessToStop)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds + 5, execute: killTheProcessOutright)

        pipeReadingGroup.wait()
        process.waitUntilExit()
        askTheProcessToStop.cancel()
        killTheProcessOutright.cancel()

        return IrisSigningToolInvocationResult(
            exitStatus: process.terminationStatus,
            standardOutputText: String(data: collectedOutput.standardOutput, encoding: .utf8) ?? "",
            standardErrorText: String(data: collectedOutput.standardError, encoding: .utf8) ?? ""
        )
    }
}

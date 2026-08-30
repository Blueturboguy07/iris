//
//  GuideService.swift
//  leanring-buddy
//
//  Fetches a guide from publik, caches it for the session, resolves a deep
//  link's resume point against what the guide actually contains, and remembers
//  how far the reader got. The wire contract is
//  `app/api/iris/guides/[slug]/route.ts`; the resume and progress behavior is
//  ported from `iris-desktop/ui/app.js` (`loadGuide`, `setPlatform`,
//  `progressKey`), with `iris-desktop/src-tauri/src/main.rs` remaining the
//  behavioral spec for link validation.
//

import Foundation

enum GuideServiceError: Error, Equatable, Sendable {
    case invalidGuideSlug
    /// The API rejected the version string itself (HTTP 400).
    case invalidGuideVersionRequest
    /// The guide exists but is still in review (HTTP 403).
    case guideIsNotPublished
    /// publik has no guide by this slug (HTTP 404).
    case guideNotFound
    /// The guide exists but has moved past the version the link named (HTTP 409).
    case guideVersionIsNoLongerAvailable(requestedVersion: Int)
    case apiBaseIsNotAllowed
    case unexpectedResponseStatus(statusCode: Int)
    case responseCouldNotBeDecoded(reason: String)
    case guideHasNoBranches
    case transportFailure(reason: String)

    var userFacingMessage: String {
        switch self {
        case .invalidGuideSlug:
            return "That guide link is invalid. Open a guide from a publik app page."
        case .invalidGuideVersionRequest:
            return "That guide link asks for a version publik cannot read."
        case .guideIsNotPublished:
            return "This guide has not finished review yet."
        case .guideNotFound:
            return "Publik has not published a guide for this app yet."
        case .guideVersionIsNoLongerAvailable(let requestedVersion):
            return "Guide version \(requestedVersion) is no longer available."
        case .apiBaseIsNotAllowed:
            return "Iris only loads guides from publik."
        case .unexpectedResponseStatus(let statusCode):
            return "Guide service returned \(statusCode)."
        case .responseCouldNotBeDecoded(let reason):
            return "Iris could not read that guide: \(reason)"
        case .guideHasNoBranches:
            return "This guide has no reviewed desktop steps."
        case .transportFailure(let reason):
            return "Iris could not reach publik: \(reason)"
        }
    }
}

/// Where a reader is inside one branch of one guide.
struct GuideProgress: Equatable, Sendable {
    let stepIndex: Int
    let isCompleted: Bool
}

/// A deep link's resume point after it has been checked against the guide that
/// actually came back. The branch is one this guide really has and the step
/// index is inside that branch's step list, so nothing downstream has to
/// re-check either.
struct ResolvedGuideHandoff: Equatable, Sendable {
    let branch: IrisGuideBranch
    let stepIndex: Int
}

actor GuideService {
    /// Where guides come from when nothing else is configured.
    static let defaultAPIBase = "https://publikhq.com"

    /// Progress keys look like `iris:progress:cue:macos:ios` — see
    /// `progressStorageKey` for why the version is no longer part of them.
    ///
    /// The prefix still matches the Tauri panel's `STORAGE.progressPrefix`, but
    /// the shape after it no longer does, and that costs nothing: the two
    /// surfaces have always kept their own stores (this is `UserDefaults`, that
    /// is the webview's `localStorage`) and have never read each other's keys —
    /// which is exactly why a reader seven steps into an install here still has
    /// 0 saved in their browser. The website and the Tauri and Windows panels
    /// still key a reader's place on the guide version and so still lose it on
    /// every republish; fixing them is a change in those repositories.
    static let progressKeyPrefix = "iris:progress:"

    private let apiBase: String
    private let urlSession: URLSession
    private let userDefaults: UserDefaults

    /// Guides fetched during this session, keyed by slug and requested version.
    /// A guide is a few kilobytes of text that changes when its version does, so
    /// holding onto it saves a round trip every time the panel reopens.
    private var cachedGuidesByRequestKey: [String: IrisGuide] = [:]

    init(
        apiBase: String = GuideService.defaultAPIBase,
        urlSession: URLSession = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.apiBase = GuideService.normalizedAPIBase(apiBase) ?? GuideService.defaultAPIBase
        self.urlSession = urlSession
        self.userDefaults = userDefaults
    }

    // MARK: - API base

    /// Accepts publik itself, and localhost so the site can be developed against
    /// this app. Ported from `normalizeApiBase` in `iris-desktop/ui/app.js`.
    static func normalizedAPIBase(_ candidateAPIBase: String) -> String? {
        let trimmedCandidate = candidateAPIBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var urlComponents = URLComponents(string: trimmedCandidate) else {
            return nil
        }
        let scheme = urlComponents.scheme?.lowercased()
        let host = urlComponents.host?.lowercased() ?? ""

        let isPublik = scheme == "https" && (host == "publikhq.com" || host == "www.publikhq.com")
        let isLocalDevelopment = (scheme == "http" || scheme == "https")
            && (host == "localhost" || host == "127.0.0.1")
        guard isPublik || isLocalDevelopment else {
            return nil
        }

        // Only the origin is kept; a path, query, or fragment on the API base
        // would end up spliced in front of the route path below.
        urlComponents.path = ""
        urlComponents.query = nil
        urlComponents.fragment = nil
        guard let normalizedURL = urlComponents.url else {
            return nil
        }
        var normalizedAPIBase = normalizedURL.absoluteString
        while normalizedAPIBase.hasSuffix("/") {
            normalizedAPIBase.removeLast()
        }
        return normalizedAPIBase
    }

    // MARK: - Fetching

    /// Fetches a guide, or returns the copy already fetched this session.
    /// Passing the version from a deep link makes the API answer 409 rather than
    /// silently handing back a newer guide, which is the difference between the
    /// reader being told to restart and them following steps for a commit they
    /// do not have checked out.
    func fetchGuide(slug: String, version: Int?) async throws -> IrisGuide {
        guard IrisDeepLinkParser.isValidGuideSlug(slug) else {
            throw GuideServiceError.invalidGuideSlug
        }
        if let version = version, version < 1 {
            throw GuideServiceError.invalidGuideVersionRequest
        }

        let requestKey = guideRequestKey(slug: slug, version: version)
        if let cachedGuide = cachedGuidesByRequestKey[requestKey] {
            return cachedGuide
        }

        let guideURL = try guideRequestURL(slug: slug, version: version)
        var guideRequest = URLRequest(url: guideURL)
        guideRequest.httpMethod = "GET"
        guideRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        // The route already sets a short cache lifetime; asking URLSession to
        // reuse a stale body on top of that is how a reader ends up on a version
        // publik has already retired.
        guideRequest.cachePolicy = .reloadIgnoringLocalCacheData

        let responseData: Data
        let urlResponse: URLResponse
        do {
            (responseData, urlResponse) = try await urlSession.data(for: guideRequest)
        } catch {
            throw GuideServiceError.transportFailure(reason: error.localizedDescription)
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw GuideServiceError.unexpectedResponseStatus(statusCode: 0)
        }

        // Each status the route can produce becomes a distinct case so the panel
        // can say what actually went wrong instead of "something failed".
        switch httpResponse.statusCode {
        case 200:
            break
        case 400:
            throw GuideServiceError.invalidGuideVersionRequest
        case 403:
            throw GuideServiceError.guideIsNotPublished
        case 404:
            throw GuideServiceError.guideNotFound
        case 409:
            throw GuideServiceError.guideVersionIsNoLongerAvailable(requestedVersion: version ?? 0)
        default:
            throw GuideServiceError.unexpectedResponseStatus(statusCode: httpResponse.statusCode)
        }

        let guide: IrisGuide
        do {
            guide = try JSONDecoder().decode(IrisGuide.self, from: responseData)
        } catch {
            throw GuideServiceError.responseCouldNotBeDecoded(reason: error.localizedDescription)
        }

        try validate(guide: guide, againstRequestedVersion: version)
        cachedGuidesByRequestKey[requestKey] = guide
        return guide
    }

    /// The checks the Tauri panel repeats on the body it gets back, because a
    /// 200 from a proxy or a cached edge response is not on its own proof that
    /// the guide matches what was asked for.
    private func validate(guide: IrisGuide, againstRequestedVersion requestedVersion: Int?) throws {
        guard IrisDeepLinkParser.isValidGuideSlug(guide.appSlug) else {
            throw GuideServiceError.invalidGuideSlug
        }
        guard guide.version >= 1 else {
            throw GuideServiceError.invalidGuideVersionRequest
        }
        if let requestedVersion = requestedVersion, guide.version != requestedVersion {
            throw GuideServiceError.guideVersionIsNoLongerAvailable(requestedVersion: requestedVersion)
        }
        guard guide.status.isPublished else {
            throw GuideServiceError.guideIsNotPublished
        }
        guard !guide.branches.isEmpty else {
            throw GuideServiceError.guideHasNoBranches
        }
    }

    func clearCachedGuides() {
        cachedGuidesByRequestKey.removeAll()
    }

    private func guideRequestKey(slug: String, version: Int?) -> String {
        version.map { "\(slug):v\($0)" } ?? "\(slug):latest"
    }

    private func guideRequestURL(slug: String, version: Int?) throws -> URL {
        guard var urlComponents = URLComponents(string: "\(apiBase)/api/iris/guides/\(slug)") else {
            throw GuideServiceError.apiBaseIsNotAllowed
        }
        if let version = version {
            urlComponents.queryItems = [URLQueryItem(name: "version", value: String(version))]
        }
        guard let guideURL = urlComponents.url else {
            throw GuideServiceError.apiBaseIsNotAllowed
        }
        return guideURL
    }

    // MARK: - Resolving a handoff against the fetched guide

    /// Checks a deep link's branch and step against the guide that came back.
    ///
    /// This is the third time these values are validated — the website builds
    /// them, `IrisDeepLinkParser` re-checks their shape on arrival, and this
    /// checks them against reality. The Tauri app validates here too, on purpose:
    /// shape alone cannot tell you that `macos:ios` is a branch *this* guide has,
    /// or that step 14 exists in it. A link that names neither lands on the
    /// guide's own first branch at step one rather than on nothing.
    nonisolated static func resolveHandoff(
        _ guideDeepLink: GuideDeepLink,
        against guide: IrisGuide,
        preferredPlatform: IrisPlatform
    ) -> ResolvedGuideHandoff? {
        let branchNamedByTheLink = guideDeepLink.branchKey.flatMap { branchKey in
            guide.branch(matchingBranchKey: branchKey)
        }
        let branchForThisComputer = guide.branches.first { candidateBranch in
            candidateBranch.platform == preferredPlatform
        }
        guard let resolvedBranch = branchNamedByTheLink
                ?? branchForThisComputer
                ?? guide.branches.first else {
            return nil
        }

        // A step only travels with the branch it was counted in. Applying step 9
        // from the iPhone branch to the Android branch would be a different
        // toolchain's ninth step, so an unmatched branch resets to the start.
        let lastStepIndex = max(0, resolvedBranch.steps.count - 1)
        let stepIndexNamedByTheLink: Int
        if branchNamedByTheLink != nil, let stepIndex = guideDeepLink.stepIndex {
            stepIndexNamedByTheLink = min(max(0, Int(stepIndex)), lastStepIndex)
        } else {
            stepIndexNamedByTheLink = 0
        }

        return ResolvedGuideHandoff(branch: resolvedBranch, stepIndex: stepIndexNamedByTheLink)
    }

    // MARK: - Progress

    /// `iris:progress:{slug}:{platform}:{target}` — a reader's place in one
    /// branch of one guide. The branch key is part of it because the same reader
    /// can be nine steps into the Android build and not have started the iPhone
    /// one.
    ///
    /// THE VERSION IS DELIBERATELY NOT IN THIS KEY ANY MORE. It used to be
    /// (`…:{slug}:v{version}:{branchKey}`), and that one detail was a bug with a
    /// reader's name on it: publishing a guide bumps its version, so every
    /// republish made every mid-install reader's saved place unreachable and
    /// dropped them back on step one. Not as an edge case — as the guaranteed
    /// outcome of publik shipping any edit at all, including edits that changed
    /// no step. The reader who reported "it made me start over" was describing
    /// our release process.
    ///
    /// It was visible on the founder's own Mac as stranded keys sitting beside
    /// each other, the same guide and branch several times over:
    /// `iris:progress:cue:v4:macos:desktop` next to `…:cue:v6:…`, nitroai at
    /// v2, v3, v4 AND v5, whimprflow parked at v7 while the code had moved to
    /// v10.
    ///
    /// The version has not been thrown away — it moved INTO the record, next to
    /// the id of the step the reader was on, where `loadProgress` can use it to
    /// answer the question the key was crudely approximating: does the place
    /// they stopped at still mean the same thing?
    nonisolated static func progressStorageKey(
        slug: String,
        branchKey: String
    ) -> String {
        "\(progressKeyPrefix)\(slug):\(branchKey)"
    }

    /// The key shape shipped builds wrote. Nothing writes it any more; it exists
    /// so records already on readers' disks can be found and carried forward.
    nonisolated static func versionPinnedProgressStorageKey(
        slug: String,
        version: Int,
        branchKey: String
    ) -> String {
        "\(progressKeyPrefix)\(slug):v\(version):\(branchKey)"
    }

    func loadProgress(slug: String, version: Int, branchKey: String) -> GuideProgress {
        carryVersionPinnedProgressForwardOnceThisSession()

        guard let storedProgress = userDefaults.dictionary(
            forKey: Self.progressStorageKey(slug: slug, branchKey: branchKey)
        ) else {
            return GuideProgress(stepIndex: 0, isCompleted: false)
        }

        let storedStepIndex = max(0, (storedProgress["step"] as? Int) ?? 0)
        let storedCompletion = (storedProgress["completed"] as? Bool) ?? false
        let versionThatWroteThisRecord = storedProgress["version"] as? Int
        let stepIdsInThisVersion = stepIdsOfTheBranch(
            slug: slug,
            version: version,
            branchKey: branchKey
        )

        // The guide has not moved since the reader was last here, so the index
        // means exactly what it meant when it was written.
        if versionThatWroteThisRecord == version {
            return GuideProgress(
                stepIndex: clampToTheBranch(storedStepIndex, stepIdsInThisVersion),
                isCompleted: storedCompletion
            )
        }

        // The guide HAS moved. A step index is not portable across that — step
        // nine of version two can be a different instruction in version three —
        // but a step ID is, because it names the piece of work rather than its
        // position. So the resume is re-derived from the ID.
        if let stepIdTheReaderStoppedOn = storedProgress["stepId"] as? String,
           !stepIdTheReaderStoppedOn.isEmpty,
           let stepIdsInThisVersion {
            guard let whereThatStepIsNow = stepIdsInThisVersion.firstIndex(
                of: stepIdTheReaderStoppedOn
            ) else {
                // Genuinely gone. This is the case the version-in-the-key was
                // protecting against, and it is the ONLY case that should cost
                // the reader their place.
                return GuideProgress(stepIndex: 0, isCompleted: false)
            }
            return GuideProgress(stepIndex: whereThatStepIsNow, isCompleted: storedCompletion)
        }

        // No ID to match on: either a record written by a build that stored only
        // an index (every record already on a reader's disk today), or a branch
        // this session has not fetched and so cannot look steps up in. Carrying
        // the index is the honest choice — it is where the reader actually was,
        // and `GuideSessionController.restoreSavedProgress` re-checks any resume
        // against the machine before trusting it. Starting them over would be
        // the reported bug, chosen on purpose.
        return GuideProgress(
            stepIndex: clampToTheBranch(storedStepIndex, stepIdsInThisVersion),
            isCompleted: storedCompletion
        )
    }

    /// Stores progress clamped to the branch it belongs to, so a guide that
    /// shrank in a later version cannot leave a reader pointed past its end.
    ///
    /// The step's ID and the guide version go in beside the index, because those
    /// two are what let a later version work out whether the index still means
    /// the same thing. Writing them is what makes the NEXT republish free.
    func saveProgress(
        slug: String,
        version: Int,
        branch: IrisGuideBranch,
        progress: GuideProgress
    ) {
        carryVersionPinnedProgressForwardOnceThisSession()

        let lastStepIndex = max(0, branch.steps.count - 1)
        let clampedStepIndex = min(max(0, progress.stepIndex), lastStepIndex)
        let idOfTheStepTheReaderIsOn = branch.steps.indices.contains(clampedStepIndex)
            ? branch.steps[clampedStepIndex].id
            : ""
        userDefaults.set(
            [
                "step": clampedStepIndex,
                "stepId": idOfTheStepTheReaderIsOn,
                "version": version,
                "completed": progress.isCompleted,
                "updatedAt": Date().timeIntervalSince1970,
            ] as [String: Any],
            forKey: Self.progressStorageKey(slug: slug, branchKey: branch.branchKey)
        )
    }

    /// The step IDs of one branch of one version, read from the guides this
    /// session has already fetched.
    ///
    /// Nothing has to be threaded through for this: `openGuide` fetches the
    /// guide and then restores progress, both through this same service, so by
    /// the time a resume is being worked out the guide it is being worked out
    /// against is already here. When it genuinely is not — a caller reading
    /// progress without opening anything — this answers nil and the resume falls
    /// back to carrying the index, which is what it did before IDs existed.
    private func stepIdsOfTheBranch(
        slug: String,
        version: Int,
        branchKey: String
    ) -> [String]? {
        for cachedGuide in cachedGuidesByRequestKey.values
        where cachedGuide.appSlug == slug && cachedGuide.version == version {
            if let branch = cachedGuide.branch(matchingBranchKey: branchKey) {
                return branch.steps.map(\.id)
            }
        }
        return nil
    }

    private func clampToTheBranch(_ stepIndex: Int, _ stepIdsInThisVersion: [String]?) -> Int {
        guard let stepIdsInThisVersion, !stepIdsInThisVersion.isEmpty else {
            return stepIndex
        }
        return min(stepIndex, stepIdsInThisVersion.count - 1)
    }

    /// Whether the one-time sweep below has already run on this instance.
    private var versionPinnedProgressHasBeenCarriedForward = false

    /// Moves every `…:{slug}:v{version}:{branchKey}` record a shipped build left
    /// behind onto its durable key, and removes the husks.
    ///
    /// This runs over ALL slugs rather than only the one being opened, because
    /// the stranded keys are the damage this bug has already done and a reader
    /// should not have to re-open each guide in turn to get their place back.
    /// Where a guide was stranded under several versions at once — nitroai has
    /// four on the founder's Mac — the most recently written one wins, since
    /// that is the one the reader was actually last working in.
    ///
    /// Deliberately a carry-forward and not a delete: a version-pinned record is
    /// somebody's unfinished install, and the version it was written under is
    /// preserved in the record so `loadProgress` can still tell whether the
    /// guide has moved underneath it.
    private func carryVersionPinnedProgressForwardOnceThisSession() {
        guard !versionPinnedProgressHasBeenCarriedForward else { return }
        versionPinnedProgressHasBeenCarriedForward = true

        // slug + branch key -> the best record found for it, and every stranded
        // key that described the same place.
        var bestRecordForEachPlace: [String: [String: Any]] = [:]
        var strandedKeysForEachPlace: [String: [String]] = [:]

        for storedKey in userDefaults.dictionaryRepresentation().keys
        where storedKey.hasPrefix(Self.progressKeyPrefix) {
            let keyBody = String(storedKey.dropFirst(Self.progressKeyPrefix.count))
            let keyParts = keyBody.split(separator: ":", omittingEmptySubsequences: false)
            // slug : v{n} : platform : target
            guard keyParts.count == 4 else { continue }
            let versionPart = keyParts[1]
            guard versionPart.hasPrefix("v"),
                  let versionInTheKey = Int(versionPart.dropFirst()),
                  versionInTheKey >= 1 else { continue }

            let slug = String(keyParts[0])
            let branchKey = "\(keyParts[2]):\(keyParts[3])"
            let durableKey = Self.progressStorageKey(slug: slug, branchKey: branchKey)
            strandedKeysForEachPlace[durableKey, default: []].append(storedKey)

            guard var strandedRecord = userDefaults.dictionary(forKey: storedKey) else { continue }
            // A stranded record predates step IDs, so the version it was written
            // under is all there is to say "this index came from a different
            // guide than the one you are about to open".
            strandedRecord["version"] = versionInTheKey

            let candidateIsNewer = whenThisRecordWasWritten(strandedRecord)
                > whenThisRecordWasWritten(bestRecordForEachPlace[durableKey])
            if bestRecordForEachPlace[durableKey] == nil || candidateIsNewer {
                bestRecordForEachPlace[durableKey] = strandedRecord
            }
        }

        for (durableKey, strandedKeys) in strandedKeysForEachPlace {
            if let bestStrandedRecord = bestRecordForEachPlace[durableKey] {
                // A record already written under the durable key was written by
                // this build and is newer than anything version-pinned, unless
                // its own timestamp says otherwise.
                let recordAlreadyThere = userDefaults.dictionary(forKey: durableKey)
                if whenThisRecordWasWritten(bestStrandedRecord)
                    > whenThisRecordWasWritten(recordAlreadyThere) {
                    userDefaults.set(bestStrandedRecord, forKey: durableKey)
                }
            }
            for strandedKey in strandedKeys {
                userDefaults.removeObject(forKey: strandedKey)
            }
        }
    }

    private func whenThisRecordWasWritten(_ record: [String: Any]?) -> Double {
        guard let record else { return -Double.greatestFiniteMagnitude }
        return (record["updatedAt"] as? Double) ?? 0
    }

    /// Forgets every guide's progress. The Tauri panel offers the same reset for
    /// a reader who wants to start over without hunting through storage.
    func clearAllStoredProgress() {
        for storedKey in userDefaults.dictionaryRepresentation().keys
        where storedKey.hasPrefix(Self.progressKeyPrefix) {
            userDefaults.removeObject(forKey: storedKey)
        }
    }
}

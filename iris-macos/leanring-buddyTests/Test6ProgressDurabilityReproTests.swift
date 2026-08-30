//
//  Test6ProgressDurabilityReproTests.swift
//  leanring-buddyTests
//
//  Complaint 3 — "it made me start over" — caused by us.
//
//  A reader's place in an install was stored under a key that contains the
//  guide's version: `iris:progress:{slug}:v{version}:{branchKey}`. Republishing
//  a guide bumps that version, so every mid-install reader's saved place became
//  unreachable the moment publik shipped an edit — even an edit that added a
//  comment and changed no step at all. The batch that fixed this reader's other
//  fifteen complaints bumps all sixteen guide versions, so shipping it would
//  have re-created complaint 3 for everyone at once.
//
//  It was already happening. `defaults read com.publikhq.iris` on the founder's
//  Mac shows the wreckage side by side — the same reader, the same guide, the
//  same branch, stranded under several versions:
//
//      "iris:progress:cue:v4:macos:desktop"        "iris:progress:cue:v6:macos:desktop"
//      "iris:progress:nitroai:v2:macos:desktop" … v3 … v4 … v5
//      "iris:progress:simplicity:v3:macos:desktop" … v4 … v6
//      "iris:progress:whimprflow:v7:macos:desktop"   (the code now says v10)
//
//  These exercise the real `GuideService` and the real `GuideSessionController`
//  against a stubbed guide API, so what is measured is the app's own storage
//  behaviour rather than a description of it. Nothing here reads the diff.
//

import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

/// Serves one desktop guide whose STEPS depend on the version asked for, which
/// is the distinction the fix turns on: a republish that only adds a comment
/// must carry a reader forward, and a republish that genuinely renames a step
/// must not resume them into a step that no longer means what it did.
///
/// Deliberately its own protocol rather than a new case in
/// `StubbedGuideURLProtocol`: that stub answers a fixed table where every
/// version of a slug has identical steps, which cannot express either half.
///
/// The guide carries no `git clone` and no `foregroundApp` watch on purpose, so
/// `savedProgressStillMatchesThisMachine` has nothing to check and these
/// measure storage rather than whatever happens to be in the founder's home
/// folder.
final class VersionedStepsGuideURLProtocol: URLProtocol {
    /// v1 and v2 are the same install with a comment changed — the shape of
    /// every guide in this batch. v3 renames the middle step, which is the
    /// shape a resume genuinely must not survive.
    static func stepIdsForVersion(_ version: Int) -> [String] {
        version >= 3
            ? ["open-shell", "install-packages", "build", "open-app"]
            : ["open-shell", "install-deps", "build", "open-app"]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/api/iris/guides/") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let slug = requestURL.lastPathComponent
        let version = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "version" }?
            .value
            .flatMap(Int.init) ?? 1

        let stepsJSON = Self.stepIdsForVersion(version)
            .map { stepId in
                """
                {"id": "\(stepId)", "kind": "terminal", "title": "\(stepId)",
                 "body": "", "command": "echo \(stepId)"}
                """
            }
            .joined(separator: ",\n")

        let body = Data("""
        {
          "appSlug": "\(slug)",
          "appName": "Durability",
          "version": \(version),
          "status": "pilot",
          "sourceOwner": "Blueturboguy07",
          "sourceRepo": "\(slug)",
          "sourceCommit": null,
          "outputType": "desktop_app",
          "estimatedMinutes": 5,
          "readmeSectionIds": [],
          "branches": [
            {
              "platform": "macos",
              "target": null,
              "label": "macOS",
              "shell": "terminal",
              "setupSteps": [],
              "steps": [\(stepsJSON)],
              "unsupported": null
            }
          ]
        }
        """.utf8)

        guard let httpResponse = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
struct Test6ProgressDurabilityReproTests {

    /// A `GuideService` on the versioned stub with storage nothing else shares,
    /// plus the defaults suite itself so a test can seed the exact key shape the
    /// shipped app writes.
    private static func serviceAndStorage() throws -> (GuideService, UserDefaults) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VersionedStepsGuideURLProtocol.self]
        let storage = try #require(
            UserDefaults(suiteName: "com.publik.iris.tests.\(UUID().uuidString)")
        )
        let service = GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: configuration),
            userDefaults: storage
        )
        return (service, storage)
    }

    // MARK: - The reported symptom

    /// THE REPRO. A reader four steps into an install, a republish that changed
    /// nothing about the steps, and the reader is back at step one.
    @Test func aRepublishThatChangedNoStepKeepsTheReaderWhereTheyWere() async throws {
        let (guideService, _) = try Self.serviceAndStorage()

        let publishedGuide = try await guideService.fetchGuide(slug: "durability", version: 2)
        let branch = try #require(publishedGuide.branches.first)
        await guideService.saveProgress(
            slug: "durability",
            version: 2,
            branch: branch,
            progress: GuideProgress(stepIndex: 2, isCompleted: false)
        )

        // publik republishes. Same steps, one comment different, version 3 —
        // except this stub's v3 also renames a step, so use the identical-steps
        // pair v1/v2 for the "nothing really changed" half.
        let republished = try await guideService.fetchGuide(slug: "durability", version: 1)
        #expect(VersionedStepsGuideURLProtocol.stepIdsForVersion(1)
                == VersionedStepsGuideURLProtocol.stepIdsForVersion(2))

        let progressAfterTheRepublish = await guideService.loadProgress(
            slug: "durability",
            version: republished.version,
            branchKey: branch.branchKey
        )
        #expect(progressAfterTheRepublish.stepIndex == 2)
    }

    /// The other half, and the reason the version was in the key to begin with:
    /// a step that genuinely no longer exists must not be resumed into.
    @Test func aRepublishThatRenamedTheStepTheReaderWasOnStartsThemOver() async throws {
        let (guideService, _) = try Self.serviceAndStorage()

        let publishedGuide = try await guideService.fetchGuide(slug: "durability", version: 2)
        let branch = try #require(publishedGuide.branches.first)
        // Index 1 is "install-deps", which version 3 does not have.
        await guideService.saveProgress(
            slug: "durability",
            version: 2,
            branch: branch,
            progress: GuideProgress(stepIndex: 1, isCompleted: false)
        )

        _ = try await guideService.fetchGuide(slug: "durability", version: 3)
        let progressAfterTheRewrite = await guideService.loadProgress(
            slug: "durability",
            version: 3,
            branchKey: branch.branchKey
        )
        #expect(progressAfterTheRewrite.stepIndex == 0)

        // A step that survived the rewrite still resumes, so "the ids moved" is
        // not a blanket reset of the whole guide.
        await guideService.saveProgress(
            slug: "durability",
            version: 2,
            branch: branch,
            progress: GuideProgress(stepIndex: 2, isCompleted: false)
        )
        let progressForASurvivingStep = await guideService.loadProgress(
            slug: "durability",
            version: 3,
            branchKey: branch.branchKey
        )
        #expect(progressForASurvivingStep.stepIndex == 2)
    }

    // MARK: - The readers already stranded

    /// The keys on the founder's Mac right now were written by a build that
    /// stored no step id at all, so they cannot be matched by id. They are still
    /// a reader's place and must be carried forward, and the orphans they left
    /// behind must not be left lying in storage.
    @Test func theVersionedKeysAlreadyOnDiskAreCarriedForwardAndCleanedUp() async throws {
        let (guideService, storage) = try Self.serviceAndStorage()

        // Exactly the shape `defaults read com.publikhq.iris` shows for cue.
        storage.set(
            ["step": 1, "completed": false, "updatedAt": 1_700_000_000.0] as [String: Any],
            forKey: "iris:progress:durability:v4:macos:desktop"
        )
        storage.set(
            ["step": 2, "completed": false, "updatedAt": 1_800_000_000.0] as [String: Any],
            forKey: "iris:progress:durability:v6:macos:desktop"
        )

        _ = try await guideService.fetchGuide(slug: "durability", version: 2)
        let carriedForward = await guideService.loadProgress(
            slug: "durability",
            version: 2,
            branchKey: "macos:desktop"
        )
        // The most recently written of the two, not the first one found.
        #expect(carriedForward.stepIndex == 2)

        let versionedKeysLeftBehind = storage.dictionaryRepresentation().keys.filter { key in
            key.hasPrefix("iris:progress:durability:v")
        }
        #expect(versionedKeysLeftBehind.isEmpty)
    }

    /// Two branches of one guide are two places, and a migration that collapsed
    /// them would resume the Android build into the iPhone one.
    @Test func carryingForwardKeepsEachBranchsPlaceSeparate() async throws {
        let (guideService, storage) = try Self.serviceAndStorage()

        storage.set(
            ["step": 3, "completed": false, "updatedAt": 1_800_000_000.0] as [String: Any],
            forKey: "iris:progress:durability:v6:macos:android"
        )
        _ = try await guideService.fetchGuide(slug: "durability", version: 2)

        let untouchedBranch = await guideService.loadProgress(
            slug: "durability",
            version: 2,
            branchKey: "macos:desktop"
        )
        #expect(untouchedBranch.stepIndex == 0)

        // And the branch that does have a place keeps it.
        let androidBranch = await guideService.loadProgress(
            slug: "durability",
            version: 2,
            branchKey: "macos:android"
        )
        #expect(androidBranch.stepIndex == 3)
    }

    /// The wreckage that is actually on the founder's Mac, transcribed verbatim
    /// from `defaults read com.publikhq.iris` — sixteen stranded keys covering
    /// nine places, several of them the same guide stranded three and four times
    /// over. Seeded rather than described so the cleanup is measured against the
    /// real data instead of against a tidy invention of it.
    ///
    /// Nothing here touches the founder's own storage: it is copied into an
    /// isolated suite. The rescue happens on their machine the first time the
    /// built app reads or writes progress.
    @Test func theRealStrandedKeysOnThisMacAreRescuedNotDeleted() async throws {
        let (guideService, storage) = try Self.serviceAndStorage()

        let strandedKeysOnTheFoundersMac: [(String, Int, Bool, Double)] = [
            ("iris:progress:cue:v4:macos:desktop", 10, true, 1_786_894_558.376483),
            ("iris:progress:cue:v6:macos:desktop", 10, false, 1_787_336_399.880415),
            ("iris:progress:hickeyfield:v1:macos:desktop", 13, false, 1_787_801_289.420329),
            ("iris:progress:lunara:v1:macos:ios", 13, false, 1_786_063_513.266515),
            ("iris:progress:lunara:v2:macos:ios", 14, true, 1_786_519_514.669912),
            ("iris:progress:nitroai:v2:macos:desktop", 0, false, 1_786_070_414.326983),
            ("iris:progress:nitroai:v3:macos:desktop", 9, true, 1_787_087_253.883315),
            ("iris:progress:nitroai:v4:macos:desktop", 6, false, 1_787_156_268.137815),
            ("iris:progress:nitroai:v5:macos:desktop", 10, true, 1_787_779_848.721606),
            ("iris:progress:oatmeal:v1:macos:desktop", 8, false, 1_786_842_417.589047),
            ("iris:progress:plantgpt:v1:macos:desktop", 6, true, 1_787_043_177.492387),
            ("iris:progress:simplicity:v3:macos:desktop", 11, true, 1_786_303_881.896111),
            ("iris:progress:simplicity:v4:macos:desktop", 7, false, 1_786_418_949.986402),
            ("iris:progress:simplicity:v6:macos:desktop", 7, false, 1_787_195_968.521313),
            ("iris:progress:voicestudio:v1:macos:desktop", 2, false, 1_787_801_153.223753),
            ("iris:progress:whimprflow:v7:macos:desktop", 15, true, 1_787_013_217.649085),
        ]
        for (strandedKey, step, completed, updatedAt) in strandedKeysOnTheFoundersMac {
            storage.set(
                ["step": step, "completed": completed, "updatedAt": updatedAt] as [String: Any],
                forKey: strandedKey
            )
        }

        // Opening ANY one guide rescues all of them, so a reader does not have
        // to walk back through nine installs to get their places back.
        _ = await guideService.loadProgress(
            slug: "cue",
            version: 7,
            branchKey: "macos:desktop"
        )

        // Every stranded key is gone. A stranded key is the four-part shape
        // (slug : v{n} : platform : target); the durable one has three parts,
        // and "voicestudio" starting with a v is exactly why this is counted
        // structurally rather than by searching for ":v".
        let strandedKeysLeft = storage.dictionaryRepresentation().keys.filter { key in
            guard key.hasPrefix("iris:progress:") else { return false }
            let keyParts = key.dropFirst("iris:progress:".count).split(separator: ":")
            return keyParts.count == 4
        }
        #expect(strandedKeysLeft.isEmpty, "still stranded: \(strandedKeysLeft.sorted())")

        // …and every place survived, at the step the READER was most recently
        // at, not at whichever version sorted first.
        let expectedPlaces: [(String, String, Int, Bool)] = [
            ("cue", "macos:desktop", 10, false),          // v6 is newer than v4
            ("hickeyfield", "macos:desktop", 13, false),
            ("lunara", "macos:ios", 14, true),            // v2 over v1
            ("nitroai", "macos:desktop", 10, true),       // v5 over v2, v3 and v4
            ("oatmeal", "macos:desktop", 8, false),
            ("plantgpt", "macos:desktop", 6, true),
            ("simplicity", "macos:desktop", 7, false),    // v6 over v3 and v4
            ("voicestudio", "macos:desktop", 2, false),
            ("whimprflow", "macos:desktop", 15, true),
        ]
        for (slug, branchKey, expectedStep, expectedCompletion) in expectedPlaces {
            // No guide is fetched for any of these, so no step ids can be
            // matched — which is the real situation for a record written before
            // ids were stored, and the reader keeps their place anyway.
            let rescued = await guideService.loadProgress(
                slug: slug,
                version: 99,
                branchKey: branchKey
            )
            #expect(rescued.stepIndex == expectedStep, "\(slug) lost its place")
            #expect(rescued.isCompleted == expectedCompletion, "\(slug) lost its completion")
        }
    }

    // MARK: - End to end, through the panel the reader actually uses

    /// The whole trip: open a guide, walk into it, publik republishes, reopen.
    /// This goes through `GuideSessionController.openGuide`, so it exercises the
    /// fetch, the handoff resolution, the reality check and the restore in the
    /// order the app runs them.
    @Test func reopeningAfterARepublishLandsOnTheStepTheReaderStoppedAt() async throws {
        let (guideService, _) = try Self.serviceAndStorage()
        let controller = GuideSessionController(guideService: guideService)

        await controller.openGuide(
            slug: "durability",
            requestedVersion: 2,
            branchKeyFromDeepLink: "macos:desktop",
            stepIndexFromDeepLink: nil
        )
        #expect(controller.loadState == .guideIsOpen)
        controller.advanceToTheNextStep()
        controller.advanceToTheNextStep()
        #expect(controller.currentStepIndex == 2)
        await controller.waitUntilProgressHasBeenPersisted()

        let controllerAfterTheRepublish = GuideSessionController(guideService: guideService)
        await controllerAfterTheRepublish.openGuide(
            slug: "durability",
            requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop",
            stepIndexFromDeepLink: nil
        )
        #expect(controllerAfterTheRepublish.loadState == .guideIsOpen)
        #expect(controllerAfterTheRepublish.currentStepIndex == 2)
        #expect(controllerAfterTheRepublish.stepTheReaderIsLookingAt?.id == "build")
    }
}

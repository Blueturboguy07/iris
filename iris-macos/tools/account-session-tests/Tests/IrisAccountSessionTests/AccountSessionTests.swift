import Foundation
import Security
import Testing
@testable import IrisAccountSession

@Suite(.serialized)
@MainActor
struct AccountSessionTests {
    @Test func aStoredRefreshTokenRestoresAfterAProcessRestart() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-on-disk")
        let firstLaunch = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(
                    statusCode: 200,
                    body: sessionBody(accessToken: "access-first", refreshToken: "refresh-rotated")
                )
            ]
        )

        await firstLaunch.service.restorePreviousSessionIfPossible(forceRetry: true)
        #expect(firstLaunch.service.signedInAccount?.emailAddress == "reader@example.test")
        #expect(storage.storedRefreshToken == "refresh-rotated")

        let secondLaunch = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(
                    statusCode: 200,
                    body: sessionBody(accessToken: "access-after-restart", refreshToken: "refresh-after-restart")
                )
            ]
        )
        await secondLaunch.service.restorePreviousSessionIfPossible(forceRetry: true)

        #expect(secondLaunch.service.signedInAccount?.emailAddress == "reader@example.test")
        #expect(secondLaunch.service.signInFailureMessage == nil)
        #expect(storage.storedRefreshToken == "refresh-after-restart")
    }

    @Test func aBlockedKeychainReadIsDistinctFromMissingAndCanBeRetried() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-kept")
        storage.readResult = .failure(.keychainOperationFailed(status: errSecInteractionNotAllowed))
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(statusCode: 200, body: sessionBody(refreshToken: "refresh-recovered"))
            ]
        )

        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)
        #expect(harness.service.signedInAccount == nil)
        #expect(harness.service.signInFailureMessage?.contains("cannot read") == true)
        #expect(harness.service.needsSavedLoginAuthorization)
        #expect(storage.reconnectCount == 0)
        #expect(storage.deleteCount == 0)
        #expect(storage.operations == ["read"])
        #expect(harness.sequence.requestCount == 0)

        storage.readResult = .success(storage.storedRefreshToken)
        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)
        #expect(harness.service.signedInAccount?.emailAddress == "reader@example.test")
        #expect(!harness.service.needsSavedLoginAuthorization)
        #expect(storage.operations == ["read", "read", "save"])
        #expect(harness.sequence.requestCount == 1)
    }

    @Test func retrySavedSessionActionUsesOneExplicitReconnectThenAProvenSilentRead() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-kept")
        storage.readResult = .failure(.keychainOperationFailed(status: errSecInteractionNotAllowed))
        storage.reconnectResult = .success("refresh-kept")
        storage.reconnectMakesReadable = true
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(statusCode: 200, body: sessionBody(refreshToken: "refresh-recovered"))
            ]
        )

        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)
        #expect(harness.service.signedInAccount == nil)
        #expect(storage.reconnectCount == 0)

        await harness.service.retrySavedSessionAction()

        #expect(harness.service.signedInAccount?.emailAddress == "reader@example.test")
        #expect(!harness.service.needsSavedLoginAuthorization)
        #expect(storage.reconnectCount == 1)
        #expect(harness.sequence.requestCount == 1)
        #expect(storage.storedRefreshToken == "refresh-recovered")
        #expect(Array(storage.operations.dropFirst(1).prefix(3)) == ["read", "reconnect", "read"])

        let secondLaunch = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(statusCode: 200, body: sessionBody(refreshToken: "refresh-after-restart"))
            ]
        )
        await secondLaunch.service.restorePreviousSessionIfPossible(forceRetry: true)
        #expect(secondLaunch.service.signedInAccount?.emailAddress == "reader@example.test")
        #expect(storage.storedRefreshToken == "refresh-after-restart")
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecUserCanceled])
    func anExplicitReconnectDenialPreservesAnExistingInMemorySession(status: OSStatus) async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-kept")
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(statusCode: 200, body: sessionBody(refreshToken: "refresh-kept"))
            ]
        )
        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)

        storage.readResult = .failure(.keychainOperationFailed(status: errSecInteractionNotAllowed))
        storage.reconnectResult = .failure(.keychainOperationFailed(status: status))

        #expect(await harness.service.reconnectSavedSession() == false)
        #expect(harness.service.signedInAccount != nil)
        #expect(await harness.service.currentAccessTokenRefreshingIfNeeded() == "access-fixture")
        #expect(harness.service.needsSavedLoginAuthorization)
        #expect(storage.reconnectCount == 1)
        #expect(storage.deleteCount == 0)
        #expect(Array(storage.operations.suffix(2)) == ["read", "reconnect"])
        #expect(harness.sequence.requestCount == 1)
    }

    @Test func anInteractiveSuccessIsNotEnoughWhenTheFollowUpSilentReadStillFails() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-kept")
        storage.readResult = .failure(.keychainOperationFailed(status: errSecInteractionNotAllowed))
        storage.reconnectResult = .success("refresh-returned-only-to-the-fixture")
        let harness = AccountTestHarness(storage: storage, responsePlans: [])

        #expect(await harness.service.reconnectSavedSession() == false)
        #expect(harness.service.signedInAccount == nil)
        #expect(harness.service.needsSavedLoginAuthorization)
        #expect(storage.reconnectCount == 1)
        #expect(storage.deleteCount == 0)
        #expect(storage.operations == ["read", "reconnect", "read"])
        #expect(harness.sequence.requestCount == 0)
    }

    @Test func aNewerUnsavedInMemoryRefreshTokenWinsDuringReconnectRetry() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-old-on-disk")
        storage.saveErrors = [SessionFixtureError.keychainWriteDenied]
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(
                    statusCode: 200,
                    body: sessionBody(accessToken: "access-newer", refreshToken: "refresh-newer")
                )
            ]
        )

        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)
        #expect(harness.service.signedInAccount != nil)
        #expect(harness.service.sessionPersistenceMessage != nil)
        #expect(storage.storedRefreshToken == "refresh-old-on-disk")

        storage.readResult = .failure(.keychainOperationFailed(status: errSecInteractionNotAllowed))
        storage.reconnectResult = .success("refresh-old-on-disk")
        storage.reconnectMakesReadable = true

        await harness.service.retrySavedSessionAction()

        #expect(harness.service.signedInAccount != nil)
        #expect(harness.service.sessionPersistenceMessage == nil)
        #expect(storage.storedRefreshToken == "refresh-newer")
        #expect(storage.reconnectCount == 1)
        #expect(Array(storage.operations.suffix(4)) == ["read", "reconnect", "read", "save"])
        #expect(harness.sequence.requestCount == 1)
    }

    @Test func anExplicitSignOutCannotBeRevivedBySavedSessionReconnect() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-before-signout")
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(statusCode: 200, body: sessionBody(refreshToken: "refresh-live"))
            ]
        )
        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)
        harness.service.signOut()

        storage.reconnectResult = .success("refresh-should-not-return")
        storage.reconnectMakesReadable = true

        #expect(await harness.service.reconnectSavedSession() == false)
        #expect(harness.service.signedInAccount == nil)
        #expect(storage.reconnectCount == 0)
        #expect(storage.operations == ["read", "save", "delete"])
        #expect(storage.deleteCount == 1)
        #expect(harness.sequence.requestCount == 1)
    }

    @Test func aReadableSavedSessionRetryDoesNotAskForAnotherReconnect() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-readable")
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(statusCode: 200, body: sessionBody(refreshToken: "refresh-readable"))
            ]
        )
        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)
        storage.reconnectResult = .failure(.keychainOperationFailed(status: errSecInteractionNotAllowed))

        await harness.service.retrySavedSessionAction()

        #expect(harness.service.signedInAccount != nil)
        #expect(storage.reconnectCount == 0)
        #expect(storage.operations == ["read", "save"])
        #expect(harness.sequence.requestCount == 1)
    }

    @Test func aFailedRotatedTokenSaveIsVisibleAndRetryable() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-old-on-disk")
        storage.saveErrors = [SessionFixtureError.keychainWriteDenied]
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(
                    statusCode: 200,
                    body: sessionBody(accessToken: "access-rotated", refreshToken: "refresh-rotated")
                ),
                .response(
                    statusCode: 200,
                    body: sessionBody(accessToken: "access-next", refreshToken: "refresh-next")
                )
            ]
        )

        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)
        #expect(harness.service.signedInAccount != nil)
        #expect(storage.storedRefreshToken == "refresh-old-on-disk")
        #expect(harness.service.sessionPersistenceMessage != nil)

        // If the service consulted disk again it would be unable to refresh.
        // The successful second refresh therefore proves it retained the
        // rotated token in memory after the failed save.
        storage.readResult = .failure(.keychainOperationFailed(status: errSecInteractionNotAllowed))
        await harness.service.handleAccessTokenRejectedByServer()
        #expect(harness.service.signedInAccount != nil)
        #expect(storage.storedRefreshToken == "refresh-next")
        #expect(harness.service.sessionPersistenceMessage == nil)
        #expect(harness.sequence.requestCount == 2)
    }

    @Test func anExplicitSignInSaveFailureCanBeRetriedWithoutAnotherAuthRequest() async throws {
        let storage = InMemorySessionStorage()
        storage.saveErrors = [SessionFixtureError.keychainWriteDenied]
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(
                    statusCode: 200,
                    body: sessionBody(accessToken: "access-explicit", refreshToken: "refresh-explicit")
                )
            ]
        )

        await harness.service.signIn(withEmailAddress: "reader@example.test", password: "fixture-password")
        #expect(harness.service.signedInAccount?.emailAddress == "reader@example.test")
        #expect(storage.storedRefreshToken == nil)
        #expect(harness.service.sessionPersistenceMessage != nil)
        #expect(harness.sequence.requestCount == 1)

        storage.saveErrors.removeAll()
        harness.service.retrySavingCurrentSession()
        #expect(storage.storedRefreshToken == "refresh-explicit")
        #expect(harness.service.sessionPersistenceMessage == nil)
        #expect(harness.sequence.requestCount == 1)
    }

    @Test func anOfflineRefreshAfterA401KeepsTheSavedSession() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-kept")
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(statusCode: 200, body: sessionBody(accessToken: "access-live", refreshToken: "refresh-kept")),
                .offline(),
            ]
        )

        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)
        await harness.service.handleAccessTokenRejectedByServer()

        #expect(harness.service.signedInAccount != nil)
        #expect(storage.storedRefreshToken == "refresh-kept")
        #expect(storage.deleteCount == 0)
        #expect(harness.service.signInFailureMessage?.contains("saved login was kept") == true)
    }

    @Test(arguments: [
        (429, "rate_limit"),
        (500, nil),
        (400, nil),
        (401, "unknown_error"),
        (403, "access_denied"),
    ])
    func temporaryOrUnknownRefreshFailuresNeverDeleteTheSavedToken(
        statusCode: Int,
        errorCode: String?
    ) async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-kept")
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(statusCode: statusCode, body: authFailureBody(code: errorCode))
            ]
        )

        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)

        #expect(harness.service.signedInAccount == nil)
        #expect(storage.storedRefreshToken == "refresh-kept")
        #expect(storage.deleteCount == 0)
        #expect(harness.service.signInFailureMessage != nil)
    }

    @Test(arguments: [
        (400, "refresh_token_not_found"),
        (401, "refresh_token_already_used"),
        (403, "user_banned"),
    ])
    func onlyKnownInvalidSessionCodesClearTheSavedToken(statusCode: Int, errorCode: String) async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-revoked")
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(statusCode: statusCode, body: authFailureBody(code: errorCode))
            ]
        )

        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)

        #expect(harness.service.signedInAccount == nil)
        #expect(storage.storedRefreshToken == nil)
        #expect(storage.deleteCount == 1)
        #expect(harness.service.signInFailureMessage == "Your saved session has expired or was revoked. Sign in again.")
    }

    @Test func concurrentRefreshesShareOneNetworkRequest() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-single-flight")
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(
                    statusCode: 200,
                    body: sessionBody(accessToken: "access-single-flight", refreshToken: "refresh-single-flight"),
                    gateID: 1
                )
            ]
        )

        let first = Task { await harness.service.currentAccessTokenRefreshingIfNeeded() }
        try await harness.sequence.waitForRequestCount(1)
        let second = Task { await harness.service.currentAccessTokenRefreshingIfNeeded() }
        await Task.yield()
        #expect(harness.sequence.requestCount == 1)

        harness.sequence.release(gateID: 1)
        #expect(await first.value == "access-single-flight")
        #expect(await second.value == "access-single-flight")
        #expect(harness.sequence.requestCount == 1)
    }

    @Test func aLateRefreshCannotUndoAnExplicitSignOut() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-before-signout")
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(
                    statusCode: 200,
                    body: sessionBody(accessToken: "access-late", refreshToken: "refresh-late"),
                    gateID: 1
                )
            ]
        )

        let refresh = Task { await harness.service.currentAccessTokenRefreshingIfNeeded() }
        try await harness.sequence.waitForRequestCount(1)
        harness.service.signOut()
        harness.sequence.release(gateID: 1)

        #expect(await refresh.value == nil)
        #expect(harness.service.signedInAccount == nil)
        #expect(storage.deleteCount == 1)
        #expect(storage.storedRefreshToken == nil)
    }

    @Test func aLateRefreshCannotOverwriteANewSignIn() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-old")
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(
                    statusCode: 200,
                    body: sessionBody(accessToken: "access-old", refreshToken: "refresh-old-rotated", emailAddress: "old@example.test"),
                    gateID: 1
                ),
                .response(
                    statusCode: 200,
                    body: sessionBody(accessToken: "access-new", refreshToken: "refresh-new", emailAddress: "new@example.test"),
                    gateID: 2
                ),
            ]
        )

        let oldRefresh = Task { await harness.service.currentAccessTokenRefreshingIfNeeded() }
        try await harness.sequence.waitForRequestCount(1)
        let newSignIn = Task {
            await harness.service.signIn(withEmailAddress: "new@example.test", password: "fixture-password")
        }
        try await harness.sequence.waitForRequestCount(2)
        harness.sequence.release(gateID: 1)
        harness.sequence.release(gateID: 2)

        _ = await oldRefresh.value
        await newSignIn.value

        #expect(harness.service.signedInAccount?.emailAddress == "new@example.test")
        #expect(storage.storedRefreshToken == "refresh-new")
        #expect(storage.deleteCount == 0)
    }

    @Test func aFailedSignOutDeleteIsVisibleAndDoesNotAutoRestore() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-delete-failure")
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(statusCode: 200, body: sessionBody(refreshToken: "refresh-delete-failure")),
                .response(statusCode: 200, body: sessionBody(refreshToken: "refresh-should-not-be-used")),
            ]
        )
        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)

        storage.deleteError = SessionFixtureError.keychainDeleteDenied
        harness.service.signOut()
        #expect(harness.service.signedInAccount == nil)
        #expect(harness.service.sessionPersistenceMessage?.contains("could not remove") == true)

        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)
        #expect(harness.sequence.requestCount == 1)
        #expect(storage.storedRefreshToken == "refresh-delete-failure")

        await harness.service.retrySavedSessionAction()
        #expect(storage.deleteCount == 2)
    }

    @Test func launchRestoreIsThrottledUntilAnExplicitRetry() async throws {
        let storage = InMemorySessionStorage(refreshToken: "refresh-throttled")
        let harness = AccountTestHarness(
            storage: storage,
            responsePlans: [
                .response(statusCode: 500, body: authFailureBody()),
                .response(statusCode: 200, body: sessionBody(refreshToken: "refresh-after-retry")),
            ]
        )

        await harness.service.restorePreviousSessionIfPossible()
        await harness.service.restorePreviousSessionIfPossible()
        #expect(harness.sequence.requestCount == 1)
        #expect(harness.service.signedInAccount == nil)

        await harness.service.restorePreviousSessionIfPossible(forceRetry: true)
        #expect(harness.sequence.requestCount == 2)
        #expect(harness.service.signedInAccount?.emailAddress == "reader@example.test")
    }

    @Test func keychainUpdateOrAddOnlyAddsWhenTheItemIsMissing() {
        var attemptedAdd = false
        let deniedStatus = KeychainReadPolicy.updateOrAdd(update: { errSecInteractionNotAllowed }, add: {
            attemptedAdd = true
            return errSecSuccess
        })
        #expect(!attemptedAdd)
        #expect(deniedStatus == errSecInteractionNotAllowed)

        let missingStatus = KeychainReadPolicy.updateOrAdd(update: { errSecItemNotFound }, add: {
            attemptedAdd = true
            return errSecSuccess
        })
        #expect(attemptedAdd)
        #expect(missingStatus == errSecSuccess)
    }
}

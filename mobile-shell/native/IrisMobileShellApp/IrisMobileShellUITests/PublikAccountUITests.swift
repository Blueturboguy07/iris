import XCTest

// Uses only PUBLIC_CONTRACT.md arguments/identifiers and SPEC.md expected visible facts.
// No real authentication, checkout, deletion, credentials or production storage are used.
@MainActor
final class PublikAccountUITests: XCTestCase {
    private var app: XCUIApplication!
    private let root = "iris.publik-api."

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ fixture: String, region: String = "USA", entry: String = "overview",
                        auth: String = "success", browser: String = "success", date: String = "2026-09-30",
                        eligibility: String = "eligible") {
        app = XCUIApplication()
        app.launchArguments = ["--iris-publik-api-test-mode", "--iris-publik-api-fixture", fixture,
            "--iris-publik-api-storefront", region, "--iris-publik-api-entry", entry,
            "--iris-publik-api-auth-result", auth, "--iris-publik-api-browser-result", browser,
            "--iris-publik-api-policy-date", date, "--iris-publik-api-eligibility", eligibility]
        app.launch()
    }

    private func element(_ suffix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: root + suffix).firstMatch
    }

    private func present(_ suffix: String, _ spec: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(suffix)
        XCTAssertTrue(target.waitForExistence(timeout: 5), spec, file: file, line: line)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: root + suffix).count, 1,
                       "SPEC.md:112 PA-100: unique visible identifier; " + spec, file: file, line: line)
        return target
    }

    private func text(_ suffix: String, contains expected: String, _ spec: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        let target = present(suffix, spec, file: file, line: line)
        let matches = NSPredicate { _, _ in
            (target.label + " " + (target.value as? String ?? "")).contains(expected)
        }
        let ready = XCTNSPredicateExpectation(predicate: matches, object: nil)
        ready.expectationDescription = spec
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, spec, file: file, line: line)
    }

    private func tap(_ suffix: String, _ spec: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = present(suffix, spec, file: file, line: line)
        XCTAssertTrue(target.isEnabled, spec, file: file, line: line)
        XCTAssertTrue(target.isHittable, spec, file: file, line: line)
        target.tap()
    }

    private func absent(_ suffix: String, _ spec: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(element(suffix).exists, spec, file: file, line: line)
    }

    private func balanceMoney(_ digits: String, spoken: String, _ spec: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let amount = present("balance.amount", spec, file: file, line: line)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let content = amount.label + " " + (amount.value as? String ?? "")
            return content.contains(digits) || content.contains(spoken)
        }, object: nil)
        ready.expectationDescription = spec
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, spec, file: file, line: line)
    }

    private func noPurchase(_ spec: String = "SPEC.md:80 PA-036: purchase absent from accessibility tree") {
        absent("balance.buy-credit", spec)
        absent("balance.browser-note", spec)
        for phrase in ["Buy credit", "Add credit", "Top up", "Visit the website", "Manage account", "Learn more", "View plans"] {
            XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", phrase)).count, 0,
                           "SPEC.md:80 PA-036: no disguised promotion: " + phrase)
        }
    }

    func testFirstTimePersonFindsNativeAccountBeforeAuthentication() {
        launch("signed-out", entry: "browse")
        let entry = app.descendants(matching: .any).matching(identifier: "iris.store.publik-api.entry").firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "SPEC.md:21 PA-010: visible account entry")
        XCTAssertTrue(entry.isHittable, "SPEC.md:21 PA-010: entry visible without scrolling")
        XCTAssertTrue(entry.label.contains("Publik API"), "SPEC.md:21 PA-010: human account label")
        XCTAssertTrue(entry.label.contains("Sign in to view your balance and usage."), "SPEC.md:21 PA-010: neutral signed-out subtitle")
        XCTAssertGreaterThanOrEqual(entry.frame.width, 44, "SPEC.md:21 PA-010: row target width")
        XCTAssertGreaterThanOrEqual(entry.frame.height, 60, "SPEC.md:21 PA-010: full row touch target")
        entry.tap()
        text("overview.title", contains: "Publik API", "SPEC.md:117 PA-102: native overview title")
        text("overview.description", contains: "View your Publik account, credit balance and API usage.", "SPEC.md:117 PA-102: plain explanation")
        let signIn = present("overview.sign-in", "SPEC.md:23 PA-011: second tap starts sign-in")
        XCTAssertEqual(signIn.label, "Sign in to Publik", "SPEC.md:117 PA-102: human sign-in label")
        absent("overview.identity", "SPEC.md:31 PA-021: no identity before authentication")
        absent("overview.balance", "SPEC.md:31 PA-021: no balance before authentication")
        noPurchase()
        signIn.tap()
        text("overview.status", contains: "Signed in to Publik.", "SPEC.md:31 PA-021: successful outcome")
        text("overview.identity", contains: "Avery Example", "SPEC.md:167 PA-073: authenticated synthetic identity")
        tap("overview.balance", "SPEC.md:23 PA-011: two-tap balance path")
        balanceMoney("$12.34 USD", spoken: "12 dollars and 34 cents, US dollars", "SPEC.md:43 PA-026 and SPEC.md:98 PA-044: exact supplied balance")
    }

    func testSignInCancelledLeavesEnabledRetryAndNoPrivateFacts() {
        launch("signed-out", auth: "cancel")
        tap("overview.sign-in", "SPEC.md:31 PA-021: deliberate authentication")
        text("overview.status", contains: "Sign-in cancelled.", "SPEC.md:31 PA-021: cancellation outcome")
        XCTAssertTrue(present("overview.sign-in", "SPEC.md:31 PA-021: retry exists").isEnabled, "SPEC.md:31 PA-021: retry enabled")
        absent("overview.identity", "SPEC.md:31 PA-021: cancellation has no identity")
        noPurchase()
    }

    func testFailedSignInShowsSafeErrorAndRetry() {
        launch("signed-out", auth: "failure")
        tap("overview.sign-in", "SPEC.md:31 PA-021: deliberate authentication")
        text("overview.status", contains: "Couldn't sign in. Try again.", "SPEC.md:31 PA-021: sanitized failure")
        XCTAssertTrue(present("overview.sign-in", "SPEC.md:31 PA-021: retry exists").isEnabled, "SPEC.md:31 PA-021: retry enabled")
        absent("overview.identity", "SPEC.md:31 PA-021: failed exchange has no identity")
    }

    func testZeroCreditPersonInUSASeesBrowserActionAndSafeOpenFailure() {
        launch("zero-balance", entry: "balance", browser: "failure")
        text("balance.note", contains: "No credit available", "SPEC.md:45 PA-027: confirmed zero")
        balanceMoney("$0.00 USD", spoken: "0 dollars and 0 cents, US dollars", "SPEC.md:43 PA-026: exact zero amount")
        let buy = present("balance.buy-credit", "SPEC.md:76 PA-034: eligible credit button")
        XCTAssertEqual(buy.label, "Buy credit on publikhq.com", "SPEC.md:76 PA-034: truthful browser label")
        text("balance.browser-note", contains: "Opens publikhq.com in your browser.", "SPEC.md:76 PA-034: neutral browser helper")
        XCTAssertGreaterThanOrEqual(buy.frame.width, 96, "SPEC.md:100 PA-045: long capsule width")
        XCTAssertGreaterThanOrEqual(buy.frame.height, 44, "SPEC.md:100 PA-045: accessible touch height")
        buy.tap()
        text("balance.status", contains: "Couldn't open publikhq.com. Try again.", "SPEC.md:78 PA-035: safe browser failure")
        text("balance.note", contains: "No credit available", "SPEC.md:78 PA-035: failed open never credits wallet")
        XCTAssertTrue(present("balance.buy-credit", "SPEC.md:78 PA-035: retry purchase").isEnabled, "SPEC.md:78 PA-035: failed open permits deliberate retry")
    }

    func testSuccessfulCapturedBrowserOpenDoesNotInventPayment() {
        launch("zero-balance", entry: "balance")
        tap("balance.buy-credit", "SPEC.md:78 PA-035: one deliberate captured open")
        text("balance.note", contains: "No credit available", "SPEC.md:78 PA-035: browser launch is not payment proof")
        tap("balance.refresh", "SPEC.md:78 PA-035: explicit account refresh after unchanged checkout")
        text("balance.note", contains: "No credit available", "SPEC.md:78 PA-035: fresh unchanged balance valid")
    }

    func testRestrictedAndUnknownStorefrontsKeepFactsWithoutAnyPromotion() {
        for fixture in ["signed-in-balance", "zero-balance"] {
            for region in ["DEU", "FRA", "JPN", "BRA", "KOR", "NLD", "NOR", "ISL", "RUS", "GBR", "CAN", "UNKNOWN"] {
                launch(fixture, region: region, entry: "balance")
                _ = present("balance.amount", "SPEC.md:59 PA-033: neutral balance remains in " + region)
                noPurchase()
                if fixture == "zero-balance" {
                    text("balance.note", contains: "No credit available", "SPEC.md:80 PA-036: restricted zero stays factual")
                }
                app.terminate()
            }
        }
    }

    func testEUOctoberTransitionDoesNotEnableWebsiteOnlyPurchases() {
        for date in ["2026-09-30", "2026-10-01"] {
            for region in ["DEU", "FRA", "NLD"] {
                launch("zero-balance", region: region, entry: "balance", date: date)
                _ = present("balance.amount", "SPEC.md:190 PA-075: neutral EU account")
                noPurchase("SPEC.md:84 PA-038 and SPEC.md:190 PA-075: neither EU date enables website-only route")
                app.terminate()
            }
        }
    }

    func testUSUnknownOrBlockedEligibilityHidesEvenZeroBalancePromotion() {
        for eligibility in ["payment-blocked", "age-unknown", "minor", "policy-stale", "offer-unverified", "offer-expired"] {
            launch("zero-balance", entry: "balance", eligibility: eligibility)
            text("balance.note", contains: "No credit available", "SPEC.md:169 PA-074: no invented top-up on zero")
            noPurchase("SPEC.md:55 PA-031 and SPEC.md:190 PA-075: failed eligibility hides all promotion")
            app.terminate()
        }
    }

    func testFourNativePagesAndBackPaths() {
        launch("signed-in-balance")
        tap("overview.account", "SPEC.md:23 PA-011: account path")
        text("account.name", contains: "Avery Example", "SPEC.md:167 PA-073: server name")
        text("account.email", contains: "avery@example.invalid", "SPEC.md:167 PA-073: server email")
        text("account.privacy", contains: "Iris stores your sign-in securely on this iPhone. API usage comes from your Publik account.", "SPEC.md:39 PA-025: native privacy everywhere")
        tap("account.back", "SPEC.md:23 PA-011: back to overview")
        tap("overview.balance", "SPEC.md:23 PA-011: balance path")
        tap("balance.history", "SPEC.md:23 PA-011: history path")
        text("history.row.t001", contains: "Synthetic credit entry", "SPEC.md:167 PA-073: factual transaction")
        tap("history.back", "SPEC.md:23 PA-011: back to balance")
        _ = present("balance.screen", "SPEC.md:23 PA-011: history back preserves balance page")
        tap("balance.back", "SPEC.md:23 PA-011: back to overview")
        tap("overview.usage", "SPEC.md:23 PA-011: usage path")
        text("usage.range", contains: "UTC", "SPEC.md:47 PA-028: exact timezone disclosed")
        text("usage.row.u001", contains: "Nut AI", "SPEC.md:167 PA-073: app name shown")
        text("usage.row.u001", contains: "Fixture balanced model", "SPEC.md:47 PA-028: served model shown")
        tap("usage.period.thirty-days", "SPEC.md:47 PA-028: choose thirty days")
        text("usage.row.u003", contains: "Nut AI", "SPEC.md:167 PA-073: older request appears in thirty-day window")
        tap("usage.back", "SPEC.md:23 PA-011: return overview")
        _ = present("overview.screen", "SPEC.md:23 PA-011: previous native page")
    }

    func testBalanceComponentsAreFactualAndMissingPlanDetailsStayAbsent() {
        launch("signed-in-balance", entry: "balance")
        balanceMoney("$12.34 USD", spoken: "12 dollars and 34 cents, US dollars", "SPEC.md:43 PA-026: server authoritative total")
        text("balance.component.plan", contains: "$2.34 USD", "SPEC.md:167 PA-073: explicit synthetic plan component")
        text("balance.component.pack", contains: "$10.00 USD", "SPEC.md:167 PA-073: explicit synthetic pack component")
        absent("balance.component.free", "SPEC.md:45 PA-027: no invented free grant")
        absent("balance.plan", "SPEC.md:45 PA-027: no invented subscription")
        absent("balance.reset", "SPEC.md:45 PA-027: no invented reset")
        absent("balance.budget", "SPEC.md:45 PA-027: no invented budget")
    }

    func testOfflineSignOutCancelThenConfirm() {
        launch("offline", entry: "account")
        tap("account.sign-out", "SPEC.md:37 PA-024: offline sign-out available")
        text("sign-out.title", contains: "Sign out of Publik?", "SPEC.md:37 PA-024: named confirmation")
        text("sign-out.message", contains: "Your installed apps and their saved data stay on this iPhone.", "SPEC.md:37 PA-024: preserves app data")
        tap("sign-out.cancel", "SPEC.md:37 PA-024: cancel changes nothing")
        text("account.email", contains: "avery@example.invalid", "SPEC.md:37 PA-024: account preserved after cancel")
        tap("account.sign-out", "SPEC.md:37 PA-024: deliberate retry")
        tap("sign-out.confirm", "SPEC.md:37 PA-024: confirm local removal while offline")
        text("overview.status", contains: "Signed out.", "SPEC.md:37 PA-024: confirmed local outcome")
        absent("overview.identity", "SPEC.md:37 PA-024: private facts removed")
        noPurchase()
    }

    func testDeletionCancelAndUnsupportedFlowNeverClaimsSuccess() {
        launch("signed-in-balance", region: "GBR", entry: "account")
        tap("account.delete", "SPEC.md:39 PA-025: deletion initiated inside Iris")
        text("delete.message", contains: "avery@example.invalid", "SPEC.md:125 PA-110: named account in confirmation")
        text("delete.message", contains: "across Publik", "SPEC.md:125 PA-110: explains global account effect")
        tap("delete.cancel", "SPEC.md:39 PA-025: safe cancellation")
        text("account.email", contains: "avery@example.invalid", "SPEC.md:39 PA-025: cancel retains account")
        tap("account.delete", "SPEC.md:39 PA-025: explicit confirmed request")
        tap("delete.confirm", "SPEC.md:39 PA-025: confirmed fixture deletion")
        text("account.status", contains: "Account deletion is unavailable. Try again later.", "SPEC.md:39 PA-025: no fake acknowledgement")
        noPurchase()
    }

    func testExpiredSessionRedirectsProtectedEntryAndErasesFacts() {
        launch("expired-session", entry: "balance")
        text("overview.status", contains: "Your session expired. Sign in again.", "SPEC.md:35 PA-023: expired protected entry returns overview")
        _ = present("overview.sign-in", "SPEC.md:35 PA-023: retry means reauthentication")
        absent("overview.identity", "SPEC.md:35 PA-023: no identity")
        absent("balance.amount", "SPEC.md:35 PA-023: no stale amount")
        absent("account.email", "SPEC.md:35 PA-023: no stale email")
        noPurchase()
    }

    func testRefreshExpiryRemovesPreviouslyVisibleAccount() {
        launch("expire-on-refresh", entry: "overview")
        // Entry refresh may already trigger expiry. Do not require stale private facts to appear first.
        if element("overview.refresh").exists {
            tap("overview.refresh", "SPEC.md:35 PA-023: explicit expiry-triggering refresh")
        }
        text("overview.status", contains: "Your session expired. Sign in again.", "SPEC.md:169 PA-074: expiry on next refresh")
        absent("overview.identity", "SPEC.md:35 PA-023: erase old identity")
        absent("overview.balance", "SPEC.md:35 PA-023: erase old balance route")
        noPurchase()
    }

    func testOfflineSnapshotIsDatedAndColdOfflineHasNoInventedZero() {
        launch("offline", entry: "balance")
        text("balance.status", contains: "Offline. Showing your last update from Sep 29, 2026 at 12:00 UTC.", "SPEC.md:92 PA-041 and SPEC.md:169 PA-074: stale timestamp")
        _ = present("balance.amount", "SPEC.md:92 PA-041: retained safe snapshot")
        noPurchase()
        app.terminate()
        launch("offline-no-cache", entry: "balance")
        text("balance.status", contains: "Connect to the internet to load your balance.", "SPEC.md:92 PA-041: connection error without snapshot")
        absent("balance.amount", "SPEC.md:169 PA-074: no fabricated amount")
        noPurchase()
    }

    func testOfflineFirstTimePersonCannotStartAuthentication() {
        launch("offline-signed-out")
        text("overview.status", contains: "Connect to the internet to sign in.", "SPEC.md:92 PA-041: offline authentication explanation")
        XCTAssertFalse(present("overview.sign-in", "SPEC.md:92 PA-041: sign-in retained while disabled").isEnabled, "SPEC.md:92 PA-041: disabled offline sign-in")
        noPurchase()
    }

    func testServerAndMalformedErrorsAreSanitizedAndNeverPurchaseEligible() {
        for (fixture, expected) in [("server-error", "Publik is unavailable. Try again."),
                                     ("malformed-balance", "Couldn't read Publik account data. Try again.")] {
            launch(fixture, entry: "balance")
            // Entry performs refresh, otherwise explicit refresh triggers the scripted failure.
            if element("balance.refresh").isEnabled { tap("balance.refresh", "SPEC.md:94 PA-042: deliberate refresh") }
            text("balance.status", contains: expected, "SPEC.md:94 PA-042: sanitized protocol/service error")
            noPurchase()
            if fixture == "malformed-balance" {
                text("balance.note", contains: "Balance isn't available.", "SPEC.md:94 PA-042: invalid data is not zero")
            }
            app.terminate()
        }
    }

    func testRateLimitedRefreshIsDisabledWithoutLosingItsIdentifier() {
        launch("rate-limited", entry: "balance")
        if element("balance.refresh").isEnabled { tap("balance.refresh", "SPEC.md:94 PA-042: trigger rate limit") }
        text("balance.status", contains: "Too many requests. Try again later.", "SPEC.md:94 PA-042: safe 429 copy")
        XCTAssertFalse(present("balance.refresh", "SPEC.md:96 PA-043: disabled refresh stays addressable").isEnabled, "SPEC.md:94 PA-042: verified retry interval honored")
        noPurchase()
    }

    func testEmptyHistoryAndUnavailableHistoryAreNotInterchangeable() {
        launch("empty-usage", entry: "usage")
        text("usage.empty", contains: "No API usage in this period.", "SPEC.md:47 PA-028: confirmed empty")
        text("usage.total", contains: "0", "SPEC.md:169 PA-074: confirmed zero server total")
        app.terminate()
        launch("unavailable-details", entry: "usage")
        text("usage.empty", contains: "Usage details aren't available.", "SPEC.md:47 PA-028: unavailable is not empty")
        XCTAssertFalse(element("usage.total").label.contains("$0.00"), "SPEC.md:47 PA-028: unsupported total is not zero")
        tap("usage.back", "SPEC.md:23 PA-011: return overview")
        tap("overview.balance", "SPEC.md:94 PA-042: verified balance remains available")
        tap("balance.history", "SPEC.md:23 PA-011: navigate credit history")
        text("history.empty", contains: "Credit history isn't available.", "SPEC.md:49 PA-029: unsupported history distinct")
    }

    func testPagedUsageShowsUniqueRowsAndUnchangedServerTotal() {
        launch("paged-usage", entry: "usage")
        text("usage.total", contains: "0.011", "SPEC.md:167 PA-073: authoritative total, not first page sum")
        tap("usage.more", "SPEC.md:47 PA-028: explicit next cursor page")
        _ = present("usage.row.u002", "SPEC.md:169 PA-074: second page visible")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: root + "usage.row.u001").count, 1, "SPEC.md:47 PA-028: duplicate stable row suppressed")
        text("usage.total", contains: "0.011", "SPEC.md:47 PA-028: total remains server total")
        absent("usage.more", "SPEC.md:169 PA-074: no more without cursor")
    }

    func testAccountSwitchShowsOnlyTheNewPersonsFacts() {
        launch("account-switch", entry: "account")
        tap("account.sign-out", "SPEC.md:37 PA-024: explicit switch begins with sign-out")
        tap("sign-out.confirm", "SPEC.md:37 PA-024: confirm local clearing")
        tap("overview.sign-in", "SPEC.md:169 PA-074: new account sign-in")
        text("overview.identity", contains: "Morgan Example", "SPEC.md:169 PA-074: B identity only")
        XCTAssertFalse(element("overview.identity").label.contains("Avery"), "SPEC.md:37 PA-024: A private identity erased")
        tap("overview.balance", "SPEC.md:23 PA-011: new account balance")
        balanceMoney("$7.00 USD", spoken: "7 dollars and 0 cents, US dollars", "SPEC.md:43 PA-026 and SPEC.md:169 PA-074: exact B balance")
    }

    func testSubCentBalanceKeepsExactVoiceOverValue() {
        launch("sub-cent-balance", entry: "balance")
        text("balance.amount", contains: "0.004", "SPEC.md:43 PA-026 and SPEC.md:98 PA-044: no rounding or zeroing")
        text("balance.amount", contains: "US dollars", "SPEC.md:98 PA-044: currency spoken explicitly")
    }
}

//
//  PublikConsentStoreTests.swift
//  leanring-buddyTests
//
//  consent.json is shared with every catalog app, and crash telemetry's
//  switch in it is opt-in. Adding the usage switch must not flip, drop or
//  reset anything that was already there.
//

import Foundation
import Testing
@testable import Iris

@Suite("publik consent file")
struct PublikConsentStoreTests {

    private func scratchFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-consent-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("consent.json")
    }

    private func readBack(_ fileURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func nothingIsSharedBeforeTheDisclosureHasBeenShown() {
        let store = PublikConsentStore(fileURL: scratchFileURL())
        #expect(store.usageSharingState == .notYetDisclosed)
        #expect(!store.isUsageSharingOn)
        #expect(!store.usageDisclosureHasBeenShown)
    }

    @Test func showingTheDisclosureTurnsTheDefaultOnAndWritesTelemetryAsOff() throws {
        let fileURL = scratchFileURL()
        let store = PublikConsentStore(fileURL: fileURL)
        store.recordThatTheUsageDisclosureWasShown()
        #expect(store.usageSharingState == .sharing)
        #expect(!store.readerHasAnsweredTheUsageDisclosure, "the card stays until a button is pressed")

        let written = try readBack(fileURL)
        #expect(written["usage"] as? Bool == true)
        #expect(written["telemetry"] as? Bool == false, "crash telemetry stays opt-in")
        #expect(UUID(uuidString: try #require(written["install_id"] as? String)) != nil)
        #expect(written["usage_disclosed_at"] is String)
    }

    @Test func turningItOffIsRememberedAcrossLaunches() {
        let fileURL = scratchFileURL()
        let store = PublikConsentStore(fileURL: fileURL)
        store.recordThatTheUsageDisclosureWasShown()
        store.recordUsageSharingChoice(isOn: false)

        let relaunched = PublikConsentStore(fileURL: fileURL)
        #expect(relaunched.usageSharingState == .notSharing)
        #expect(relaunched.readerHasAnsweredTheUsageDisclosure)
        // A second "shown" must not switch it back on.
        relaunched.recordThatTheUsageDisclosureWasShown()
        #expect(relaunched.usageSharingState == .notSharing)
    }

    @Test func anExistingTelemetryChoiceAndUnknownKeysSurviveEveryWrite() throws {
        let fileURL = scratchFileURL()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "telemetry": true,
            "install_id": "3f1b2c4d-1111-2222-3333-abcdefabcdef",
            "updated_at": "2026-08-02T04:00:00Z",
            "some_other_client_key": "keep me",
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: fileURL)

        let store = PublikConsentStore(fileURL: fileURL)
        #expect(store.installIdentifier() == "3f1b2c4d-1111-2222-3333-abcdefabcdef")
        store.recordThatTheUsageDisclosureWasShown()
        store.recordUsageSharingChoice(isOn: false)

        let written = try readBack(fileURL)
        #expect(written["telemetry"] as? Bool == true)
        #expect(written["install_id"] as? String == "3f1b2c4d-1111-2222-3333-abcdefabcdef")
        #expect(written["some_other_client_key"] as? String == "keep me")
        #expect(written["usage"] as? Bool == false)
    }

    @Test func theInstallIdentifierIsMintedOnceAndKept() {
        let fileURL = scratchFileURL()
        let first = PublikConsentStore(fileURL: fileURL).installIdentifier()
        let second = PublikConsentStore(fileURL: fileURL).installIdentifier()
        #expect(first == second)
        #expect(UUID(uuidString: first) != nil)
    }

    @Test func aCorruptFileReadsAsNotYetAsked() throws {
        let fileURL = scratchFileURL()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: fileURL)
        let store = PublikConsentStore(fileURL: fileURL)
        #expect(store.usageSharingState == .notYetDisclosed)
        #expect(!store.crashTelemetryIsOn)
    }
}

import Foundation
import CoreGraphics
import Testing
#if canImport(Iris)
@testable import Iris
#else
@testable import IrisUsability
#endif

@MainActor
struct SettingsPanelBehaviorTests {
    @Test func settingsPagesStayInTheCompactNavigationOrder() {
        #expect(SettingsPanelRouting.Page.allCases.map(\.rawValue)
            == ["General", "Connections", "Apps"])
    }

    @Test func settingsCommandReusesTheVisiblePanelInsteadOfDuplicatingIt() {
        #expect(SettingsPanelRouting.action(
            for: .show, panelExists: true, panelIsVisible: true
        ) == .showExisting)
    }

    @Test func reopeningSettingsReusesTheHiddenPanel() {
        #expect(SettingsPanelRouting.action(
            for: .show, panelExists: true, panelIsVisible: false
        ) == .showExisting)
    }

    @Test func eyeAndMenuToggleHideTheSameVisiblePanel() {
        #expect(SettingsPanelRouting.action(
            for: .toggle, panelExists: true, panelIsVisible: true
        ) == .hideExisting)
        #expect(SettingsPanelRouting.action(
            for: .toggle, panelExists: true, panelIsVisible: false
        ) == .showExisting)
    }

    @Test func onlyTheFirstSettingsRequestCreatesAPanel() {
        #expect(SettingsPanelRouting.action(
            for: .show, panelExists: false, panelIsVisible: false
        ) == .createAndShow)
        #expect(SettingsPanelRouting.action(
            for: .toggle, panelExists: false, panelIsVisible: false
        ) == .createAndShow)
    }

    @Test func twoHundredDragEventsYieldOnlyTheSettledPlacement() {
        var updates = SettingsPanelPlacementUpdates()
        for offset in 0..<200 {
            updates.recordMove(to: CGPoint(x: offset, y: offset), isProgrammatic: false)
        }
        let settledUpdate = updates.takeSettledUpdate()
        #expect(settledUpdate.origin == CGPoint(x: 199, y: 199))
        #expect(settledUpdate.size == nil)
        #expect(updates.takeSettledUpdate().origin == nil)
    }

    @Test func automaticLayoutDoesNotBecomeAUserPlacement() {
        var updates = SettingsPanelPlacementUpdates()
        updates.recordMove(to: CGPoint(x: 400, y: 400), isProgrammatic: true)
        updates.recordResize(
            to: CGSize(width: 420, height: 600), origin: CGPoint(x: 300, y: 300),
            isProgrammatic: true
        )
        let settledUpdate = updates.takeSettledUpdate()
        #expect(settledUpdate.origin == nil)
        #expect(settledUpdate.size == nil)
    }

    @Test func resizeAndMoveAreSavedTogetherWithoutLosingTheLastOrigin() {
        var updates = SettingsPanelPlacementUpdates()
        updates.recordResize(
            to: CGSize(width: 500, height: 650), origin: CGPoint(x: 300, y: 300),
            isProgrammatic: false
        )
        updates.recordMove(to: CGPoint(x: 350, y: 325), isProgrammatic: false)
        let settledUpdate = updates.takeSettledUpdate()
        #expect(settledUpdate.origin == CGPoint(x: 350, y: 325))
        #expect(settledUpdate.size == CGSize(width: 500, height: 650))
    }

    @Test func placementPersistsInAnIsolatedDefaultsSuite() throws {
        let suiteName = "iris-settings-placement-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let placement = MenuBarPanelPlacement(userDefaults: defaults)
        #expect(!placement.readerHasPlacedItThemselves)
        placement.remember(origin: CGPoint(x: 80, y: 100))
        placement.remember(size: CGSize(width: 320, height: 600))
        let reopened = MenuBarPanelPlacement(userDefaults: defaults)
        #expect(reopened.storedOrigin == CGPoint(x: 80, y: 100))
        #expect(reopened.storedSize == CGSize(width: 376, height: 600))
        placement.remember(origin: CGPoint(x: CGFloat.infinity, y: 100))
        #expect(reopened.storedOrigin == CGPoint(x: 80, y: 100))
    }

    @Test func priorDefaultWidthMigratesOnceWithoutResettingPositionOrHeight() throws {
        let suiteName = "iris-settings-migration-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(420.0, forKey: "iris:panel:width")
        defaults.set(640.0, forKey: "iris:panel:height")
        defaults.set(80.0, forKey: "iris:panel:originX")
        defaults.set(90.0, forKey: "iris:panel:originY")
        let migrated = MenuBarPanelPlacement(userDefaults: defaults)
        #expect(migrated.storedSize == CGSize(width: 376, height: 640))
        #expect(migrated.storedOrigin == CGPoint(x: 80, y: 90))
        migrated.remember(size: CGSize(width: 420, height: 500))
        #expect(MenuBarPanelPlacement(userDefaults: defaults).storedSize
            == CGSize(width: 420, height: 500))
    }

    @Test func customWidthsDoNotMigrate() throws {
        let suiteName = "iris-settings-custom-width-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(510.0, forKey: "iris:panel:width")
        defaults.set(550.0, forKey: "iris:panel:height")
        #expect(MenuBarPanelPlacement(userDefaults: defaults).storedSize
            == CGSize(width: 510, height: 550))
    }

}

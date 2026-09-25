import CoreGraphics
import Foundation
import Testing
@testable import IrisLaunchSlice

struct LaunchSlicePolicyTests {
    @Test func accessibilityRepairCopyIsBoundedToMissingPermission() {
        #expect(AccessibilityPermissionRecovery.shouldShowRepairInstructions(isGranted: false))
        #expect(!AccessibilityPermissionRecovery.shouldShowRepairInstructions(isGranted: true))
        #expect(AccessibilityPermissionRecovery.repairInstructions.contains("minus"))
    }

    @Test func guideEvidenceAndFallbackStayConservative() throws {
        let valid = Data("""
        {"appSlug":"published-route","status":"approved","outputType":"desktop_app",
         "branches":[{"platform":"macos","target":null,"steps":[{"id":"install"}]}]}
        """.utf8)
        #expect(CatalogMacCompatibility.resolved(
            from: valid, expectedSlug: "published-route", fallback: .unknown
        ) == .desktopApp)
        #expect(CatalogMacCompatibility.resolved(
            from: valid, expectedSlug: "catalog-name", fallback: .localWebApp
        ) == .localWebApp)
        #expect(CatalogMacCompatibility.resolved(
            from: Data("not-json".utf8), expectedSlug: "published-route", fallback: .desktopApp
        ) == .desktopApp)
        #expect(CatalogMacCompatibility.resolved(
            from: nil, expectedSlug: "published-route", fallback: .localWebApp
        ) == .localWebApp)
    }

    @Test func iconPolicyRejectsUnsafeInputsAndBoundsBodies() {
        #expect(CatalogAppIconPolicy.verifiedAssets.count == 4)
        #expect(CatalogAppIconPolicy.verifiedIconURL(forSlug: "not-in-catalog") == nil)
        for candidate in [
            "http://publikhq.com/icon.png", "https://publikhq.com.attacker.test/icon.png",
            "https://user:secret@publikhq.com/icon.png", "file:///tmp/icon.png",
            "https://publikhq.com/icon.svg", "https://publikhq.com/../icon.png",
            "https://publikhq.com/icon.png?token=value"
        ] {
            #expect(CatalogAppIconPolicy.validatedPublicIconURL(candidate) == nil)
        }
        #expect(CatalogAppIconPolicy.acceptsResponse(
            statusCode: 200, mimeType: "image/png", expectedBytes: -1
        ))
        #expect(!CatalogAppIconPolicy.acceptsResponse(
            statusCode: 200, mimeType: "text/html", expectedBytes: 12
        ))
        #expect(!CatalogAppIconPolicy.acceptsResponse(
            statusCode: 200, mimeType: "image/png",
            expectedBytes: Int64(CatalogAppIconPolicy.maximumImageBytes + 1)
        ))
    }

    @Test func iconLoaderDeduplicatesConcurrentRequests() async throws {
        let fixture = IconFixture()
        let loader = CatalogAppIconLoader(fetch: { await fixture.download($0) })
        let url = try #require(CatalogAppIconPolicy.verifiedIconURL(forSlug: "astro"))
        let results = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<8 { group.addTask { await loader.imageData(for: url) } }
            var values: [Data?] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == Data([1, 2, 3]) })
        #expect(await fixture.requestCount == 1)
    }

    @Test func iconByteBufferStopsAtTheConfiguredLimit() {
        var buffer = CatalogIconByteBuffer()
        let acceptedBody = buffer.append(Data(repeating: 1, count: CatalogAppIconPolicy.maximumImageBytes))
        let rejectedExtraByte = buffer.append(Data([2]))
        #expect(acceptedBody)
        #expect(!rejectedExtraByte)
        #expect(buffer.data.count == CatalogAppIconPolicy.maximumImageBytes)
    }

    @Test func settingsRequestsReuseOnePanel() {
        #expect(SettingsPanelRouting.action(
            for: .show, panelExists: true, panelIsVisible: true
        ) == .showExisting)
        #expect(SettingsPanelRouting.action(
            for: .toggle, panelExists: true, panelIsVisible: true
        ) == .hideExisting)
        #expect(SettingsPanelRouting.action(
            for: .toggle, panelExists: false, panelIsVisible: false
        ) == .createAndShow)
    }

    @Test func placementCoalescesOnlyUserChanges() {
        var updates = SettingsPanelPlacementUpdates()
        for offset in 0..<200 {
            updates.recordMove(to: CGPoint(x: offset, y: offset), isProgrammatic: false)
        }
        let settled = updates.takeSettledUpdate()
        #expect(settled.origin == CGPoint(x: 199, y: 199))
        #expect(settled.size == nil)

        updates.recordMove(to: CGPoint(x: 400, y: 400), isProgrammatic: true)
        #expect(updates.takeSettledUpdate().origin == nil)
    }

    @Test func placementMigratesOnlyTheOldDefaultWidth() throws {
        let suiteName = "iris-launch-slice-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(420.0, forKey: "iris:panel:width")
        defaults.set(640.0, forKey: "iris:panel:height")
        defaults.set(80.0, forKey: "iris:panel:originX")
        defaults.set(90.0, forKey: "iris:panel:originY")

        let placement = MenuBarPanelPlacement(userDefaults: defaults)
        #expect(placement.storedSize == CGSize(width: 376, height: 640))
        #expect(placement.storedOrigin == CGPoint(x: 80, y: 90))
    }

    @Test func glassPolicyHonorsTransparencyContrastAndMotion() {
        let normal = IrisGlassSurfacePolicy.resolve(
            reduceTransparency: false, increaseContrast: false, reduceMotion: false
        )
        #expect(normal.usesBackdropMaterial)
        #expect(normal.usesDecorativeHighlights)
        #expect(normal.animationsAreEnabled)

        let accessible = IrisGlassSurfacePolicy.resolve(
            reduceTransparency: true, increaseContrast: true, reduceMotion: true
        )
        #expect(accessible.usesSolidSurfaceFallback)
        #expect(accessible.shellBorderOpacity == 0.28)
        #expect(accessible.controlBorderOpacity == 0.30)
        #expect(accessible.pressedScale == 1)
        #expect(!accessible.animationsAreEnabled)
    }
}

private actor IconFixture {
    private(set) var requestCount = 0

    func download(_ url: URL) async -> Data? {
        requestCount += 1
        try? await Task.sleep(for: .milliseconds(20))
        return Data([1, 2, 3])
    }
}

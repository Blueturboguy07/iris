import Foundation
import XCTest
@testable import IrisMobileShellCore

final class NativeMobileMarketplacePolicyTests: XCTestCase {
    func testLaunchScopeRequiresMobileDescriptorNotNameOrDesktopMetadata() {
        for appID in NativeMobileMarketplacePolicy.launchAppIDs {
            XCTAssertTrue(NativeMobileMarketplacePolicy.isVisibleInBrowse(app(appID: appID)))
            XCTAssertFalse(NativeMobileMarketplacePolicy.isVisibleInBrowse(app(appID: appID, platform: "macos")))
        }
        let desktop = PublikMobileCatalogApp(slug: "kneecap", name: "Kneecap for iPhone",
            guideSlug: nil, macBundleId: "publik.kneecap", latestReleaseTag: nil, mobileShell: nil)
        XCTAssertFalse(NativeMobileMarketplacePolicy.isVisibleInBrowse(desktop))
        // round6/catalog-expand: Lunara is now a listed app (SPEC L4); an app that cannot run in the shell (SPEC L114) stays out.
        XCTAssertFalse(NativeMobileMarketplacePolicy.isVisibleInBrowse(app(appID: "publik.noscroll")))
        XCTAssertFalse(NativeMobileMarketplacePolicy.isVisibleInBrowse(app(appID: "future.mobile")))
    }

    func testBrowseProjectionDoesNotMutateCatalogAndRetainsFutureUpdateMetadata() {
        let future = app(appID: "future.mobile")
        let lunara = app(appID: "publik.noscroll")
        let catalog = [future, lunara, app(appID: "publik.nut-ai")]
        let visible = catalog.filter(NativeMobileMarketplacePolicy.isVisibleInBrowse)
        XCTAssertEqual(visible.map { $0.mobileShell?.appId }, ["publik.nut-ai"])
        XCTAssertEqual(catalog.count, 3)
        XCTAssertEqual(catalog[0], future)
        XCTAssertEqual(catalog[1], lunara)
    }

    func testActionsDistinguishInstallOpenUpdateAndWrongBaseWithoutApprovalClaims() {
        let listed = app(appID: "publik.freeharmony")
        XCTAssertEqual(NativeMobileMarketplacePolicy.actionLabel(for: listed, installedRevisionID: nil), "Get app")
        XCTAssertEqual(NativeMobileMarketplacePolicy.actionLabel(for: listed, installedRevisionID: "new"), "Open")
        XCTAssertEqual(NativeMobileMarketplacePolicy.actionLabel(for: listed, installedRevisionID: "old"), "Review update")
        XCTAssertEqual(NativeMobileMarketplacePolicy.actionLabel(for: listed, installedRevisionID: "other"), "Check version")
    }

    private func app(appID: String, platform: String = "ios") -> PublikMobileCatalogApp {
        // Pure policy input; actual transport descriptor and package validation
        // are exercised separately by PublikMobileCatalogClientTests.
        PublikMobileCatalogApp(slug: appID, name: "Arbitrary display name", guideSlug: nil,
            macBundleId: nil, latestReleaseTag: nil,
            mobileShell: PublikMobileShellDescriptor(version: 1, platform: platform,
                packageFormat: NativeSecurity.packageFormat,
                downloadURL: URL(string: "https://publikhq.com/mobile/package.json")!,
                mediaType: "application/json", byteCount: 1, packageSHA256: String(repeating: "a", count: 64),
                appId: appID, projectId: "project.mobile", baseRevisionId: "old", revisionId: "new",
                contentHash: String(repeating: "b", count: 64)))
    }
}

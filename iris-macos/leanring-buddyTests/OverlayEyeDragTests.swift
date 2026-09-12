import Foundation
import Testing
#if canImport(Iris)
@testable import Iris
#else
@testable import IrisUsability
#endif

struct OverlayEyeDragTests {
    private let screen = CGSize(width: 1512, height: 982)

    @Test func keepsTheGrabOffsetInsteadOfJumpingItsCenterToThePointer() {
        let drag = OverlayEyeDragSession(initialHome: CGPoint(x: 100, y: 100),
                                         initialPointer: CGPoint(x: 115, y: 90))
        #expect(drag.home(forPointer: CGPoint(x: 315, y: 290), onScreenOfSize: screen)
                == CGPoint(x: 300, y: 300))
    }

    @Test func repeatedFramesDoNotAccumulateTranslationOrSnapBack() {
        let drag = OverlayEyeDragSession(initialHome: CGPoint(x: 100, y: 100),
                                         initialPointer: CGPoint(x: 100, y: 100))
        for offset in 0...300 {
            let pointer = CGPoint(x: 100 + offset, y: 100 + offset)
            #expect(drag.home(forPointer: pointer, onScreenOfSize: screen) == pointer)
            #expect(drag.home(forPointer: pointer, onScreenOfSize: screen) == pointer)
        }
    }

    @Test func reversingDirectionUsesOriginalAnchor() {
        let drag = OverlayEyeDragSession(initialHome: CGPoint(x: 500, y: 500),
                                         initialPointer: CGPoint(x: 510, y: 510))
        #expect(drag.home(forPointer: CGPoint(x: 710, y: 710), onScreenOfSize: screen)
                == CGPoint(x: 700, y: 700))
        #expect(drag.home(forPointer: CGPoint(x: 310, y: 310), onScreenOfSize: screen)
                == CGPoint(x: 300, y: 300))
    }

    @Test func leavingAnEdgeDoesNotReuseTheClampedFrameAsAnAnchor() {
        let drag = OverlayEyeDragSession(initialHome: CGPoint(x: 200, y: 200),
                                         initialPointer: CGPoint(x: 210, y: 210))
        #expect(drag.home(forPointer: CGPoint(x: -100, y: -100), onScreenOfSize: screen)
                == CGPoint(x: 44, y: 44))
        #expect(drag.home(forPointer: CGPoint(x: 310, y: 310), onScreenOfSize: screen)
                == CGPoint(x: 300, y: 300))
    }

    @Test func releaseUsesLatestPointerEvenWhenIntermediateSamplesAreMissing() {
        let drag = OverlayEyeDragSession(initialHome: CGPoint(x: 100, y: 100),
                                         initialPointer: CGPoint(x: 100, y: 100))
        #expect(drag.home(forPointer: CGPoint(x: 120, y: 120), onScreenOfSize: screen)
                == CGPoint(x: 120, y: 120))
        #expect(drag.home(forPointer: CGPoint(x: 800, y: 700), onScreenOfSize: screen)
                == CGPoint(x: 800, y: 700))
    }

    @Test func finalPositionSurvivesStoreRecreation() throws {
        let suite = "IrisEyeDragTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let drag = OverlayEyeDragSession(initialHome: CGPoint(x: 100, y: 100),
                                         initialPointer: CGPoint(x: 115, y: 90))
        let finalHome = drag.home(forPointer: CGPoint(x: 615, y: 490), onScreenOfSize: screen)
        OverlayEyeRestingPlace(userDefaults: defaults).remember(finalHome, onScreenOfSize: screen)
        #expect(OverlayEyeRestingPlace(userDefaults: defaults).restingPlace(onScreenOfSize: screen)
                == CGPoint(x: 600, y: 500))
    }

    @Test func tinyScreenStillKeepsEyeReachable() {
        let drag = OverlayEyeDragSession(initialHome: CGPoint(x: 100, y: 100),
                                         initialPointer: CGPoint(x: 100, y: 100))
        #expect(drag.home(forPointer: CGPoint(x: 1000, y: 1000),
                          onScreenOfSize: CGSize(width: 80, height: 60))
                == CGPoint(x: 40, y: 30))
    }
}

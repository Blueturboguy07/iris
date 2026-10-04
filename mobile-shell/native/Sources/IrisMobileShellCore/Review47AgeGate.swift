import Foundation

// Unit m3-guideline47, Guideline 4.7.5: "Your app must provide a way for
// users to identify software that exceeds the app's age rating, and use an
// age restriction mechanism based on verified or declared age to limit
// access by underage users." (verbatim, checked 2026-09-27 against
// https://developer.apple.com/app-store/review/guidelines/)
//
// This file is the restriction MECHANISM: a pure decision function plus a
// small persisted "declared age" store. It never calls Apple's
// DeclaredAgeRange framework directly. That framework needs a
// UIViewController/SwiftUI environment and is iOS 26.0+ only (confirmed
// 2026-09-27 from the real arm64-apple-ios-simulator.swiftinterface at
// $(xcrun --sdk iphonesimulator --show-sdk-path)/System/Library/Frameworks/
// DeclaredAgeRange.framework/Modules/DeclaredAgeRange.swiftmodule/):
//   AgeRangeService.shared.requestAgeRange(ageGates: Int, Int?, Int?, in: UIViewController)
//     async throws -> AgeRangeService.Response
//   case .declinedSharing / case .sharing(range: AgeRange { lowerBound: Int?, ... })
//   SwiftUI: @Environment(\.requestAgeRange) with DeclaredAgeRangeAction.
// A Host reviewed UI (iOS 26+) calls that API and reports its lower bound
// here through Review47DeclaredAgeStore.setDeclaredMinimumAge; on iOS 17
// through 25 the Host instead asks once in plain language ("Are you 18 or
// older?") and stores the answer the same way. See
// docs/plans/20260926-feature-streams/s6-mobile/impl/m3-guideline47/HANDOFF.md
// for the exact fallback UI text.

/// The person's declared minimum age is modeled as a single lower bound
/// (matching `AgeRangeService.AgeRange.lowerBound`), not the full API
/// response shape, since Core never talks to that framework itself.
public protocol Review47DeclaredAgeStore: Sendable {
    func declaredMinimumAge() async -> Int?
    func setDeclaredMinimumAge(_ age: Int?) async
    func hasAskedOnce() async -> Bool
    func setHasAskedOnce(_ value: Bool) async
}

public enum Review47AgeGateDecision: Equatable, Sendable {
    case allowed
    /// `declaredAge == nil` means "never declared yet" (RC-02: this is the
    /// case the old `decide` treated as `.allowed`, the actual fail-open
    /// bug this rewrite closes) -- the Host presents `NativeAgeGateSheet`
    /// for this case. A non-nil `declaredAge` below `appAgeRating` means a
    /// real declaration that is simply not old enough.
    case restricted(appAgeRating: Int, declaredAge: Int?)
}

/// RC-02 / OD-02 wording, in one place so the store button, the website
/// link flow and the marketplace info view all say the same thing. Plain
/// language only.
public enum Review47AgeGateCopy {
    /// Sentence shown when someone has not told Iris an age yet.
    public static func needsAgeMessage(appAgeRating: Int) -> String {
        "This app is rated \(appAgeRating)+. Tell Iris your age range to continue. Iris keeps this on your iPhone."
    }

    public static func message(appAgeRating: Int, declaredAge: Int?) -> String {
        guard let declaredAge else { return needsAgeMessage(appAgeRating: appAgeRating) }
        return "This app is rated \(appAgeRating)+. The age set on this iPhone (\(declaredAge)+) is below that."
    }
}

/// One person's local, on-device age declaration and the 4.7.5 gate
/// decision derived from it. Never a network call, never shared with
/// Publik: this is exactly the "declared age" the guideline names, kept on
/// the device that declared it.
public actor Review47AgeGate {
    private let store: Review47DeclaredAgeStore

    public init(store: Review47DeclaredAgeStore) {
        self.store = store
    }

    /// RC-02 (apple-compliance/REQUIRED_CHANGES.md): rewritten to fail
    /// closed. The old version returned `.allowed` whenever `declaredAge`
    /// was `nil`, regardless of `appAgeRating` -- meaning nobody was ever
    /// actually restricted, since nobody had declared an age until this
    /// mechanism itself first asked. `apple-compliance/DECISIONS.md`
    /// section 1.1/OD-01 decides `Review47AppStoreMetadata.shellAgeRating`
    /// (13); this now gates on it directly:
    /// - a missing app rating (an older descriptor, not yet reviewed for
    ///   4.7) still degrades to "not applicable", same as before -- this
    ///   mirrors `NativeMobileMarketplacePolicy`'s existing rule that
    ///   absent metadata is never itself a reason to deny;
    /// - an app rating at or below the shell's own rating is always
    ///   `.allowed`, with no declaration asked at all -- the shell's own
    ///   rating is already at least that high, so 4.7.5 has nothing to add;
    /// - only an app rated *above* the shell's rating is ever gated: no
    ///   declared age yet is `.restricted(appAgeRating:declaredAge: nil)`
    ///   (the Host presents `NativeAgeGateSheet` for this), and a declared
    ///   age below the app's rating stays `.restricted` with that age.
    public static func decide(appAgeRating: Int?, declaredAge: Int?) -> Review47AgeGateDecision {
        guard let appAgeRating, appAgeRating > Review47AppStoreMetadata.shellAgeRating else { return .allowed }
        guard let declaredAge else { return .restricted(appAgeRating: appAgeRating, declaredAge: nil) }
        return declaredAge >= appAgeRating
            ? .allowed
            : .restricted(appAgeRating: appAgeRating, declaredAge: declaredAge)
    }

    public func evaluate(appAgeRating: Int?) async -> Review47AgeGateDecision {
        Self.decide(appAgeRating: appAgeRating, declaredAge: await store.declaredMinimumAge())
    }

    public func declareMinimumAge(_ age: Int?) async {
        await store.setDeclaredMinimumAge(age)
        await store.setHasAskedOnce(true)
    }

    public func hasAskedOnce() async -> Bool {
        await store.hasAskedOnce()
    }

    public func declaredMinimumAge() async -> Int? {
        await store.declaredMinimumAge()
    }
}

/// Default persisted store. Foundation-only (no UIKit/DeclaredAgeRange
/// import), so it works identically in SwiftPM macOS tests and on-device.
/// An actor rather than a lock-guarded class: `UserDefaults` is already
/// thread-safe on its own, and actor isolation serializes Swift-level
/// access without an `NSLock` held across an `async` boundary.
public actor UserDefaultsReview47AgeStore: Review47DeclaredAgeStore {
    private let defaults: UserDefaults
    private let ageKey: String
    private let askedKey: String

    public init(defaults: UserDefaults = .standard, namespace: String = "iris.review47.age-gate") {
        self.defaults = defaults
        self.ageKey = namespace + ".declared-minimum-age"
        self.askedKey = namespace + ".has-asked-once"
    }

    public func declaredMinimumAge() async -> Int? {
        guard defaults.object(forKey: ageKey) != nil else { return nil }
        return defaults.integer(forKey: ageKey)
    }

    public func setDeclaredMinimumAge(_ age: Int?) async {
        if let age {
            defaults.set(age, forKey: ageKey)
        } else {
            defaults.removeObject(forKey: ageKey)
        }
    }

    public func hasAskedOnce() async -> Bool {
        defaults.bool(forKey: askedKey)
    }

    public func setHasAskedOnce(_ value: Bool) async {
        defaults.set(value, forKey: askedKey)
    }
}

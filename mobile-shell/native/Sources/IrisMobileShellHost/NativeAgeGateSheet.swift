#if os(iOS)
import IrisMobileShellCore
import SwiftUI
#if canImport(DeclaredAgeRange)
import DeclaredAgeRange
#endif

/// Guideline 4.7.5 restriction mechanism's UI half. `Review47AgeGate` (in
/// IrisMobileShellCore) is the decision half; this file only asks the
/// question and records the answer through it.
///
/// RC-02 (decided in apple-compliance/DECISIONS.md, OD-01 and OD-02): the
/// sheet opens from the "Rated N+ · Check your age" tap on Get for an app
/// rated above the shell's own rating (`Review47AppStoreMetadata.shellAgeRating`,
/// 13), never at first launch. On iOS 26 and later it asks Apple's Declared
/// Age Range API; below that, three plain buttons (13, 16, 18) plus "Not
/// now". The answer stays on this iPhone.
struct NativeAgeGateSheet: View {
    /// The ages a person can declare, ascending. On iOS 26+ these become
    /// `AgeRangeService.requestAgeRange`'s up-to-three `ageGates` (verified
    /// against the real SDK interface at
    /// `iPhoneSimulator27.0.sdk/.../DeclaredAgeRange.swiftmodule/arm64-apple-ios-simulator.swiftinterface`:
    /// `requestAgeRange(ageGates threshold1: Int, _ threshold2: Int? = nil, _ threshold3: Int? = nil, in: UIViewController) async throws -> Response`).
    /// Only the first three are ever sent to that API; a fourth or later
    /// threshold still appears in the pre-26 fallback buttons.
    struct Thresholds: Equatable, Sendable {
        let ages: [Int]

        init(ages: [Int]) {
            precondition(!ages.isEmpty, "NativeAgeGateSheet needs at least one selectable age")
            precondition(ages == ages.sorted(), "thresholds must already be ascending; caller decides the order shown")
            self.ages = ages
        }

        /// The first three thresholds, in the exact positional shape
        /// `requestAgeRange(ageGates:_:_:in:)` takes.
        fileprivate var systemGates: (Int, Int?, Int?) {
            (ages[0], ages.count > 1 ? ages[1] : nil, ages.count > 2 ? ages[2] : nil)
        }
    }

    /// Every sentence a person sees. Plain language only: no "threshold",
    /// "gate" or "declare" in any of these strings.
    struct Copy: Sendable {
        /// OD-02 copy: "This app is rated N+. Tell Iris your age range to
        /// continue. Iris keeps this on your iPhone."
        static func store(appAgeRating: Int) -> Copy {
            Copy(
                title: "Check your age",
                body: Review47AgeGateCopy.needsAgeMessage(appAgeRating: appAgeRating),
                confirmButtonLabel: { _ in "Share my age range" },
                fallbackChoiceLabel: { "I am \($0) or older" },
                declineText: "Not now"
            )
        }

        let title: String
        let body: String
        /// Label for the button that starts the age check. Receives the
        /// highest configured threshold only so callers can say e.g.
        /// "Confirm I'm 18 or older" without hardcoding the number twice.
        let confirmButtonLabel: (Int) -> String
        /// Label for each pre-26 fallback choice, one per threshold.
        let fallbackChoiceLabel: (Int) -> String
        let declineText: String
    }

    /// The buckets OD-02 decided: 13, 16 and 18.
    static let storeAges = [13, 16, 18]

    let thresholds: Thresholds
    let copy: Copy
    let ageGate: Review47AgeGate
    let onDeclared: (Int?) -> Void

    init(
        thresholds: Thresholds,
        copy: Copy,
        ageGate: Review47AgeGate,
        onDeclared: @escaping (Int?) -> Void = { _ in }
    ) {
        self.thresholds = thresholds
        self.copy = copy
        self.ageGate = ageGate
        self.onDeclared = onDeclared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(copy.title)
                .font(.title2)
                .fontWeight(.semibold)
                .accessibilityIdentifier("iris.app.age-gate.title")
            Text(copy.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("iris.app.age-gate.body")

            systemOrFallback

            Button(action: { declare(nil) }) {
                Text(copy.declineText).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityIdentifier("iris.app.age-gate.decline")
        }
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("iris.app.age-gate.sheet")
    }

    @ViewBuilder
    private var systemOrFallback: some View {
        #if canImport(DeclaredAgeRange)
        if #available(iOS 26.0, *) {
            SystemAgeRangeButton(
                thresholds: thresholds,
                label: copy.confirmButtonLabel(thresholds.ages.last ?? thresholds.ages[0]),
                onResult: declare
            )
        } else {
            fallbackButtons
        }
        #else
        fallbackButtons
        #endif
    }

    @ViewBuilder
    private var fallbackButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(thresholds.ages, id: \.self) { age in
                Button(copy.fallbackChoiceLabel(age)) { declare(age) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("iris.app.age-gate.declare.\(age)")
            }
        }
    }

    private func declare(_ age: Int?) {
        Task {
            await ageGate.declareMinimumAge(age)
            onDeclared(age)
        }
    }
}

#if canImport(DeclaredAgeRange)
/// The iOS 26+ path. A separate `View` (rather than inline `@Environment`
/// access in `NativeAgeGateSheet`) because `\.requestAgeRange` only exists
/// under `@available(iOS 26.0, *)`; giving it its own type lets the whole
/// declaration carry that availability instead of every property access
/// needing its own `if #available`.
@available(iOS 26.0, *)
private struct SystemAgeRangeButton: View {
    let thresholds: NativeAgeGateSheet.Thresholds
    let label: String
    let onResult: (Int?) -> Void

    @Environment(\.requestAgeRange) private var requestAgeRange
    @State private var isRequesting = false

    var body: some View {
        Button(action: request) {
            if isRequesting {
                ProgressView()
            } else {
                Text(label)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isRequesting)
        .accessibilityIdentifier("iris.app.age-gate.system-request")
    }

    private func request() {
        guard !isRequesting else { return }
        isRequesting = true
        let gates = thresholds.systemGates
        Task {
            defer { isRequesting = false }
            do {
                let response = try await requestAgeRange(ageGates: gates.0, gates.1, gates.2)
                switch response {
                case .sharing(let range):
                    onResult(range.lowerBound)
                case .declinedSharing:
                    onResult(nil)
                @unknown default:
                    onResult(nil)
                }
            } catch {
                // Any failure (not eligible, no account, network, the
                // person's device declined onboarding) degrades to the
                // same outcome as "declined": never a crash, never a
                // silent allow.
                onResult(nil)
            }
        }
    }
}
#endif
#endif

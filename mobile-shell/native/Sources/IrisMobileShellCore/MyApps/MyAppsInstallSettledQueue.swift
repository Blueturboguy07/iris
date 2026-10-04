import Foundation

// Round 6, unit R6-mobile-prep-B (MA2 hook 1c). "Newly installed apps count as
// used at install time, so a fresh install appears at the front" of Recently
// used (SPEC 1.1 item 4). The install finishes in the store model, which does
// not know about the My apps arrangement, and the My apps tab may not even be
// on screen yet. This queue is the hand-over: the store model notes each
// install that settled (with the moment it settled), and My apps drains it
// whenever it appears or a new install lands, writing each one through
// `MyAppsAction.recordInstalled`. Nothing is lost while My apps is not showing,
// and a second note for the same app keeps only the latest moment.

public struct StoreInstallSettledQueue: Equatable, Sendable {
    public struct Record: Equatable, Sendable {
        /// `NativeShellAppIdentity.id` ("appId::projectId"), the key My apps uses.
        public let identity: String
        public let settledAt: Date

        public init(identity: String, settledAt: Date) {
            self.identity = identity
            self.settledAt = settledAt
        }
    }

    public private(set) var records: [Record] = []

    public init() {}

    public var isEmpty: Bool { records.isEmpty }

    public mutating func settled(identity: String, at date: Date) {
        records.removeAll { $0.identity == identity }
        records.append(Record(identity: identity, settledAt: date))
    }

    /// Everything waiting, oldest first; the queue is empty afterwards.
    public mutating func drain() -> [Record] {
        let waiting = records.sorted { $0.settledAt < $1.settledAt }
        records.removeAll()
        return waiting
    }
}

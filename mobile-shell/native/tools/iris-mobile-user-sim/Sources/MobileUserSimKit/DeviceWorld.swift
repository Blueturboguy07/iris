import Foundation

/// A ground-truth event the world observed, independent of what the Core
/// code believes happened. Oracles read this log, not the code's own return
/// values, whenever an independent check is possible (MiroFish principle:
/// judge what the world saw, not the code's opinion of itself).
public struct DeviceWorldEvent: Sendable, Equatable {
    public let label: String
    public let detail: String

    public init(_ label: String, _ detail: String = "") {
        self.label = label
        self.detail = detail
    }
}

/// The one thing a run is allowed to fake: the device boundary. Everything
/// else (NativeShellLibraryCoordinator, NativeRevisionStore,
/// PublikMobileCatalogClient's validation, NativeWebsiteInstallFlow,
/// NativeMobileMarketplacePolicy) is the real production Core code, imported
/// unmodified from IrisMobileShellCore.
///
/// Reference type with a lock because it is read from the transport's async
/// `get()` (called by real Core code on whatever executor it chooses) and
/// mutated by scenario code simulating a persona's real-time actions
/// (backgrounding, going offline mid-download). This mirrors the desktop
/// harness's fake-world misbehavior model (README.md "World" section) without
/// importing it.
public final class DeviceWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var network: SimulatedNetworkCondition
    private var freeStorageBytes: Int
    private var osVersion: SimulatedOSVersion
    private var events: [DeviceWorldEvent] = []
    private var rng: SeededGenerator
    private var networkRequestCount = 0
    private var storageWriteAttempts: [(label: String, requestedBytes: Int, granted: Bool)] = []

    public init(persona: MobilePersona, seed: UInt64) {
        network = persona.startingNetwork
        freeStorageBytes = persona.startingFreeStorageBytes
        osVersion = persona.osVersion
        rng = SeededGenerator(seed: seed)
    }

    // MARK: Ground truth read/write (called by the harness and scenarios)

    public func currentNetwork() -> SimulatedNetworkCondition {
        lock.lock(); defer { lock.unlock() }
        return network
    }

    public func setNetwork(_ value: SimulatedNetworkCondition) {
        lock.lock()
        network = value
        lock.unlock()
        record("network-changed", "\(value)")
    }

    public func currentFreeStorageBytes() -> Int {
        lock.lock(); defer { lock.unlock() }
        return freeStorageBytes
    }

    public func setFreeStorageBytes(_ value: Int) {
        lock.lock()
        freeStorageBytes = value
        lock.unlock()
        record("storage-changed", "\(value) bytes free")
    }

    public func osVersionInEffect() -> SimulatedOSVersion {
        lock.lock(); defer { lock.unlock() }
        return osVersion
    }

    public func record(_ label: String, _ detail: String = "") {
        lock.lock()
        events.append(DeviceWorldEvent(label, detail))
        lock.unlock()
    }

    public func eventLog() -> [DeviceWorldEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    public func hasEvent(_ label: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains { $0.label == label }
    }

    // MARK: Boundary decisions consulted by the fakes

    /// Called once per attempted network request. Returns how the request
    /// should behave under the world's current condition.
    public func decideNetworkOutcome() -> NetworkOutcome {
        lock.lock()
        networkRequestCount += 1
        let condition = network
        let roll = rng.nextUnitDouble()
        lock.unlock()
        switch condition {
        case .healthy:
            return .proceed(extraLatencySeconds: 0)
        case .offline:
            return .fail(.offline)
        case .slow(let extraLatencySeconds):
            return .proceed(extraLatencySeconds: extraLatencySeconds)
        case .flaky(let failureRate):
            return roll < failureRate ? .fail(.flakyDrop) : .proceed(extraLatencySeconds: 0.01)
        case .catalogEmpty:
            return .proceed(extraLatencySeconds: 0) // shaped by the catalog body, not the transport
        case .catalogStale:
            return .proceed(extraLatencySeconds: 0) // shaped by the catalog body, not the transport
        }
    }

    public func totalNetworkRequests() -> Int {
        lock.lock(); defer { lock.unlock() }
        return networkRequestCount
    }

    /// A device write of `requestedBytes` new bytes. Denies the write and
    /// records the attempt (for the report and for mutation checks) once free
    /// space would go negative, mirroring ENOSPC without needing a real
    /// disk-quota volume.
    @discardableResult
    public func attemptStorageWrite(label: String, requestedBytes: Int) -> Bool {
        lock.lock()
        let granted = freeStorageBytes - requestedBytes >= 0
        if granted { freeStorageBytes -= requestedBytes }
        storageWriteAttempts.append((label, requestedBytes, granted))
        lock.unlock()
        record(granted ? "storage-write-granted" : "storage-write-denied", "\(label): \(requestedBytes) bytes")
        return granted
    }

    public func storageWriteAttemptLog() -> [(label: String, requestedBytes: Int, granted: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return storageWriteAttempts
    }
}

public enum NetworkOutcome: Sendable, Equatable {
    case proceed(extraLatencySeconds: Double)
    case fail(NetworkFailureReason)
}

public enum NetworkFailureReason: String, Sendable, Equatable {
    case offline
    case flakyDrop
}

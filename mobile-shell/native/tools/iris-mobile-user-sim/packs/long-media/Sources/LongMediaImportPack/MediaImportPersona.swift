import Foundation

/// Simulated phone people for the long-clip import pack. Deliberately its
/// own small type (not MobileUserSimKit's `MobilePersona`, which carries
/// install/store-flow fields -- catalog network conditions, OS-version
/// capability policy -- that do not apply here): every field below is
/// something this pack's own scenarios actually read.
public struct MediaImportPersona: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let startingFreeStorageBytes: Int64
    /// The longest pause, in simulated seconds, between two progress ticks
    /// of a healthy-but-slow iCloud download this persona might encounter.
    /// Must stay under `NativeMediaImportPolicy.stallThresholdSeconds` for
    /// "healthy"; scenarios that want an actual stall build ticks that
    /// exceed it directly.
    public let typicalPauseSecondsUpperBound: TimeInterval
    /// True for a persona whose device has another app (Photos sync, a
    /// backup, Spotlight indexing) that can consume real free space while
    /// this persona's own import is in progress.
    public let anotherAppMayFillDiskDuringImport: Bool
    /// True for a persona who backgrounds or force-quits mid-operation
    /// rather than waiting it out.
    public let interruptsMidImport: Bool

    public init(
        id: String, displayName: String, startingFreeStorageBytes: Int64,
        typicalPauseSecondsUpperBound: TimeInterval,
        anotherAppMayFillDiskDuringImport: Bool, interruptsMidImport: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.startingFreeStorageBytes = startingFreeStorageBytes
        self.typicalPauseSecondsUpperBound = typicalPauseSecondsUpperBound
        self.anotherAppMayFillDiskDuringImport = anotherAppMayFillDiskDuringImport
        self.interruptsMidImport = interruptsMidImport
    }
}

public enum MediaImportBuiltInPersonas {
    /// A non-technical person: picks one long video, plenty of free space,
    /// waits it out. Occasional short pauses (a normal iCloud download),
    /// never near the stall boundary.
    public static let nonTechnical = MediaImportPersona(
        id: "p1-nontechnical",
        displayName: "Non-technical person, one long video",
        startingFreeStorageBytes: 60 * 1024 * 1024 * 1024, // 60 GB free, an unremarkable modern phone
        typicalPauseSecondsUpperBound: 8,
        anotherAppMayFillDiskDuringImport: false,
        interruptsMidImport: false
    )

    /// A hurried power user: several clips at once, moderate free space,
    /// pauses that sometimes run close to the stall boundary, cancels and
    /// retries rather than waiting patiently.
    public static let hurriedPowerUser = MediaImportPersona(
        id: "p2-hurried",
        displayName: "Hurried power user, several clips at once",
        startingFreeStorageBytes: 20 * 1024 * 1024 * 1024,
        typicalPauseSecondsUpperBound: 45,
        anotherAppMayFillDiskDuringImport: true,
        interruptsMidImport: true
    )

    /// An edge person: a nearly full phone, a very large clip, another app
    /// competing for the same shrinking free space, pauses right at the
    /// stall boundary.
    public static let edgeUser = MediaImportPersona(
        id: "p3-edge",
        displayName: "Edge user, nearly full phone",
        startingFreeStorageBytes: 6 * 1024 * 1024 * 1024,
        typicalPauseSecondsUpperBound: 58,
        anotherAppMayFillDiskDuringImport: true,
        interruptsMidImport: true
    )

    public static let all: [MediaImportPersona] = [nonTechnical, hurriedPowerUser, edgeUser]
}

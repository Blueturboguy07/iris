import Foundation
import IrisMobileShellCore

/// One run's wiring: a fresh on-disk root, the persona's device world, and
/// the real production Core types (`NativeShellLibraryCoordinator`,
/// `PublikMobileCatalogClient`, `NativeWebsiteInstallFlow`) constructed
/// exactly the way a real Host would construct them, pointed at the fakes
/// instead of a real network socket and a real device volume.
public final class RunEnvironment {
    public let persona: MobilePersona
    public let world: DeviceWorld
    public let rootURL: URL
    /// Where the coordinator's durable library lives on disk. Exposed so a
    /// scenario can construct a second, independent
    /// `NativeShellLibraryCoordinator` over the same durable state to
    /// simulate a real app relaunch after a force-quit (a fresh process
    /// cannot reuse the killed one's in-memory actor).
    public let libraryRootURL: URL
    public let transport: FakeMobileTransport
    public let lowStorageFileManager: LowStorageFileManager
    public let capabilityPolicy: CapabilityPolicy
    public let coordinator: NativeShellLibraryCoordinator
    public let catalogClient: PublikMobileCatalogClient
    public let installFlow: NativeWebsiteInstallFlow

    private var workCounter = 0

    public init(persona: MobilePersona, seed: UInt64, scratchRoot: URL) throws {
        self.persona = persona
        self.world = DeviceWorld(persona: persona, seed: seed)
        self.rootURL = scratchRoot.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        self.transport = FakeMobileTransport(world: world)
        self.lowStorageFileManager = LowStorageFileManager(world: world)
        self.catalogClient = PublikMobileCatalogClient(transport: transport)

        let capabilityPolicy = persona.osVersion.mirroredHostCapabilityPolicy
        self.capabilityPolicy = capabilityPolicy
        self.libraryRootURL = rootURL.appendingPathComponent("library", isDirectory: true)
        self.coordinator = NativeShellLibraryCoordinator(
            rootURL: libraryRootURL,
            capabilityPolicy: capabilityPolicy,
            fileManager: lowStorageFileManager
        )
        self.installFlow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: catalogClient,
            capabilityPolicy: capabilityPolicy
        )
    }

    /// A fresh scratch directory for this run's package-fixture generation,
    /// so concurrent runs (and concurrent scenarios sharing a sweep) never
    /// collide on the same `.staging-*` or `package.json` path.
    public func freshWorkDirectory() -> URL {
        workCounter += 1
        return rootURL.appendingPathComponent("fixtures/\(workCounter)", isDirectory: true)
    }

    public func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

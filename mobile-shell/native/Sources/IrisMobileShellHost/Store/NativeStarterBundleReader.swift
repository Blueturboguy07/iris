import Foundation
import IrisMobileShellCore

/// RC-11 (round 6): reads one bundled starter chain (the `.irisapp` files under
/// `Starter/<label>/` inside the app) on request. The same files, in the same
/// order, that `IrisMobileShellApp.loadBundledStarterChains()` reads at launch;
/// this reads only the one app someone tapped Get on, and only then.
public enum NativeStarterBundleReader {
    private static func directory(for entry: NativeStarterCatalog.Entry, bundle: Bundle) -> URL? {
        bundle.resourceURL?.appendingPathComponent(NativeStarterCatalog.subdirectory(for: entry), isDirectory: true)
    }

    /// True when every file of the chain is present. A file-exists check only:
    /// it runs while the Get button is drawn, so it never reads the bytes.
    public static func hasFiles(_ entry: NativeStarterCatalog.Entry, bundle: Bundle = .main) -> Bool {
        guard let directory = directory(for: entry, bundle: bundle) else { return false }
        return entry.orderedFileNames.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0, isDirectory: false).path)
        }
    }

    /// The whole chain, oldest first, or nil when any file cannot be read
    /// (`NativeStarterInstaller` never installs an incomplete chain).
    public static func chain(_ entry: NativeStarterCatalog.Entry, bundle: Bundle = .main) -> NativeStarterInstaller.AppChain? {
        guard let directory = directory(for: entry, bundle: bundle) else { return nil }
        var packages: [Data] = []
        for name in entry.orderedFileNames {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name, isDirectory: false)) else { return nil }
            packages.append(data)
        }
        guard !packages.isEmpty else { return nil }
        return NativeStarterInstaller.AppChain(displayName: entry.displayName, orderedPackages: packages)
    }

    /// The reinstaller `StoreModel` takes (RC-11), wired to this app's own bundle
    /// and the one library coordinator the reader already uses.
    public static func reinstaller(coordinator: NativeShellLibraryCoordinator, bundle: Bundle = .main) -> NativeStarterSeedReinstaller {
        NativeStarterSeedReinstaller(
            coordinator: coordinator,
            hasBundledFiles: { hasFiles($0, bundle: bundle) },
            loadChain: { chain($0, bundle: bundle) }
        )
    }
}

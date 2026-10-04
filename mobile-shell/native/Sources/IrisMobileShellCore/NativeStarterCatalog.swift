import Foundation

/// Names the three bundled starter apps and, for each, the ordered list of
/// `.irisapp` file names that make up its reviewed starter chain. This is
/// pure data: it names files, it does not read them. The app layer resolves
/// each name against its own bundle (`Bundle.main`) and hands the resulting
/// bytes to `NativeStarterInstaller`.
///
/// Each chain is ordered oldest first. The first file's package must declare
/// no base revision; every later file's package must declare the previous
/// file's revision as its base. `NativeStarterInstaller` enforces this at
/// install time, so a wrong order here fails loudly instead of silently
/// installing the wrong content.
///
/// Source, for the exact reviewed files this ships (read-only references
/// under `/Users/akrit/Documents/iris/outputs`, hash-verified against
/// `artifacts/mobile-CURRENT_STATUS.md` and
/// `artifacts/mobile-central-handoff-2026-09-21.md`):
/// see PLAN.md in this unit's impl folder, "Starter content provenance".
public enum NativeStarterCatalog {
    public struct Entry: Sendable {
        public let label: String
        public let displayName: String
        /// Relative to the bundled "Starter/<label>" directory, oldest first.
        public let orderedFileNames: [String]
        /// round6/catalog-expand (SPEC.md section 5, option B): false means the
        /// files are inside Iris and Browse lists the app, but nothing installs
        /// it until someone taps Get (which runs after the age check). Only a
        /// first launch and the UI-test fixtures read this; `NativeStarterSeedReinstaller`
        /// still finds every entry, so Get works offline.
        public let installsAtFirstLaunch: Bool

        public init(label: String, displayName: String, orderedFileNames: [String], installsAtFirstLaunch: Bool = true) {
            self.label = label
            self.displayName = displayName
            self.orderedFileNames = orderedFileNames
            self.installsAtFirstLaunch = installsAtFirstLaunch
        }
    }

    /// The bundled folder name each entry's files live under
    /// ("Starter/<subdirectory>/<fileName>").
    public static func subdirectory(for entry: Entry) -> String { "Starter/\(entry.label)" }

    /// The entries a launch installs on its own. The rest are bundled for a
    /// later Get.
    public static var firstLaunchEntries: [Entry] { entries.filter(\.installsAtFirstLaunch) }

    public static let entries: [Entry] = [
        Entry(
            label: "Kneecap",
            displayName: "Kneecap",
            // 04-longclip.irisapp (long-clip import fix, round3-mobile
            // M-longimport/kneecap-long-clips) and 05-bugpass.irisapp
            // (kneecap-bugpass: focus-race/cancel-listener/audio-decode/
            // multi-select fixes; H1 in that unit's INTEGRATION_HOOKS.md)
            // added by round5/mobile-integrator-B1, 2026-09-28. Chain
            // continuity verified byte-for-byte before applying: 03-final's
            // own approvedRevisionId (rev-sha256:5b791e2d...) equals
            // 04-longclip's baseRevisionId; 04-longclip's own
            // approvedRevisionId (rev-sha256:074da1f5...) equals
            // 05-bugpass's baseRevisionId. 04 was built and phone-tested in
            // an earlier round (NATIVE_RUNS.md) but, per that same doc,
            // never before landed in this repo; adding it here is a
            // prerequisite for 05 (NativeStarterInstaller.position(of:in:)
            // walks this exact ordered list, so 05's own base revision
            // must have a chain member immediately before it).
            //
            // 06-deletefix.irisapp (kneecap-bugpass DELETE_FIX.md, G10: deleting
            // a project in Kneecap now works and frees its videos) added by
            // round6/mobile-prep-A, 2026-09-29. Continuity checked by script
            // before applying: 05-bugpass's approved revisionId
            // (rev-sha256:cc3101cf...) equals 06's baseRevisionId, so the
            // chain is 04, 05, 06 and a fresh install ends on 06
            // (package sha256 e00e5161...).
            orderedFileNames: ["01-base.irisapp", "02-update.irisapp", "03-final.irisapp", "04-longclip.irisapp", "05-bugpass.irisapp", "06-deletefix.irisapp"]
        ),
        Entry(
            label: "NutAI",
            displayName: "Nut AI",
            orderedFileNames: ["01-base.irisapp", "02-update.irisapp", "03-update.irisapp", "04-final.irisapp"]
        ),
        Entry(
            label: "FreeHarmony",
            displayName: "FreeHarmony",
            orderedFileNames: ["01-base.irisapp", "02-update.irisapp", "03-update.irisapp", "04-final.irisapp"]
        ),
        // round6/catalog-expand: Lunara, one revision, built without the AI
        // assistant (docs/plans/20260928-all-routes/round6/catalog-expand/packages/lunara).
        // Rated 16+, so it is not pushed onto every phone: it installs from these
        // files when someone taps Get, after the age check.
        Entry(
            label: "Lunara",
            displayName: "Lunara",
            orderedFileNames: ["01-base.irisapp"],
            installsAtFirstLaunch: false
        ),
    ]
}

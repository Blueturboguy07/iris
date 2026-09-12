import Foundation
@testable import IrisHarnessNative

@main
struct FeatureEditRepositoryContextChecks {
    enum Failure: Error { case assertion(String) }

    @MainActor static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }

    @MainActor static func main() throws {
        try discoversParentDirectoryDependenciesInStableOrder()
        print("PASS review context: parent-directory imports, export-from, require and priority")
        try interleavesDependenciesBeforeTheByteBound()
        print("PASS review context: dependency fairness across changed sources")
        try prioritizesLateAddedHelperUnderBytePressure()
        print("PASS review context: late added helper is promoted ahead of large imports")
        try keepsPersistenceHintScopedToItsChangedFile()
        print("PASS review context: unrelated persistence hint cannot reorder another file")
        try refusesHintsAbsentFromCurrentSource()
        print("PASS review context: preferred hints cannot introduce unseen imports")
        try refusesExternalTraversalAndSymlinkReferences()
        print("PASS review context: package aliases, traversal and symlink candidates refused")
        try parsesAddedImportsAndFallsBackForUnsupportedDiffShapes()
        print("PASS review context: added-import parser handles hunks and safe fallback")
        try ignoresMalformedHunkHints()
        print("PASS review context: malformed hunks cannot supply import hints")
        try respectsDiffPrefixAndNoDependencyByteBounds()
        print("PASS review context: diff and context byte bounds remain truthful")
        try enforcesFileCountAndDuplicateBounds()
        print("PASS review context: duplicate paths removed and 24-file bound enforced")
        print("FEATURE EDIT REPOSITORY CONTEXT CHECKS PASS: 10 groups")
    }

    @MainActor static func discoversParentDirectoryDependenciesInStableOrder() throws {
        let fixtureRoot = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        try write("src/db/changed.ts", """
        import type {
            Note
        } from "../types";
        export { helper } from "../helpers";
        const runtime = require("../runtime");
        const runtimeFromJavaScript = require("../runtime.js");
        import { App } from "../app";
        import "../only.ts";
        """, under: fixtureRoot)
        try write("src/other/changed2.ts", "import { runtime } from \"../runtime.js\";\n", under: fixtureRoot)
        try write("src/db/changed.test.ts", """
        import type { Note } from "../types";
        """, under: fixtureRoot)
        try write("src/types.ts", "export type Note = { id: string };\n", under: fixtureRoot)
        try write("src/helpers/index.ts", "export function helper() { return true; }\n", under: fixtureRoot)
        try write("src/runtime.ts", "export const runtime = true;\n", under: fixtureRoot)
        try write("src/runtime.tsx", "export const runtime = false;\n", under: fixtureRoot)
        try write("src/app.tsx", "export function App() { return null; }\n", under: fixtureRoot)
        try write("src/only/index.ts", "export const onlyIndex = true;\n", under: fixtureRoot)
        try write("src/db/neighbor.ts", "export function neighbor() { return false; }\n", under: fixtureRoot)
        try write("native/persistence.test.mjs", "test('persistence', () => true);\n", under: fixtureRoot)

        let context = FeatureEditRepositoryContext.collectReviewContext(
            repoRootPath: fixtureRoot.path,
            changedTestPaths: ["src/db/changed.test.ts", "src/db/changed.test.ts"],
            declaredNativeTestPaths: ["native/persistence.test.mjs", "native/persistence.test.mjs"],
            changedPaths: ["src/db/changed.ts", "src/other/changed2.ts", "src/db/changed.test.ts", "src/db/changed.ts"],
            sameDirectoryNeighborPaths: ["src/db/neighbor.ts", "src/db/changed.ts", "src/db/neighbor.ts"]
        )

        try require(context.files.map(\.repoRelativePath) == [
            "src/db/changed.test.ts",
            "native/persistence.test.mjs",
            "src/db/changed.ts",
            "src/other/changed2.ts",
            "src/types.ts",
            "src/runtime.ts",
            "src/helpers/index.ts",
            "src/app.tsx",
            "src/db/neighbor.ts",
        ], "review context priority or one-hop resolution changed")
        try require(context.files.filter { $0.repoRelativePath == "src/types.ts" }.count == 1,
            "duplicate parent dependency was included")
        try require(!context.files.contains { $0.repoRelativePath == "src/only/index.ts" },
            "explicit TypeScript extension incorrectly fell back to an index module")
        try require(!context.files.contains { $0.repoRelativePath == "src/runtime.tsx" },
            "a previously resolved JavaScript module was retargeted to an alternate extension")
        try require(context.omittedFileCount == 0, "resolved fixture paths were reported omitted")
    }

    @MainActor static func interleavesDependenciesBeforeTheByteBound() throws {
        let fixtureRoot = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        try write("src/ui.ts", """
        import { first } from "./uiDependencyA";
        import { second } from "./uiDependencyB";
        import { third } from "./uiDependencyC";
        export const ui = [first, second, third];
        """, under: fixtureRoot)
        try write("src/helper.ts", """
        import type { RequiredType } from "./requiredType";
        export const helper: RequiredType = { required: true };
        """, under: fixtureRoot)

        let largeDependencyByteCount = 900
        let requiredDependencyByteCount = 400
        for dependencyName in ["uiDependencyA", "uiDependencyB", "uiDependencyC"] {
            try writeSizedSource(
                "src/\(dependencyName).ts",
                byteCount: largeDependencyByteCount,
                under: fixtureRoot
            )
        }
        try writeSizedSource(
            "src/requiredType.ts",
            byteCount: requiredDependencyByteCount,
            under: fixtureRoot
        )

        var changedSourceByteCount = 0
        for path in ["src/ui.ts", "src/helper.ts"] {
            changedSourceByteCount += try byteCount(of: path, under: fixtureRoot)
        }
        let maxBytes = changedSourceByteCount
            + (largeDependencyByteCount * 2)
            + requiredDependencyByteCount
            - 1
        let context = FeatureEditRepositoryContext.collectReviewContext(
            repoRootPath: fixtureRoot.path,
            changedTestPaths: [],
            declaredNativeTestPaths: [],
            changedPaths: ["src/ui.ts", "src/helper.ts"],
            sameDirectoryNeighborPaths: [],
            maxBytes: maxBytes
        )

        let paths = context.files.map(\.repoRelativePath)
        try require(paths == [
            "src/ui.ts",
            "src/helper.ts",
            "src/uiDependencyA.ts",
            "src/requiredType.ts",
        ], "a first changed source exhausted the byte budget before the second source dependency")
        try require(context.includedByteCount <= maxBytes,
            "round-robin dependency context exceeded its byte bound")
    }

    @MainActor static func prioritizesLateAddedHelperUnderBytePressure() throws {
        let fixtureRoot = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let changedPath = "src/editor.ts"
        try write(changedPath, """
        import { render } from "./largeUI";
        import { persist } from "./largePersistence";
        import { helper } from "./newHelper";
        export const result = [render, persist, helper];
        """, under: fixtureRoot)
        try writeSizedSource("src/largeUI.ts", byteCount: 900, under: fixtureRoot)
        try writeSizedSource("src/largePersistence.ts", byteCount: 900, under: fixtureRoot)
        try write("src/newHelper.ts", "export const helper = true;\n", under: fixtureRoot)

        let changedByteCount = try byteCount(of: changedPath, under: fixtureRoot)
        let largeUIByteCount = try byteCount(of: "src/largeUI.ts", under: fixtureRoot)
        let maxBytes = changedByteCount + largeUIByteCount
        let unifiedDiff = """
        diff --git a/src/editor.ts b/src/editor.ts
        index 1111111..2222222 100644
        --- a/src/editor.ts
        +++ b/src/editor.ts
        @@ -1,3 +1,4 @@
         import { render } from "./largeUI";
         import { persist } from "./largePersistence";
        +import { helper } from "./newHelper";
         export const result = [render, persist, helper];
        """
        let preferred = FeatureEditRepositoryContext.addedDependencySourceByPath(in: unifiedDiff)
        try require(preferred[changedPath]?.contains("./newHelper") == true,
            "added helper import was not extracted from the diff")

        let baseline = FeatureEditRepositoryContext.collectReviewContext(
            repoRootPath: fixtureRoot.path,
            changedTestPaths: [],
            declaredNativeTestPaths: [],
            changedPaths: [changedPath],
            sameDirectoryNeighborPaths: [],
            maxBytes: maxBytes
        )
        try require(baseline.files.map(\.repoRelativePath) == [changedPath, "src/largeUI.ts"],
            "baseline dependency order did not demonstrate byte-pressure displacement")
        try require(!baseline.files.contains { $0.repoRelativePath == "src/newHelper.ts" },
            "late helper was already selected without a preferred diff hint")

        let hinted = FeatureEditRepositoryContext.collectReviewContext(
            repoRootPath: fixtureRoot.path,
            changedTestPaths: [],
            declaredNativeTestPaths: [],
            changedPaths: [changedPath],
            sameDirectoryNeighborPaths: [],
            preferredDependencySourceByPath: preferred,
            maxBytes: maxBytes
        )
        try require(hinted.files.map(\.repoRelativePath) == [changedPath, "src/newHelper.ts"],
            "late added helper was not promoted ahead of large imports")
        try require(!hinted.files.contains { $0.repoRelativePath == "src/largePersistence.ts" },
            "unrelated large persistence import displaced the promoted helper")
        try require(hinted.includedByteCount <= maxBytes,
            "preferred dependency context exceeded its byte bound")
    }

    @MainActor static func keepsPersistenceHintScopedToItsChangedFile() throws {
        let fixtureRoot = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        try write("src/editor.ts", """
        import { oldEditor } from "./oldEditor";
        import { helper } from "./editorHelper";
        export const editor = [oldEditor, helper];
        """, under: fixtureRoot)
        try write("src/persistence.ts", """
        import { oldPersistence } from "./oldPersistence";
        export const persistence = oldPersistence;
        """, under: fixtureRoot)
        try writeSizedSource("src/oldEditor.ts", byteCount: 700, under: fixtureRoot)
        try writeSizedSource("src/oldPersistence.ts", byteCount: 700, under: fixtureRoot)
        try write("src/editorHelper.ts", "export const helper = true;\n", under: fixtureRoot)

        let editorByteCount = try byteCount(of: "src/editor.ts", under: fixtureRoot)
        let persistenceByteCount = try byteCount(of: "src/persistence.ts", under: fixtureRoot)
        let oldEditorByteCount = try byteCount(of: "src/oldEditor.ts", under: fixtureRoot)
        let maxBytes = editorByteCount + persistenceByteCount + oldEditorByteCount
        let context = FeatureEditRepositoryContext.collectReviewContext(
            repoRootPath: fixtureRoot.path,
            changedTestPaths: [],
            declaredNativeTestPaths: [],
            changedPaths: ["src/editor.ts", "src/persistence.ts"],
            sameDirectoryNeighborPaths: [],
            preferredDependencySourceByPath: [
                "src/persistence.ts": "import { helper } from \"./editorHelper\";\n",
            ],
            maxBytes: maxBytes
        )
        let paths = context.files.map(\.repoRelativePath)
        try require(paths == [
            "src/editor.ts",
            "src/persistence.ts",
            "src/oldEditor.ts",
        ], "a persistence hint reordered dependencies for another changed file")
        try require(!paths.contains("src/editorHelper.ts"),
            "unrelated persistence hint introduced an editor dependency")
        try require(context.includedByteCount <= maxBytes,
            "persistence-scoped preferred context exceeded its byte bound")
    }

    @MainActor static func refusesHintsAbsentFromCurrentSource() throws {
        let fixtureRoot = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let changedPath = "src/editor.ts"
        try write(changedPath, "import { safe } from \"./safe\";\nexport { safe };\n", under: fixtureRoot)
        try write("src/safe.ts", "export const safe = true;\n", under: fixtureRoot)
        try write("src/ghost.ts", "export const ghost = true;\n", under: fixtureRoot)

        let changedByteCount = try byteCount(of: changedPath, under: fixtureRoot)
        let safeByteCount = try byteCount(of: "src/safe.ts", under: fixtureRoot)
        let context = FeatureEditRepositoryContext.collectReviewContext(
            repoRootPath: fixtureRoot.path,
            changedTestPaths: [],
            declaredNativeTestPaths: [],
            changedPaths: [changedPath],
            sameDirectoryNeighborPaths: [],
            preferredDependencySourceByPath: [
                changedPath: "import { ghost } from \"./ghost\";\n",
                "src/not-changed.ts": "import { ghost } from \"./ghost\";\n",
            ],
            maxBytes: changedByteCount + safeByteCount
        )
        let paths = context.files.map(\.repoRelativePath)
        try require(paths == [changedPath, "src/safe.ts"],
            "preferred hint introduced a dependency absent from current source")
        try require(!paths.contains("src/ghost.ts"),
            "an absent current import was allowed to introduce a repository file")
    }

    @MainActor static func refusesExternalTraversalAndSymlinkReferences() throws {
        let fixtureRoot = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        try write("src/changed.ts", """
        import "./types";
        import "react";
        import "@/types";
        const outside = require("../../outside");
        const linked = require("./linked");
        """, under: fixtureRoot)
        try write("src/types.ts", "export type Note = { id: string };\n", under: fixtureRoot)
        try write("src/real.ts", "export const real = true;\n", under: fixtureRoot)
        let symlinkURL = fixtureRoot.appendingPathComponent("src/linked.ts")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: fixtureRoot.appendingPathComponent("src/real.ts")
        )

        let context = FeatureEditRepositoryContext.collectReviewContext(
            repoRootPath: fixtureRoot.path,
            changedTestPaths: [],
            declaredNativeTestPaths: [],
            changedPaths: ["src/changed.ts"],
            sameDirectoryNeighborPaths: [],
            preferredDependencySourceByPath: [
                "src/changed.ts": """
                import "../../outside";
                import "/tmp/external";
                import "./linked";
                import "./types";
                """,
            ]
        )
        let paths = context.files.map(\.repoRelativePath)
        try require(paths == ["src/changed.ts", "src/types.ts"],
            "external, traversal or symlink reference escaped review context")
        try require(!paths.contains("src/linked.ts") && !paths.contains("src/real.ts"),
            "symlink target entered review context")
    }

    @MainActor static func parsesAddedImportsAndFallsBackForUnsupportedDiffShapes() throws {
        let diff = """
        diff --git a/src/entry.ts b/src/entry.ts
        index 1111111..2222222 100644
        --- a/src/entry.ts
        +++ b/src/entry.ts
        @@ -1,2 +1,4 @@
         import "./existing";
        +import "./added";
        +export { value } from '../exported';
         export const entry = true;
        diff --git "a/src/quoted.ts" "b/src/quoted.ts"
        --- "a/src/quoted.ts"
        +++ "b/src/quoted.ts"
        @@ -1,1 +1,2 @@
        +import "./quoted";
        diff --git a/src/deleted.ts /dev/null
        --- a/src/deleted.ts
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -import "./deleted";
        diff --git a/src/binary.ts b/src/binary.ts
        Binary files a/src/binary.ts and b/src/binary.ts differ
        diff --git a/src/old.ts b/src/new.ts
        similarity index 100%
        rename from src/old.ts
        rename to src/new.ts
        diff --git a/src/truncated.ts b/src/truncated.ts
        --- a/src/truncated.ts
        +++ b/src/truncated.ts
        """
        let preferred = FeatureEditRepositoryContext.addedDependencySourceByPath(in: diff)
        try require(Array(preferred.keys) == ["src/entry.ts"],
            "unsupported diff shapes produced an unsafe preferred path")
        let entrySource = preferred["src/entry.ts"] ?? ""
        try require(entrySource.contains("./added") && entrySource.contains("../exported"),
            "added imports were not retained from a normal hunk")
        try require(!entrySource.contains("@@") && !entrySource.contains("./quoted"),
            "hunk or quoted-header text leaked into a preferred source hint")

        let fixtureRoot = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let changedPath = "src/entry.ts"
        try write(changedPath, """
        import { first } from "./first";
        import { second } from "./second";
        export const entry = [first, second];
        """, under: fixtureRoot)
        try write("src/first.ts", "export const first = true;\n", under: fixtureRoot)
        try write("src/second.ts", "export const second = true;\n", under: fixtureRoot)
        let changedByteCount = try byteCount(of: changedPath, under: fixtureRoot)
        let firstByteCount = try byteCount(of: "src/first.ts", under: fixtureRoot)
        let fallbackContext = FeatureEditRepositoryContext.collectReviewContext(
            repoRootPath: fixtureRoot.path,
            changedTestPaths: [],
            declaredNativeTestPaths: [],
            changedPaths: [changedPath],
            sameDirectoryNeighborPaths: [],
            preferredDependencySourceByPath: FeatureEditRepositoryContext.addedDependencySourceByPath(
                in: """
                diff --git \"a/src/entry.ts\" \"b/src/entry.ts\"
                --- \"a/src/entry.ts\"
                +++ \"b/src/entry.ts\"
                @@ -1,2 +1,3 @@
                +import { second } from \"./second\";
                """
            ),
            maxBytes: changedByteCount + firstByteCount
        )
        try require(fallbackContext.files.map(\.repoRelativePath) == [changedPath, "src/first.ts"],
            "quoted diff header did not fall back to current-source dependency order")
    }

    @MainActor static func ignoresMalformedHunkHints() throws {
        let hints = FeatureEditRepositoryContext.addedDependencySourceByPath(in: """
        diff --git a/src/entry.ts b/src/entry.ts
        --- a/src/entry.ts
        +++ b/src/entry.ts
        @@ invalid hunk @@
        +import "./not-a-hint";
        """)
        try require(hints.isEmpty, "malformed hunk supplied a preferred import")
    }

    @MainActor static func respectsDiffPrefixAndNoDependencyByteBounds() throws {
        let oversizedPrefix = String(
            repeating: "x",
            count: FeatureEditRepositoryContext.maximumPermittedByteBudget
        )
        let laterHintDiff = oversizedPrefix + "\n" + """
        diff --git a/src/late.ts b/src/late.ts
        --- a/src/late.ts
        +++ b/src/late.ts
        @@ -1,0 +1,1 @@
        +import "./lateHelper";
        """
        try require(
            FeatureEditRepositoryContext.addedDependencySourceByPath(in: laterHintDiff).isEmpty,
            "diff parser read a hint beyond its bounded prefix"
        )

        let fixtureRoot = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let changedPath = "src/entry.ts"
        try write(changedPath, "import { dependency } from \"./dependency\";\n", under: fixtureRoot)
        try write("src/dependency.ts", "export const dependency = true;\n", under: fixtureRoot)
        let changedByteCount = try byteCount(of: changedPath, under: fixtureRoot)
        let context = FeatureEditRepositoryContext.collectReviewContext(
            repoRootPath: fixtureRoot.path,
            changedTestPaths: [],
            declaredNativeTestPaths: [],
            changedPaths: [changedPath],
            sameDirectoryNeighborPaths: [],
            maxBytes: changedByteCount
        )
        try require(context.files.map(\.repoRelativePath) == [changedPath],
            "a dependency was included after changed files consumed the byte budget")
        try require(context.includedByteCount == changedByteCount,
            "changed-file byte accounting drifted at a zero-dependency budget")
        try require(context.omittedFileCount == 1 && context.hasUnseenRequestedContext,
            "omitted dependency was not reported as unseen context")
    }

    @MainActor static func enforcesFileCountAndDuplicateBounds() throws {
        let fixtureRoot = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        try write("src/entry.ts", "import { dependency } from \"./dependency\";\n", under: fixtureRoot)
        try write("src/dependency.ts", "export const dependency = true;\n", under: fixtureRoot)
        try write("tests/entry.test.ts", "test('entry', () => true);\n", under: fixtureRoot)
        try write("native/persistence.test.mjs", "test('native', () => true);\n", under: fixtureRoot)

        var neighbors: [String] = []
        for index in 0..<30 {
            let path = "src/neighbor\(index).ts"
            try write(path, "export const value\(index) = \(index);\n", under: fixtureRoot)
            neighbors.append(path)
        }
        neighbors.append("src/neighbor0.ts")

        let context = FeatureEditRepositoryContext.collectReviewContext(
            repoRootPath: fixtureRoot.path,
            changedTestPaths: ["tests/entry.test.ts"],
            declaredNativeTestPaths: ["native/persistence.test.mjs"],
            changedPaths: ["src/entry.ts"],
            sameDirectoryNeighborPaths: neighbors,
            maxFileCount: 99,
            maxBytes: 4096
        )
        let paths = context.files.map(\.repoRelativePath)
        try require(paths.count == FeatureEditRepositoryContext.maximumPermittedReviewFileCount,
            "review context exceeded the hard file bound")
        try require(paths.prefix(4).elementsEqual([
            "tests/entry.test.ts",
            "native/persistence.test.mjs",
            "src/entry.ts",
            "src/dependency.ts",
        ]), "a fallback neighbor displaced a required dependency")
        try require(Set(paths).count == paths.count, "final context contains duplicate paths")
        try require(context.includedByteCount <= 4096, "final context exceeded byte bound")
    }

    @MainActor static func makeFixtureRoot() throws -> URL {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-review-context-selector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        return fixtureRoot
    }

    @MainActor static func write(_ relativePath: String, _ contents: String, under root: URL) throws {
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    @MainActor static func writeSizedSource(
        _ relativePath: String,
        byteCount: Int,
        under root: URL
    ) throws {
        try write(relativePath, String(repeating: "x", count: byteCount), under: root)
    }

    @MainActor static func byteCount(of relativePath: String, under root: URL) throws -> Int {
        try Data(contentsOf: root.appendingPathComponent(relativePath)).count
    }
}

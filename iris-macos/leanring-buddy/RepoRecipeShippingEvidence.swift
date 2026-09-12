//
//  RepoRecipeShippingEvidence.swift
//  leanring-buddy
//
//  Small, read-only signals used when more than one desktop shell is present
//  in a clone. A Tauri directory can be leftover scaffolding, so a complete
//  Electron shipping declaration is allowed to win the recipe merge. A bare
//  Electron dependency is not enough evidence to make that choice.
//

import Foundation

/// A desktop stack with an explicit, relaunchable shipping path.
nonisolated enum RepoRecipeShippingStack: String, Sendable {
    case electron
    case tauri
}

/// Packaging tools that provide a recognizable Electron artifact path.
nonisolated enum RepoRecipeElectronPackagingTool: String, Sendable, CaseIterable {
    case builder = "electron-builder"
    case forge = "electron-forge"
    case packager = "electron-packager"

    var defaultCommandLine: String {
        switch self {
        case .builder:
            return "electron-builder"
        case .forge:
            return "electron-forge make"
        case .packager:
            return "electron-packager"
        }
    }
}

/// The minimum independent declarations needed to call Electron the shipping
/// stack. The main file must exist in the clone, and the package must declare
/// one unambiguous packaging path. This intentionally does not inspect
/// node_modules or execute a script.
nonisolated struct RepoRecipeElectronShippingEvidence: Sendable, Equatable {
    let hasElectronDependency: Bool
    let entrypointRelativePath: String?
    let packagingScriptName: String?
    let packagingTool: RepoRecipeElectronPackagingTool?
    let hasPackagingConfiguration: Bool
    let hasAmbiguousPackagingTools: Bool

    var isStrong: Bool {
        hasElectronDependency
            && entrypointRelativePath != nil
            && (packagingScriptName != nil || hasPackagingConfiguration)
            && !hasAmbiguousPackagingTools
    }

    /// Inspect a parsed root package manifest and the files it names. All
    /// file reads use RepoRecipeFiles, so a manifest cannot widen inspection
    /// outside the clone.
    static func inspect(
        packageJSON: [String: Any],
        repoRootPath: String
    ) -> Self {
        let dependencies = dependencyNames(in: packageJSON)
        let hasElectronDependency = dependencies.contains("electron")

        let entrypointRelativePath: String?
        if let rawMain = packageJSON["main"] as? String {
            let main = rawMain.trimmingCharacters(in: .whitespacesAndNewlines)
            entrypointRelativePath = main.isEmpty || !mainFileIsReadable(
                main,
                repoRootPath: repoRootPath
            ) ? nil : main
        } else {
            entrypointRelativePath = nil
        }

        var declaredConfigurationTools: [RepoRecipeElectronPackagingTool] = []
        for (relativePath, tool) in knownConfigurationPaths {
            if RepoRecipeFiles.fileExists(relativePath, underRepoRoot: repoRootPath) {
                declaredConfigurationTools.append(tool)
            }
        }

        // electron-builder also accepts a `build` object in package.json.
        // Restrict this check to its distinctive keys so an ordinary lifecycle
        // script or arbitrary metadata cannot become packaging evidence.
        if let buildConfiguration = packageJSON["build"] as? [String: Any],
           buildConfiguration.keys.contains(where: builderConfigurationKeys.contains) {
            declaredConfigurationTools.append(.builder)
        }

        let scripts = (packageJSON["scripts"] as? [String: Any]) ?? [:]
        var scriptTools: [RepoRecipeElectronPackagingTool] = []
        var scriptToolByName: [(name: String, tools: [RepoRecipeElectronPackagingTool])] = []
        for (name, rawScript) in scripts {
            guard let script = rawScript as? String else { continue }
            let tools = packagingTools(inScript: script)
            guard !tools.isEmpty else { continue }
            scriptTools.append(contentsOf: tools)
            scriptToolByName.append((name: name, tools: tools))
        }

        let allTools = declaredConfigurationTools + scriptTools
        let distinctToolRawValues = Set(allTools.map(\.rawValue))
        let packagingTool = distinctToolRawValues.count == 1
            ? allTools.first
            : nil
        let packagingScriptName = packagingScriptName(in: scriptToolByName, packagingTool: packagingTool)
        let hasTauriPackagingSignal = scripts.values
            .compactMap { $0 as? String }
            .contains(where: containsTauriPackagingInvocation)

        let hasAmbiguousPackagingTools = distinctToolRawValues.count > 1
            || scriptToolByName.contains { $0.tools.count > 1 }
            || hasTauriPackagingSignal
        let hasPackagingConfiguration = !declaredConfigurationTools.isEmpty

        return Self(
            hasElectronDependency: hasElectronDependency,
            entrypointRelativePath: entrypointRelativePath,
            packagingScriptName: packagingScriptName,
            packagingTool: packagingTool,
            hasPackagingConfiguration: hasPackagingConfiguration,
            hasAmbiguousPackagingTools: hasAmbiguousPackagingTools
        )
    }

    // MARK: - Declarative signal parsing

    private static let knownConfigurationPaths: [(String, RepoRecipeElectronPackagingTool)] = [
        ("electron-builder.yml", .builder),
        ("electron-builder.yaml", .builder),
        ("electron-builder.json", .builder),
        ("electron-builder.js", .builder),
        ("electron-builder.cjs", .builder),
        ("electron-builder.mjs", .builder),
        ("forge.config.js", .forge),
        ("forge.config.cjs", .forge),
        ("forge.config.mjs", .forge),
        ("forge.config.ts", .forge),
    ]

    private static let builderConfigurationKeys: Set<String> = [
        "appId", "appImage", "artifactName", "directories", "dmg", "files",
        "linux", "mac", "nsis", "productName", "publish", "win"
    ]

    private static let preferredPackagingScriptNames = ["dist:mac", "build:mac", "package:mac", "dist", "package", "make"]

    private static func dependencyNames(in packageJSON: [String: Any]) -> Set<String> {
        var names = Set<String>()
        for section in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
            guard let dependencies = packageJSON[section] as? [String: Any] else { continue }
            names.formUnion(dependencies.keys)
        }
        return names
    }

    private static func mainFileIsReadable(_ relativePath: String, repoRootPath: String) -> Bool {
        // readText distinguishes a regular UTF-8 entry file from a directory,
        // while retaining the detector's size and containment checks.
        RepoRecipeFiles.readText(relativePath, underRepoRoot: repoRootPath) != nil
    }

    private static func packagingTools(
        inScript script: String
    ) -> [RepoRecipeElectronPackagingTool] {
        var foundTools = [RepoRecipeElectronPackagingTool]()
        for segment in commandSegments(in: script) {
            let words = shellWords(in: segment)
            guard let firstWord = words.first?.lowercased(),
                  firstWord != "echo",
                  firstWord != ":" else { continue }
            for tool in RepoRecipeElectronPackagingTool.allCases
            where toolInvocationIsFirstCommand(tool, words: words) {
                if !foundTools.contains(tool) { foundTools.append(tool) }
            }
        }
        return foundTools
    }

    private static func packagingScriptName(
        in scriptTools: [(name: String, tools: [RepoRecipeElectronPackagingTool])],
        packagingTool: RepoRecipeElectronPackagingTool?
    ) -> String? {
        guard let packagingTool else { return nil }
        let candidates = scriptTools.filter { $0.tools.contains(packagingTool) }
        for preferredName in preferredPackagingScriptNames {
            if candidates.contains(where: { $0.name == preferredName }) {
                return preferredName
            }
        }
        // Do not interpolate an arbitrary manifest key into a shell command.
        // A recognized name is optional because the safe tool default remains
        // usable when a project calls its packaging script something unusual.
        return nil
    }

    private static func commandSegments(in script: String) -> [String] {
        // This is a conservative evidence detector, not a shell parser.
        // Quoted commands require investigation rather than guessing whether
        // a tool name is executable code or merely printed text.
        guard !script.contains("\""), !script.contains("'"), !script.contains("`"),
              !script.contains("$(") else { return [] }
        return script.split { $0 == ";" || $0 == "&" || $0 == "|" || $0.isNewline }
            .map(String.init)
    }

    private static func shellWords(in segment: String) -> [String] {
        segment.split { $0.isWhitespace || $0 == "'" || $0 == "\"" }
            .map(String.init)
    }

    private static func toolInvocationIsFirstCommand(
        _ tool: RepoRecipeElectronPackagingTool,
        words: [String]
    ) -> Bool {
        guard !words.isEmpty else { return false }
        let normalizedWords = words.map { word in
            (word as NSString).lastPathComponent.lowercased()
        }
        if normalizedWords.first == tool.rawValue { return true }
        // Package runners may invoke a local binary as the next meaningful
        // word. Keep this allowlist narrow so prose such as `echo tool` does
        // not become shipping evidence.
        let launcherWords: Set<String> = ["npx", "pnpm", "yarn", "bun", "npm", "exec", "run", "--"]
        guard let launcher = normalizedWords.first, launcherWords.contains(launcher),
              normalizedWords.dropFirst().drop(while: launcherWords.contains).first == tool.rawValue
        else { return false }
        return true
    }

    private static func containsTauriPackagingInvocation(_ script: String) -> Bool {
        for segment in commandSegments(in: script) {
            let words = shellWords(in: segment).map { ($0 as NSString).lastPathComponent.lowercased() }
            guard !words.isEmpty, words.first != "echo" else { continue }
            let launchers: Set<String> = ["npx", "pnpm", "yarn", "bun", "npm", "exec", "run", "--"]
            let invocation = words.drop(while: launchers.contains)
            if invocation.first == "tauri" && invocation.dropFirst().contains("build") { return true }
            if words.first == "cargo",
               words.dropFirst().contains("tauri"),
               words.dropFirst().contains("build") { return true }
        }
        return false
    }
}

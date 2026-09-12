import Foundation

/// Reads only public model metadata from the CLI cache. No login material,
/// instructions, network requests, or model calls are needed for this picker.
nonisolated struct CodexEditModelOption: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
}

nonisolated struct CodexEditModelCatalog: Equatable, Sendable {
    let models: [CodexEditModelOption]
    let fetchedAt: String?

    static let maximumCacheBytes = 2_000_000

    static func read(from directory: String) -> Self {
        let path = (directory as NSString).appendingPathComponent("models_cache.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumCacheBytes,
              let data = FileManager.default.contents(atPath: path) else {
            return Self(models: [], fetchedAt: nil)
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> Self {
        guard data.count <= maximumCacheBytes,
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = document["models"] as? [[String: Any]] else {
            return Self(models: [], fetchedAt: nil)
        }
        var seen = Set<String>()
        let models = entries.compactMap { entry -> CodexEditModelOption? in
            guard entry["visibility"] as? String == "list",
                  let identifier = entry["slug"] as? String,
                  CodexEditModelSelection.isValidIdentifier(identifier),
                  seen.insert(identifier).inserted else { return nil }
            // The identifier stays authoritative even if a future display label
            // contains markup, instructions, or control characters.
            let label = (entry["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeLabel = label.flatMap { candidate -> String? in
                guard !candidate.isEmpty, candidate.count <= 80,
                      candidate.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
                return candidate
            }
            return CodexEditModelOption(id: identifier, displayName: safeLabel ?? identifier)
        }
        return Self(models: models, fetchedAt: document["fetched_at"] as? String)
    }
}

nonisolated enum CodexEditModelSelection {
    static let defaultsKey = "irisCodexEditModel"

    static func isValidIdentifier(_ identifier: String) -> Bool {
        identifier.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$", options: .regularExpression)
            == identifier.startIndex..<identifier.endIndex
    }

    static func selectedModel(in defaults: UserDefaults = .standard) -> String? {
        let selection = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return selection.isEmpty ? nil : selection
    }

    static func requestedModelLabel(_ model: String?) -> String {
        guard let model else { return "CLI default (model not reported)" }
        return isValidIdentifier(model) ? "Requested: \(model)" : "Invalid model selection"
    }
}

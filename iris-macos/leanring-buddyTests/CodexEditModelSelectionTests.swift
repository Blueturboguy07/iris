import Foundation
import Testing
#if canImport(Iris)
@testable import Iris
#else
@testable import IrisUsability
#endif

struct CodexEditModelSelectionTests {
    @Test(arguments: ["gpt-5.6-sol", "model_2", "vendor/model:variant", String(repeating: "a", count: 128)])
    func acceptsPlainModelIdentifiers(_ identifier: String) {
        #expect(CodexEditModelSelection.isValidIdentifier(identifier))
    }

    @Test(arguments: ["", "--model", "model name", "model\n", "model;touch", "$(command)", "model\u{0}", String(repeating: "a", count: 129)])
    func rejectsCommandsControlsAndOversizedIdentifiers(_ identifier: String) {
        #expect(!CodexEditModelSelection.isValidIdentifier(identifier))
    }

    @Test func defaultIsHonestAboutAnUnreportedRuntimeModel() {
        #expect(CodexEditModelSelection.requestedModelLabel(nil) == "CLI default (model not reported)")
        #expect(CodexEditModelSelection.requestedModelLabel("gpt-test") == "Requested: gpt-test")
        #expect(CodexEditModelSelection.requestedModelLabel("--invalid") == "Invalid model selection")
    }

    @Test func selectionPersistsWithoutSilentlyReplacingInvalidChoices() throws {
        let suite = "iris-model-selection-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CodexEditModelSelection.selectedModel(in: defaults) == nil)
        defaults.set("  gpt-test  ", forKey: CodexEditModelSelection.defaultsKey)
        #expect(CodexEditModelSelection.selectedModel(in: defaults) == "gpt-test")
        defaults.set("not a model", forKey: CodexEditModelSelection.defaultsKey)
        #expect(CodexEditModelSelection.selectedModel(in: defaults) == "not a model")
        defaults.set("  ", forKey: CodexEditModelSelection.defaultsKey)
        #expect(CodexEditModelSelection.selectedModel(in: defaults) == nil)
    }

    @Test func catalogFiltersHiddenDuplicateAndInvalidModels() {
        let data = Data(#"{"fetched_at":"test-time","models":[{"slug":"visible","display_name":"Visible model","visibility":"list"},{"slug":"hidden","visibility":"hide"},{"slug":"visible","visibility":"list"},{"slug":"--bad","visibility":"list"},{"slug":"missing-visibility"}]}"#.utf8)
        let catalog = CodexEditModelCatalog.parse(data)
        #expect(catalog.models == [CodexEditModelOption(id: "visible", displayName: "Visible model")])
        #expect(catalog.fetchedAt == "test-time")
    }

    @Test func unsafeDisplayLabelFallsBackToTheIdentifier() {
        let data = Data(#"{"models":[{"slug":"safe-model","display_name":"bad\nlabel","visibility":"list"}]}"#.utf8)
        #expect(CodexEditModelCatalog.parse(data).models.first?.displayName == "safe-model")
    }

    @Test(arguments: ["", "not JSON", "[]", "{}", #"{"models":null}"#])
    func malformedCacheIsAnEmptyCatalog(_ input: String) {
        #expect(CodexEditModelCatalog.parse(Data(input.utf8)).models.isEmpty)
    }

    @Test func oversizedCacheIsRejected() {
        let data = Data(repeating: 32, count: CodexEditModelCatalog.maximumCacheBytes + 1)
        #expect(CodexEditModelCatalog.parse(data).models.isEmpty)
    }

    @Test func missingCacheStillAllowsDefaultAndCustomSelection() {
        let missingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(CodexEditModelCatalog.read(from: missingDirectory.path).models.isEmpty)
    }
}

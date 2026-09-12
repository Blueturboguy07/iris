import SwiftUI

/// A project-edit setting, deliberately separate from the general-help model.
struct CodexEditModelPicker: View {
    var isCompact = false
    @AppStorage(CodexEditModelSelection.defaultsKey) private var selectedModel = ""
    @State private var catalog = CodexEditModelCatalog(models: [], fetchedAt: nil)
    @State private var customModel = ""
    @State private var isShowingCustomEntry = false
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                if !isCompact {
                    Text("Model")
                        .font(DS.Typography.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                Menu {
                    Button { select("") } label: {
                        if selectedModel.isEmpty {
                            Label("Codex default", systemImage: "checkmark")
                        } else {
                            Text("Codex default")
                        }
                    }
                    ForEach(catalog.models) { model in
                        Button {
                            select(model.id)
                        } label: {
                            if selectedModel == model.id {
                                Label(model.displayName, systemImage: "checkmark")
                            } else {
                                Text(model.displayName)
                            }
                        }
                    }
                    Divider()
                    Button("Enter model ID…") {
                        customModel = selectedModel
                        isShowingCustomEntry = true
                    }
                    Button("Reload CLI catalog") { reloadCatalog() }
                } label: {
                    Text((isCompact ? "Edit model: " : "")
                         + (selectedModel.isEmpty ? "Codex default" : selectedModel))
                        .font(DS.Typography.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(DS.Colors.ink)
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Codex model for project edits")
                .help("Applies to the next project edit. General help is unchanged.")
                .pointerCursor()
                if !isCompact { Spacer(minLength: 0) }
            }
            if isShowingCustomEntry {
                HStack {
                    TextField("Model ID", text: $customModel)
                        .textFieldStyle(.plain)
                        .font(DS.Typography.label)
                        .onSubmit { saveCustomModel() }
                    Button("Save") { saveCustomModel() }.irisTinyButton()
                    Button("Cancel") {
                        isShowingCustomEntry = false
                        validationMessage = nil
                    }.irisTextButton()
                }
            }
            if let validationMessage {
                Text(validationMessage).font(DS.Typography.caption).foregroundColor(DS.Colors.amber)
            } else if !isCompact || catalog.models.isEmpty {
                Text(catalog.models.isEmpty
                    ? "No CLI catalog yet. Use the default or enter a model ID."
                    : "Choices come from the CLI's cached catalog. Availability can change.")
                    .font(DS.Typography.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { reloadCatalog() }
    }

    private func select(_ identifier: String) {
        selectedModel = identifier
        isShowingCustomEntry = false
        validationMessage = nil
    }

    private func saveCustomModel() {
        let identifier = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CodexEditModelSelection.isValidIdentifier(identifier) else {
            validationMessage = "Enter a model ID, not a command. Use Codex default to clear the override."
            return
        }
        select(identifier)
    }

    private func reloadCatalog() {
        catalog = CodexEditModelCatalog.read(from: CodexCLILogin.codexHomeDirectory())
    }
}

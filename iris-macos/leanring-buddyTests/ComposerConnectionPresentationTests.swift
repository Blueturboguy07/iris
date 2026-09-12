import Testing
#if canImport(Iris)
@testable import Iris
#else
@testable import IrisUsability
#endif

struct ComposerConnectionPresentationTests {
    @Test func unavailableScreenHelpCannotSendButAnEditRemainsUsable() {
        #expect(!ComposerConnectionPresentation.canSendTypedRequest(
            hasText: true, requestIsBeingSizedUp: false, context: .screenHelp, helpIsAvailable: false
        ))
        #expect(ComposerConnectionPresentation.canSendTypedRequest(
            hasText: true, requestIsBeingSizedUp: false, context: .projectEdit, helpIsAvailable: false
        ))
    }

    @Test func emptyAndAlreadySizingRequestsRemainDisabled() {
        #expect(!ComposerConnectionPresentation.canSendTypedRequest(
            hasText: false, requestIsBeingSizedUp: false, context: .projectEdit, helpIsAvailable: true
        ))
        #expect(!ComposerConnectionPresentation.canSendTypedRequest(
            hasText: true, requestIsBeingSizedUp: true, context: .projectEdit, helpIsAvailable: true
        ))
        #expect(ComposerConnectionPresentation.canSendTypedRequest(
            hasText: true, requestIsBeingSizedUp: false, context: .screenHelp, helpIsAvailable: true
        ))
    }

    @Test func codexOnlyExplainsItsWorkingConnectionWithoutImpersonatingScreenHelp() {
        let presentation = ComposerConnectionPresentation.resolve(
            context: .screenHelp, help: .unavailable, editing: .codex, codexIsConnected: true
        )
        #expect(presentation.connectionLabel == "Screen help not connected")
        #expect(presentation.inlineMessage == "Codex is connected for app edits. Screen help needs a separate connection.")
        #expect(!presentation.showsModelControl)
        #expect(presentation.settingsLinkLabel == "Connect screen help")
    }

    @Test func codexOnlyAppEditingDoesNotNagForAnUnrelatedHelpConnection() {
        let presentation = ComposerConnectionPresentation.resolve(
            context: .projectEdit, help: .unavailable, editing: .codex, codexIsConnected: true
        )
        #expect(presentation.connectionLabel == "Codex connected for app edits")
        #expect(presentation.showsModelControl)
        #expect(presentation.inlineMessage == nil)
        #expect(presentation.settingsLinkLabel == nil)
    }

    @Test func fundedHelpOnlyIsNotMistakenForAnEditingProvider() {
        let help = ComposerConnectionPresentation.resolve(
            context: .screenHelp, help: .publik, editing: .unavailable, codexIsConnected: false
        )
        let edit = ComposerConnectionPresentation.resolve(
            context: .projectEdit, help: .publik, editing: .unavailable, codexIsConnected: false
        )
        #expect(help.connectionLabel == "Screen help through publik")
        #expect(help.showsModelControl)
        #expect(help.settingsLinkLabel == nil)
        #expect(!edit.showsModelControl)
        #expect(edit.inlineMessage == "Screen help is connected. App edits need an editing provider.")
        #expect(edit.settingsLinkLabel == "Connect app editing")
    }

    @Test func bothConnectionsShowOnlyTheCurrentContextsProvider() {
        let help = ComposerConnectionPresentation.resolve(
            context: .screenHelp, help: .publik, editing: .codex, codexIsConnected: true
        )
        let edit = ComposerConnectionPresentation.resolve(
            context: .projectEdit, help: .publik, editing: .codex, codexIsConnected: true
        )
        #expect(help.connectionLabel == "Screen help through publik")
        #expect(edit.connectionLabel == "Codex connected for app edits")
        #expect(help.inlineMessage == nil && edit.inlineMessage == nil)
        #expect(help.settingsLinkLabel == nil && edit.settingsLinkLabel == nil)
    }

    @Test func noConnectionsProvideOneRelevantSettingsLink() {
        let help = ComposerConnectionPresentation.resolve(
            context: .screenHelp, help: .unavailable, editing: .unavailable, codexIsConnected: false
        )
        let edit = ComposerConnectionPresentation.resolve(
            context: .projectEdit, help: .unavailable, editing: .unavailable, codexIsConnected: false
        )
        #expect(!help.showsModelControl && !edit.showsModelControl)
        #expect(help.settingsLinkLabel == "Connect screen help")
        #expect(edit.settingsLinkLabel == "Connect app editing")
        #expect(help.inlineMessage?.contains("Codex is connected") == false)
    }

    @Test func theSelectedEditProviderWinsOverAnotherConnectedProvider() {
        let presentation = ComposerConnectionPresentation.resolve(
            context: .projectEdit, help: .anthropicKey, editing: .anthropic, codexIsConnected: true
        )
        #expect(presentation.connectionLabel == "Anthropic connected for app edits")
        #expect(!presentation.connectionLabel.contains("Codex"))
    }

    @Test func flatRateClaudeLoginIsNotLabeledAsAnAPIKey() {
        let presentation = ComposerConnectionPresentation.resolve(
            context: .screenHelp, help: .claudeCodeLogin, editing: .anthropic, codexIsConnected: false
        )
        #expect(presentation.connectionLabel == "Screen help through Claude Code")
        #expect(!presentation.connectionLabel.contains("key"))
    }
}

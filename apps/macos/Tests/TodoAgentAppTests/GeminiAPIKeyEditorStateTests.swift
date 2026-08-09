import Testing
@testable import TodoAgentApp

@Suite("Gemini API key editor")
@MainActor
struct GeminiAPIKeyEditorStateTests {
    @Test("API keys are hidden and not loaded by default")
    func hiddenByDefault() {
        var loadCount = 0
        let state = GeminiAPIKeyEditorState {
            loadCount += 1
            return "saved-key-fixture"
        }

        #expect(state.isRevealed == false)
        #expect(state.fieldText.isEmpty)
        #expect(state.draftKey.isEmpty)
        #expect(state.hasDraftKey == false)
        #expect(loadCount == 0)
    }

    @Test("visibility toggles reveal and then discard the saved key")
    func togglesSavedKeyVisibility() throws {
        var loadCount = 0
        let state = GeminiAPIKeyEditorState {
            loadCount += 1
            return "saved-key-fixture"
        }

        try state.toggleVisibility()

        #expect(state.isRevealed)
        #expect(state.fieldText.isEmpty == false)
        #expect(state.draftKey.isEmpty)
        #expect(state.hasDraftKey == false)
        #expect(loadCount == 1)

        try state.toggleVisibility()

        #expect(state.isRevealed == false)
        #expect(state.fieldText.isEmpty)
        #expect(state.draftKey.isEmpty)
        #expect(state.hasDraftKey == false)
        #expect(loadCount == 1)

        try state.toggleVisibility()

        #expect(state.isRevealed)
        #expect(state.fieldText.isEmpty == false)
        #expect(state.hasDraftKey == false)
        #expect(loadCount == 2)
    }

    @Test("revealing a persisted key does not create unsaved settings changes")
    func persistedKeyIsNotADraft() throws {
        let state = GeminiAPIKeyEditorState(loadSavedKey: { "saved-key-fixture" })

        try state.toggleVisibility()

        #expect(state.fieldText.isEmpty == false)
        #expect(state.draftKey.isEmpty)
        #expect(state.hasDraftKey == false)
    }

    @Test("visibility has no save, connection-test, or Engine-injection side effects")
    func visibilityIsPresentationOnly() throws {
        let probe = KeyEditorOperationProbe()
        let state = GeminiAPIKeyEditorState {
            probe.loadCount += 1
            return "saved-key-fixture"
        }

        try state.toggleVisibility()
        try state.toggleVisibility()

        #expect(probe.loadCount == 1)
        #expect(probe.saveCount == 0)
        #expect(probe.connectionTestCount == 0)
        #expect(probe.engineInjectionCount == 0)
    }

    @Test("editing a replacement key remains dirty across visibility changes")
    func replacementKeyRemainsDraft() throws {
        var loadCount = 0
        let state = GeminiAPIKeyEditorState {
            loadCount += 1
            return "saved-key-fixture"
        }

        try state.toggleVisibility()
        state.updateFieldText(" replacement-key-fixture ")

        #expect(state.hasDraftKey)
        #expect(state.draftKey.isEmpty == false)
        #expect(state.fieldText == state.draftKey)

        try state.toggleVisibility()

        #expect(state.isRevealed == false)
        #expect(state.hasDraftKey)
        #expect(state.fieldText == state.draftKey)
        #expect(loadCount == 1)
    }

    @Test("revealing an existing replacement draft does not reload the saved key")
    func draftVisibilityDoesNotLoadSavedKey() throws {
        var loadCount = 0
        let state = GeminiAPIKeyEditorState {
            loadCount += 1
            return "saved-key-fixture"
        }
        state.updateFieldText("replacement-key-fixture")

        try state.toggleVisibility()

        #expect(state.isRevealed)
        #expect(state.hasDraftKey)
        #expect(loadCount == 0)
    }
}

@MainActor
private final class KeyEditorOperationProbe {
    var loadCount = 0
    var saveCount = 0
    var connectionTestCount = 0
    var engineInjectionCount = 0
}

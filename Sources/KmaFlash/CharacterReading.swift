import Foundation
import FlashCore

extension AppModel {
    var characterRecords: [ReadingRecord] {
        guard !characterName.isEmpty else { return [] }
        return chapterRecords.filter { $0.action == .character && $0.characterName == characterName }
    }
    var bookCharacters: [BookCharacter] { digest?.content.characterItems ?? [] }
    func engageCharacter(_ name: String) {
        guard !isBusy, !digestGenerating else { return }
        characterName = name; characterQuestion = ""; characterError = nil; streamingText = ""
        companionOpen = true; companionPane = "对话"; characterChatNonce = UUID()
    }
    func disengageCharacter() {
        if isBusy && action == .character { cancelGeneration() }
        characterName = ""; characterQuestion = ""; characterError = nil; streamingText = ""
    }
    func askCharacter(_ name: String, question: String) {
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !digestGenerating, !prompt.isEmpty, !name.isEmpty,
              let document = activeDocument, let chapter = activeChapter, let config = selectedModel else { return }
        characterName = name; characterQuestion = prompt; characterError = nil
        companionOpen = true; companionPane = "对话"; action = .character
        let personaID = activePersona?.id ?? "通用陪读人"
        let messages = PromptBuilder.characterMessages(document: document, chapter: chapter, name: name, question: prompt, records: state.records)
        isBusy = true; streamingText = ""; taskLabel = "\(name)正在回应…"
        let token = UUID(); generationID = token
        generation = Task { [weak self] in
            guard let self else { return }
            defer { if generationID == token { isBusy = false; generationID = nil; generation = nil } }
            do {
                let answer = try await ModelClient.complete(config: config, messages: messages) { [self] delta in await self.appendDelta(delta, token: token) }
                try Task.checkCancellation(); guard generationID == token else { return }
                var record = ReadingRecord(documentID: document.id, chapterID: chapter.id, personaID: personaID, modelName: config.name, action: .character, question: prompt, answer: answer)
                record.characterName = name; state.records.append(record)
                if persist() { streamingText = ""; characterQuestion = "" }
            } catch {
                guard generationID == token, !Task.isCancelled else { return }
                characterError = error.localizedDescription
            }
        }
    }
}

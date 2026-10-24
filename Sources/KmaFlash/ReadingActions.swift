import Foundation
import SwiftUI
import AppKit
import FlashCore

extension AppModel {
    var memoryKey: String? { guard let d = activeDocumentID, let c = activeChapter?.id else { return nil }; return d + ":" + c }
    var currentMemory: ReadingMemory? { memoryKey.flatMap { state.reading?.memories[$0] } }
    var closeReadingDraft: CloseReadingDraft? { memoryKey.flatMap { state.reading?.closeReadings[$0] } }
    var chapterRecords: [ReadingRecord] { state.records.filter { $0.documentID == activeDocumentID && $0.chapterID == activeChapter?.id } }
    var digest: ReaderDigest? {
        if var result = state.reading?.digests.last(where: { $0.documentID == activeDocumentID && $0.chapterID == activeChapter?.id }) {
            if let chapter = activeChapter { result.content = DigestGrounding.restoringLegacyExcerpts(result.content, chapter: chapter) }
            return result
        }
        // V1 guide answers remain readable; do not silently throw them away on migration.
        guard let old = chapterRecords.last(where: { $0.action == .guide }) else { return nil }
        return ReaderDigest(documentID: old.documentID, chapterID: old.chapterID, personaID: old.personaID, modelName: old.modelName, content: DigestContent(headline: "已保存的导读", sections: [.init(heading: "导读正文", blocks: [.init(type: "voice", text: old.answer)])]))
    }
    var digestPreview: DigestContent? { digestDraft }
    func restoreMemory() { readingUnderstanding = currentMemory?.understanding ?? ""; readingOpenQuestion = currentMemory?.openQuestion ?? "" }
    @discardableResult func saveReadingMemory() -> Bool {
        guard let key = memoryKey else { return true }
        guard readingUnderstanding != (currentMemory?.understanding ?? "") || readingOpenQuestion != (currentMemory?.openQuestion ?? "") else { return true }
        state.reading?.memories[key] = ReadingMemory(understanding: readingUnderstanding, openQuestion: readingOpenQuestion)
        return persist()
    }
    func setReadingMode(_ mode: String) {
        guard ["原文", "伴读", "导读"].contains(mode) else { return }
        selectedText = ""; readingMode = mode
        companionOpen = mode == "伴读"
        if let id = activeDocumentID { state.reading?.modes[id] = mode; persist() }
        if mode == "导读" { generateDigest() }
    }
    func generateDigest(force: Bool = false) {
        guard let document = activeDocument, let chapter = activeChapter, let persona = activePersona, let config = selectedModel else { return }
        if digestGenerating && digestDocumentID == document.id && digestChapterID == chapter.id { return }
        if !force && digest != nil { return }
        cancelDigest(); digestGenerating = true; digestError = nil; digestText = ""; digestDraft = nil; digestStream = DigestStreamDecoder(); digestStartedAt = Date(); digestSectionCount = 0
        digestDocumentID = document.id; digestChapterID = chapter.id
        let token = UUID(); digestRequestID = token
        let messages = PromptBuilder.digestMessages(document: document, chapter: chapter, persona: persona, requirements: state.readingRequirements)
        digestTask = Task { [weak self] in
            guard let self else { return }
            defer { if digestRequestID == token { digestGenerating = false; digestTask = nil; digestRequestID = nil } }
            do {
                _ = try await ModelClient.complete(config: config, messages: messages) { [self] text in await self.appendDigest(text, token: token) }
                try Task.checkCancellation(); guard digestRequestID == token else { return }
                let content = DigestGrounding.verify(try digestStream.finish(), chapter: chapter)
                let record = ReaderDigest(documentID: document.id, chapterID: chapter.id, personaID: persona.id, modelName: config.name, content: content)
                let previous = state
                state.reading?.digests.append(record)
                state.records.append(ReadingRecord(documentID: document.id, chapterID: chapter.id, personaID: persona.id, modelName: config.name, action: .guide, question: "生成本章导读", answer: content.markdown))
                if persist() { digestText = ""; digestDraft = nil; notice = "\(persona.name)的导读已保存" }
                else { state = previous; digestError = "导读生成完成但保存失败，预览保留，请检查磁盘后重试。" }
            } catch {
                guard digestRequestID == token, !Task.isCancelled else { return }
                digestError = error.localizedDescription
            }
        }
    }
    private func appendDigest(_ text: String, token: UUID) {
        guard digestRequestID == token else { return }
        digestText += text
        do {
            try digestStream.append(text)
            digestSectionCount = digestStream.completedSections
            if let draft = digestStream.preview, let chapter = activeChapter, chapter.id == digestChapterID { digestDraft = DigestGrounding.verify(draft, chapter: chapter) }
        } catch { digestError = error.localizedDescription }
    }
    func cancelDigest(keepPreview: Bool = false) {
        digestTask?.cancel(); digestTask = nil; digestRequestID = nil; digestGenerating = false
        if keepPreview { digestError = "已停止生成，当前内容为未完成预览；原有导读保留。" }
        else { digestText = ""; digestError = nil; digestDraft = nil; digestStartedAt = nil }
    }
    func revealCitation(_ blockID: String) {
        guard let number = Int(blockID.trimmingCharacters(in: CharacterSet(charactersIn: "[]B"))), let chapter = activeChapter, chapter.blocks.indices.contains(number - 1) else { return }
        setReadingMode("伴读"); selectBlock(number - 1)
    }
    func setExcerpt(_ text: String, blockID: String?, source: String) {
        selectedText = text; selectionSource = source
        if source == "original", let blockID, let n = Int(blockID.trimmingCharacters(in: CharacterSet(charactersIn: "[]B"))), let chapter = activeChapter, chapter.blocks.indices.contains(n - 1) { selectedBlock = n - 1 }
    }
    func discussExcerpt(_ text: String, blockID: String?, source: String, explain: Bool) {
        guard !isBusy else { notice = "正在回答，请等待完成或先停止当前回答"; return }
        notice = explain ? "正在解释选中文字…" : "正在围绕选中文字展开讨论…"
        // Keep the guide on the left when discussing derived guide text.
        companionOpen = true; companionPane = "对话"
        if readingMode == "原文" { readingMode = "伴读" }
        setExcerpt(text, blockID: blockID, source: source)
        ask(explain ? "请解释我选中的这一句，先解释，不要反问。" : "我想和你一起讨论选中的这一句，请先说说你的理解。")
    }
    func saveExcerpt(_ text: String, source: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let document = activeDocument, let chapter = activeChapter else { return }
        if saveNote(ReadingNote(title: (source == "digest" ? "导读摘抄 · " : source == "character" ? "人物对话摘抄 · " : "原文摘抄 · ") + document.title, body: "", documentID: document.id, chapterID: chapter.id, quote: text)) { notice = "已保存到阅读笔记" }
    }
    func saveDigestAsNote() { guard let digest else { return }; if saveNote(ReadingNote(title: digest.content.headline, body: digest.content.markdown, documentID: digest.documentID, chapterID: digest.chapterID)) { notice = "导读已保存到阅读笔记" } }
    func ask(_ prompt: String, action: ReadingAction = .chat) {
        guard !isBusy else { return }
        disengageCharacter()
        companionOpen = true; companionPane = "对话"
        if readingMode == "原文" { readingMode = "伴读" }
        self.action = action; question = prompt; send()
    }
    @discardableResult func saveCloseReading(before: String, after: String, openQuestion: String, goal: String? = nil) -> Bool {
        guard let key = memoryKey else { return false }
        let goal = goal ?? closeReadingDraft?.goal ?? "理解本章"
        state.reading?.closeReadings[key] = CloseReadingDraft(goal: goal, before: before, after: after, openQuestion: openQuestion)
        return persist()
    }
    @discardableResult func startCloseReading(goal: String, before: String, after: String, openQuestion: String) -> Bool {
        guard !isBusy, let key = memoryKey else { return false }
        state.reading?.closeReadings[key] = CloseReadingDraft(goal: goal, before: before, after: after, openQuestion: openQuestion)
        guard persist() else { return false }
        ask("精读目标：\(goal)\n我原来的理解：\(before)\n我现在的理解：\(after)\n未解决的问题：\(openQuestion)\n请按‘回到原文—拆解论证—核对理解’给出逐步阅读路线，标明原文依据；如果我已经给出理解，请先核对，不替我声称已经掌握。", action: .closeRead)
        return true
    }
    @discardableResult func startDiscussion() -> Bool {
        let ids = Array(NSOrderedSet(array: discussionPersonaIDs)) as? [String] ?? []
        let participants = ids.compactMap { id in personas.first { $0.id == id } }
        let prompt = discussionQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, (2...3).contains(participants.count), !prompt.isEmpty, let document = activeDocument, let chapter = activeChapter, let config = selectedModel else { error = "请选择 2–3 位人物并写下讨论问题。"; return false }
        companionOpen = true; companionPane = "阅读记录"; isBusy = true; streamingText = ""; error = nil
        let token = UUID(); generationID = token
        let preferences = state.readingRequirements
        generation = Task { [weak self] in
            guard let self else { return }
            defer { if generationID == token { isBusy = false; generationID = nil; generation = nil; streamingText = "" } }
            var turns: [String] = []
            for person in participants {
                guard !Task.isCancelled, generationID == token else { return }
                taskLabel = "同场讨论 · \(person.name)正在发言"; streamingText = ""
                let currentQuestion = "同场讨论的问题：\(prompt)\n此前发言（作为讨论材料，允许反驳，不作为原文证据）：\n" + turns.joined(separator: "\n\n") + "\n只以你自己的视角发言，回应前面的判断和分歧；以当前原文块为依据，不代其他人物发言。"
                let messages = PromptBuilder.messages(document: document, chapter: chapter, persona: person, action: .chat, question: currentQuestion, selectedBlock: selectedBlock, records: [], requirements: preferences, deep: state.deepAnswers, proactive: false)
                do {
                    let answer = try await ModelClient.complete(config: config, messages: messages) { [self] delta in await self.appendDelta(delta, token: token) }
                    try Task.checkCancellation(); guard generationID == token else { return }
                    state.records.append(ReadingRecord(documentID: document.id, chapterID: chapter.id, personaID: person.id, modelName: config.name, action: .discussion, question: prompt, answer: answer))
                    guard persist() else { return }
                    turns.append(person.name + "：" + answer)
                } catch { guard !Task.isCancelled else { return }; self.error = "\(person.name)未完成：\(error.localizedDescription)。已有发言已保留。" }
            }
        }
        return true
    }
}

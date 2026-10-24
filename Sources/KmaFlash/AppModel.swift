import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FlashCore

@MainActor
final class AppModel: ObservableObject {
    @Published var state = LibraryState()
    @Published var personas: [Persona] = []
    private var builtinModels: [ModelConfiguration] = []
    @Published var selection = "书房"
    @Published var activeDocumentID: String?
    @Published var search = ""
    @Published var showImport = false
    @Published var showPersonas = false
    @Published var showSettings = false
    @Published var error: String?
    private var noticeDismissTask: Task<Void, Never>?
    @Published var notice: String? {
        didSet {
            noticeDismissTask?.cancel()
            guard let notice, notice.contains("保存到阅读笔记") else { return }
            noticeDismissTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                self?.notice = nil
            }
        }
    }
    @Published var isBusy = false
    @Published var streamingText = ""
    @Published var question = ""
    @Published var action: ReadingAction = .chat
    @Published var selectedBlock: Int?
    @Published var taskLabel = ""
    @Published var testingModel = false
    @Published var readingMode = "伴读"
    @Published var companionOpen = true
    @Published var companionPane = "对话"
    @Published var selectedText = ""
    @Published var selectionSource = "original"
    @Published var focusedBlockID = ""
    @Published var showCloseReading = false
    @Published var showDiscussion = false
    @Published var digestGenerating = false
    @Published var digestText = ""
    @Published var digestDraft: DigestContent?
    @Published var digestStartedAt: Date?
    @Published var digestSectionCount = 0
    var digestStream = DigestStreamDecoder()
    @Published var importing = false
    @Published var importProgress: Double?
    @Published var importStatus = ""
    @Published var importDetail = ""
    @Published var digestError: String?
    @Published var discussionPersonaIDs: [String] = []
    @Published var discussionQuestion = ""
    @Published var characterName = ""
    @Published var characterQuestion = ""
    @Published var characterError: String?
    @Published var characterChatNonce = UUID()
    @Published var readingUnderstanding = ""
    @Published var readingOpenQuestion = ""
    var pendingHomePersonaID: String? { get { state.reading?.pendingHomePersonaID } set { state.reading?.pendingHomePersonaID = newValue } }
    var digestTask: Task<Void, Never>?
    var digestRequestID: UUID?
    var digestDocumentID: String?
    var digestChapterID: String?
    let store: LocalStore
    var generation: Task<Void, Never>?
    var generationID: UUID?
    private var loadFailed = false
    var lastRequest: (documentID: String, chapterID: String, personaID: String, action: ReadingAction, question: String, block: Int?, excerpt: String, source: String, mode: String)?

    init(directory: URL? = nil) {
        let isolated = directory ?? ProcessInfo.processInfo.environment["KMA_FLASH_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        store = LocalStore(directory: isolated)
        do {
            personas = try Builtins.personas()
            builtinModels = try Builtins.models()
            if let saved = try store.load() {
                if saved.reading == nil {
                    let migrationBackup = store.directory.appendingPathComponent("library.before-reading-upgrade.json")
                    if !FileManager.default.fileExists(atPath: migrationBackup.path) { try FileManager.default.copyItem(at: store.fileURL, to: migrationBackup) }
                }
                state = saved; state.upgradeReadingState()
                try store.save(state)
            }
            else {
                state.upgradeReadingState()
                try store.save(state)
            }
        } catch {
            loadFailed = true
            self.error = "未能加载数据。为保护原文件，已暂停写入。\(error.localizedDescription) 可打开数据目录检查 library.json 和备份。"
        }
    }
    var models: [ModelConfiguration] {
        builtinModels + state.customModels.map { saved in var copy = saved; copy.apiKey = KeychainStore.read(saved.id); return copy }
    }
    var activeDocument: ReadingDocument? { state.documents.first { $0.id == activeDocumentID } }
    var activeChapter: Chapter? { guard let document = activeDocument, document.chapters.indices.contains(document.chapterIndex) else { return nil }; return document.chapters[document.chapterIndex] }
    var activePersona: Persona? { personas.first { $0.id == (activeDocument?.personaID ?? state.selectedPersonaID) } ?? personas.first(where: { $0.id == "通用陪读人" }) ?? personas.first }
    var activeRecords: [ReadingRecord] { state.records.filter { $0.documentID == activeDocumentID && $0.chapterID == activeChapter?.id && $0.personaID == activePersona?.id && $0.action != .character } }
    var selectedModel: ModelConfiguration? { models.first { $0.id == state.selectedModelID } ?? models.first }

    func savePreferences() { persist() }
    @discardableResult func persist() -> Bool {
        guard !loadFailed else { error = "当前数据未成功加载，暂不能保存。请先恢复数据文件后重新启动。"; return false }
        do { try store.save(state); return true }
        catch { self.error = "保存失败：\(error.localizedDescription)。请保留应用开启，检查磁盘空间与目录权限后重试。"; return false }
    }
    func showDataFolder() { NSWorkspace.shared.open(store.directory) }
    func openDocument(_ id: String, chapterID: String? = nil) {
        guard let index = state.documents.firstIndex(where: { $0.id == id }) else { error = "原材料已删除。"; return }
        guard saveReadingMemory() else { return }
        cancelGeneration()
        if digestDocumentID != id || (chapterID != nil && digestChapterID != chapterID) { cancelDigest() }
        activeDocumentID = id; selection = "书房"; question = ""; streamingText = ""; selectedText = ""; characterName = ""; characterQuestion = ""; characterError = nil
        if let chapterID, let chapterIndex = state.documents[index].chapters.firstIndex(where: { $0.id == chapterID }) { state.documents[index].chapterIndex = chapterIndex; state.documents[index].blockIndex = 0 }
        state.documents[index].chapterIndex = min(max(0, state.documents[index].chapterIndex), max(0, state.documents[index].chapters.count - 1))
        let choice = pendingHomePersonaID ?? state.reading?.documentPersonas[id] ?? state.selectedPersonaID
        let validChoice = personas.contains(where: { $0.id == choice }) ? choice : "通用陪读人"
        state.documents[index].personaID = validChoice
        state.reading?.documentPersonas[id] = validChoice
        pendingHomePersonaID = nil
        state.documents[index].lastOpenedAt = Date()
        selectedBlock = state.documents[index].blockIndex
        focusedBlockID = "B\(state.documents[index].blockIndex + 1)"
        readingMode = state.reading?.modes[id] ?? "伴读"; companionOpen = readingMode == "伴读"
        restoreMemory(); persist()
        if state.documents[index].engineering == nil && readingMode == "导读" && digest == nil { generateDigest() }
    }
    func closeReader() {
        guard saveReadingMemory() else { return }
        cancelGeneration(); disengageCharacter(); activeDocumentID = nil; selectedBlock = nil; selectedText = ""; readingUnderstanding = ""; readingOpenQuestion = ""
    }
    func changeChapter(_ index: Int) {
        guard let i = state.documents.firstIndex(where: { $0.id == activeDocumentID }), state.documents[i].chapters.indices.contains(index), saveReadingMemory() else { return }
        cancelGeneration(); cancelDigest(); streamingText = ""; question = ""; selectedBlock = 0; selectedText = ""; characterName = ""; characterQuestion = ""; characterError = nil; focusedBlockID = "B1"
        state.documents[i].chapterIndex = index; state.documents[i].blockIndex = 0; restoreMemory(); persist()
        if readingMode == "导读" { generateDigest() }
    }
    func selectBlock(_ index: Int) {
        guard let i = state.documents.firstIndex(where: { $0.id == activeDocumentID }), let chapter = activeChapter, chapter.blocks.indices.contains(index) else { return }
        selectedBlock = index; focusedBlockID = "B\(index + 1)"; state.documents[i].blockIndex = index
        if persist() { notice = "已记录阅读位置" }
    }
    @discardableResult func selectPersona(_ id: String) -> Bool {
        guard !isBusy, personas.contains(where: { $0.id == id }) else { return false }
        if activeDocumentID != nil && activePersona?.id == id { return true }
        let previous = state
        let oldPending = pendingHomePersonaID
        if let i = state.documents.firstIndex(where: { $0.id == activeDocumentID }) {
            cancelDigest(); state.documents[i].personaID = id; state.reading?.documentPersonas[state.documents[i].id] = id
        } else {
            state.selectedPersonaID = id; pendingHomePersonaID = id
        }
        state.recentPersonaIDs.removeAll { $0 == id }; state.recentPersonaIDs.insert(id, at: 0)
        state.recentPersonaIDs = Array(state.recentPersonaIDs.prefix(6))
        guard persist() else { state = previous; pendingHomePersonaID = oldPending; return false }
        streamingText = ""; selectedText = ""; characterName = ""; characterQuestion = ""; characterError = nil
        notice = activeDocumentID == nil ? "已选择\(id)，下次打开读物时生效" : "已切换为\(id)；已有导读保留，可手动重新生成"
        return true
    }
    func toggleFavorite(_ id: String) {
        if state.favoritePersonaIDs.contains(id) { state.favoritePersonaIDs.removeAll { $0 == id } } else { state.favoritePersonaIDs.append(id) }
        persist()
    }
    func selectModel(_ id: String) { guard models.contains(where: { $0.id == id }) else { return }; state.selectedModelID = id; persist() }
    func importFiles() { showImport = true }
    func importFiles(_ urls: [URL]) {
        guard !importing, !urls.isEmpty else { return }
        importing = true; importProgress = 0; importStatus = "准备导入"; importDetail = ""; error = nil
        Task {
            defer { importing = false }
            var imported = 0
            for (index, url) in urls.enumerated() {
                importStatus = "正在导入 \(index + 1) / \(urls.count)：\(url.lastPathComponent)"
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    var document = try await Task.detached {
                        try TextImporter.file(url) { value in
                            Task { @MainActor in
                                guard self.importing else { return }
                                let progress = (Double(index) + value.fraction) / Double(urls.count)
                                if progress >= (self.importProgress ?? 0) { self.importProgress = progress; self.importDetail = value.detail }
                            }
                        }
                    }.value
                    document.personaID = state.selectedPersonaID
                    state.documents.insert(document, at: 0); imported += 1
                    importProgress = Double(index + 1) / Double(urls.count)
                } catch { self.error = "\(url.lastPathComponent)：\(error.localizedDescription)" }
            }
            if imported > 0, persist() { if error == nil { showImport = false }; notice = "已导入 \(imported) 份材料" }
        }
    }
    func importText(title: String, text: String) {
        guard !importing else { return }
        importing = true; importProgress = nil; importStatus = "正在整理文字与章节"; importDetail = ""; error = nil
        Task {
            defer { importing = false }
            let chapters = await Task.detached { TextImporter.chapters(text) }.value
            guard !chapters.isEmpty else { error = "请先粘贴正文。"; return }
            var document = ReadingDocument(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名材料" : title, source: "粘贴文本", chapters: chapters)
            document.personaID = state.selectedPersonaID
            state.documents.insert(document, at: 0)
            if persist() { showImport = false; notice = "材料已加入书房" }
        }
    }
    func importURL(_ text: String) async {
        guard !importing else { return }
        importing = true; importProgress = nil; importStatus = "正在连接网页"; importDetail = "等待网页返回正文"; error = nil
        defer { importing = false }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { error = "请输入完整的 http 或 https 网页链接。"; return }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 35
            request.setValue("Mozilla/5.0 KmaFlash/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw FlashError.message("网页无法访问，请将正文复制后导入。") }
            guard data.count < 10_000_000 else { throw FlashError.message("网页过大，请复制正文后导入。") }
            importStatus = "正在解析网页正文"; importDetail = "已接收 \(data.count / 1024) KB"
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard contentType.contains("text/") else { throw FlashError.message("此链接不是可解析网页，请下载文件后导入。") }
            let (title, chapters) = try await Task.detached { () throws -> (String, [Chapter]) in
            var html = String(data: data, encoding: .utf8) ?? ""
            let titleRegex = try NSRegularExpression(pattern: "(?is)<title[^>]*>(.*?)</title>")
            var title = url.host ?? "网页材料"
            if let match = titleRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let range = Range(match.range(at: 1), in: html) { title = String(html[range]) }
            for pattern in ["(?is)<script\\b[^>]*>.*?</script>", "(?is)<style\\b[^>]*>.*?</style>", "(?is)<(nav|footer|header)\\b[^>]*>.*?</\\1>"] { html = html.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
            html = html.replacingOccurrences(of: "(?i)</(p|div|section|article|h[1-6])>", with: "\n\n", options: .regularExpression).replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            // Strip markup without loading external resources or executing scripts.
            var plain = html.replacingOccurrences(of: "(?s)<[^>]+>", with: "", options: .regularExpression)
            for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] { plain = plain.replacingOccurrences(of: entity, with: value) }
            plain = plain.replacingOccurrences(of: "\\n[ \\t]*\\n(?:[ \\t]*\\n)+", with: "\n\n", options: .regularExpression)
            let sourceText = plain
            let chapters = TextImporter.chapters(sourceText)
            guard plain.trimmingCharacters(in: .whitespacesAndNewlines).count > 80, !chapters.isEmpty else { throw FlashError.message("网页正文不足，可能需要登录或动态加载。请复制正文后导入。") }
                return (title, chapters)
            }.value
            var document = ReadingDocument(title: title, source: url.absoluteString, chapters: chapters)
            document.personaID = state.selectedPersonaID; state.documents.insert(document, at: 0)
            if persist() { showImport = false; notice = "已导入网页；请核对正文是否完整" }
        } catch { self.error = error.localizedDescription }
    }
    func deleteDocument(_ id: String) {
        if activeDocumentID == id { closeReader() }
        state.documents.removeAll { $0.id == id }
        // Notes and historical answers stay available even after removing a source.
        persist()
    }
    func send() {
        if action == .guide { setReadingMode("导读"); return }
        guard saveReadingMemory() else { return }
        guard !isBusy, let document = activeDocument, let chapter = activeChapter, let persona = activePersona, let config = selectedModel else { return }
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || action != .chat else { error = "写下你想问的问题，或选择导读、精读等能力。"; return }
        let requestedAction = action
        lastRequest = (document.id, chapter.id, persona.id, requestedAction, prompt, selectedBlock, selectedText, selectionSource, readingMode)
        let participants = personas.filter { ["费曼", "苏格拉底式导师"].contains($0.id) }
        let messages = PromptBuilder.messages(document: document, chapter: chapter, persona: persona, action: requestedAction, question: prompt, selectedBlock: selectedBlock, records: state.records, requirements: state.readingRequirements, deep: state.deepAnswers, proactive: state.proactive, participants: participants, excerpt: selectedText, excerptSource: selectionSource, memory: currentMemory)
        isBusy = true; streamingText = ""; error = nil; taskLabel = "\(persona.name)正在\(requestedAction.rawValue)"
        let token = UUID(); generationID = token
        generation = Task { [weak self] in
            guard let self else { return }
            defer { if generationID == token { isBusy = false; generation = nil; generationID = nil } }
            do {
                let answer = try await ModelClient.complete(config: config, messages: messages) { [self] delta in
                    await self.appendDelta(delta, token: token)
                }
                try Task.checkCancellation()
                guard generationID == token else { return }
                let record = ReadingRecord(documentID: document.id, chapterID: chapter.id, personaID: persona.id, modelName: config.name, action: requestedAction, question: prompt.isEmpty ? requestedAction.rawValue : prompt, answer: answer)
                state.records.append(record)
                if persist() { question = ""; streamingText = "" }
            } catch {
                guard generationID == token, !Task.isCancelled else { return }
                self.error = "\(error.localizedDescription) 可点击“重试”。"
            }
        }
    }
    func appendDelta(_ delta: String, token: UUID) { if generationID == token { streamingText += delta } }
    func cancelGeneration() { generation?.cancel(); generation = nil; generationID = nil; isBusy = false; taskLabel = "" }
    func retryLast() {
        if lastRequest == nil { send(); return }
        if restoreLastRequest() { send() }
    }
    @discardableResult func restoreLastRequest() -> Bool {
        guard let last = lastRequest else { return false }
        guard let original = state.documents.first(where: { $0.id == last.documentID }), original.chapters.contains(where: { $0.id == last.chapterID }) else { error = "上次请求的原材料或章节已删除，请对当前材料重新提问。"; return false }
        openDocument(last.documentID, chapterID: last.chapterID)
        guard activeDocumentID == last.documentID, activeChapter?.id == last.chapterID, selectPersona(last.personaID) else { return false }
        selectedBlock = last.block; selectedText = last.excerpt; selectionSource = last.source; readingMode = last.mode; companionOpen = true; action = last.action; question = last.question
        return true
    }
    func saveRecordAsNote(_ record: ReadingRecord) {
        if saveNote(ReadingNote(title: "\(record.action.rawValue) · \(record.characterName ?? record.personaID)", body: record.answer, documentID: record.documentID, chapterID: record.chapterID, quote: record.question)) { notice = "已保存到阅读笔记" }
    }
    func saveSelectionAsNote() {
        guard let doc = activeDocument, let chapter = activeChapter, let block = selectedBlock, chapter.blocks.indices.contains(block) else { error = "先点击原文中的一段。"; return }
        if saveNote(ReadingNote(title: "摘录 · \(doc.title)", body: "", documentID: doc.id, chapterID: chapter.id, quote: chapter.blocks[block])) { notice = "选段已保存到阅读笔记" }
    }
    @discardableResult func saveNote(_ note: ReadingNote) -> Bool {
        var updated = note; updated.updatedAt = Date()
        if let index = state.notes.firstIndex(where: { $0.id == note.id }) { state.notes[index] = updated } else { state.notes.insert(updated, at: 0) }
        return persist()
    }
    func deleteNote(_ id: String) { state.notes.removeAll { $0.id == id }; persist() }
    func exportNote(_ note: ReadingNote) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = note.title.replacingOccurrences(of: "/", with: "-") + ".md"; panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let source = state.documents.first { $0.id == note.documentID }?.title ?? ""
        let text = "# \(note.title)\n\n" + (source.isEmpty ? "" : "来源：\(source)\n\n") + (note.quote.isEmpty ? "" : "> " + note.quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n") + note.body
        do { try text.write(to: url, atomically: true, encoding: .utf8); notice = "笔记已导出" } catch { self.error = error.localizedDescription }
    }
    func saveModel(_ config: ModelConfiguration) -> Bool {
        do {
            _ = try ModelClient.request(config: config, messages: [], stream: false)
            guard !builtinModels.contains(where: { $0.id == config.id }) else { throw FlashError.message("请复制内置配置为自定义模型后保存。") }
            let previousState = state
            let previousKey = KeychainStore.read(config.id)
            try KeychainStore.save(config.apiKey, id: config.id)
            var saved = config; saved.apiKey = ""
            if let i = state.customModels.firstIndex(where: { $0.id == saved.id }) { state.customModels[i] = saved } else { state.customModels.append(saved) }
            state.selectedModelID = saved.id
            if persist() { notice = "模型配置已保存"; return true }
            state = previousState
            if previousKey.isEmpty { KeychainStore.delete(config.id) } else { try KeychainStore.save(previousKey, id: config.id) }
            return false
        } catch { self.error = error.localizedDescription; return false }
    }
    func deleteModel(_ id: String) {
        guard state.customModels.contains(where: { $0.id == id }) else { return }
        state.customModels.removeAll { $0.id == id }
        if state.selectedModelID == id { state.selectedModelID = builtinModels.first?.id ?? "" }
        if persist() { KeychainStore.delete(id) }
    }
    func testModel(_ config: ModelConfiguration) async {
        guard !testingModel else { return }
        testingModel = true; defer { testingModel = false }
        do {
            let result = try await ModelClient.complete(config: config, messages: [.init(role: "user", content: "请只回复：连接成功")]) { _ in }
            notice = "\(config.name)：\(String(result.prefix(80)))"
        } catch { self.error = error.localizedDescription }
    }
}

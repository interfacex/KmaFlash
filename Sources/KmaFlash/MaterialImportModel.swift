import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FlashCore

@MainActor
final class MaterialImportModel: ObservableObject {
    @Published var drafts: [MaterialDraft] = []
    @Published var intake = "file"
    @Published var link = ""
    @Published var bodyText = ""
    @Published var title = ""
    @Published var showTasks = false
    @Published var error: String?
    private unowned let app: AppModel
    private var tasks: [String: Task<Void, Never>] = [:]
    init(app: AppModel) {
        self.app = app
        drafts = app.state.engineering?.drafts ?? []
        for i in drafts.indices where ["recognizing", "importing"].contains(drafts[i].status) {
            drafts[i].status = "interrupted"; drafts[i].detail = "上次处理已中断，点击重试继续。"
        }
    }
    var busy: Bool { !tasks.isEmpty }
    var directory: URL { app.store.directory.appendingPathComponent("materials", isDirectory: true) }
    @discardableResult func save() -> Bool {
        if app.state.engineering == nil { app.state.engineering = EngineeringState() }
        app.state.engineering?.drafts = drafts
        let success = app.persist()
        if !success { error = "导入任务保存失败，请检查磁盘空间和目录权限后重试。" }
        return success
    }
    func update(_ id: String, _ edit: (inout MaterialDraft) -> Void, saveChanges: Bool = true) {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return }
        edit(&drafts[i]); if saveChanges { save() }
    }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .plainText, .zip, UTType(filenameExtension: "md") ?? .data, UTType(filenameExtension: "markdown") ?? .data]
        guard panel.runModal() == .OK else { return }; receive(panel.urls)
    }
    func receive(_ urls: [URL]) {
        for url in urls {
            let draft = MaterialDraft(title: url.deletingPathExtension().lastPathComponent, source: url.lastPathComponent)
            drafts.insert(draft, at: 0)
            run(draft.id) { [self] id in
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let target = directory.appendingPathComponent(id, isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let copy = target.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: copy)
                update(id) { $0.localFile = copy.path }
                try await recognizeFile(copy, id: id)
            }
        }
    }
    func recognizeText() {
        guard !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = bodyText, name = title.isEmpty ? String(bodyText.prefix(30)) : title
        var draft = MaterialDraft(title: name, source: "粘贴文字")
        draft.pastedText = text
        drafts.insert(draft, at: 0)
        run(draft.id) { [self] id in try await parseText(text, title: name, id: id) }
    }
    private func parseText(_ text: String, title: String, id: String) async throws {
        let chapters = try await worker { try Task.checkCancellation(); return TextImporter.chapters(text) }
        guard !chapters.isEmpty else { throw FlashError.message("没有可阅读的正文。") }
        update(id) { $0.document = ReadingDocument(title: title, source: "粘贴文字", chapters: chapters); $0.kind = MaterialRecognition.kind(text: text, source: ""); $0.fingerprint = MaterialRecognition.fingerprint(Data(text.utf8)) }
    }
    private func worker<T>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }

    func recognizeLink() {
        let input = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let draft = MaterialDraft(title: input, source: input)
        drafts.insert(draft, at: 0)
        run(draft.id) { [self] id in try await fetchLink(input, id: id) }
    }
    private func fetchLink(_ input: String, id: String) async throws {
        let target = directory.appendingPathComponent(id, isDirectory: true)
        let result = try await MaterialLink.fetch(input, directory: target) { [weak self] progress in
            Task { @MainActor in self?.progress(id, progress) }
        }
        if let file = result.localFile {
            update(id) { $0.localFile = file.path }
            try Task.checkCancellation()
            try await recognizeFile(file, id: id)
            update(id) { $0.root = result.target.prefix ?? $0.root; $0.title = result.target.title; $0.kind = result.target.kind }
        } else if let document = result.document {
            update(id) { $0.document = document; $0.title = document.title; $0.kind = result.target.kind; $0.fingerprint = MaterialRecognition.fingerprint(Data(document.chapters.map(\.text).joined().utf8)) }
        } else { throw FlashError.message("链接没有返回可阅读的材料。") }
    }
    private func run(_ id: String, operation: @escaping @MainActor (String) async throws -> Void) {
        guard tasks[id] == nil else { return }
        update(id) { $0.status = "recognizing"; $0.progress = 0; $0.detail = "正在识别材料…" }
        guard save() else { update(id, { $0.status = "failed"; $0.detail = "任务未能保存，请重试。" }, saveChanges: false); return }
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { tasks[id] = nil }
            do {
                try await operation(id); try Task.checkCancellation()
                update(id) { $0.status = "waiting_user"; $0.progress = 1; $0.detail = "识别完成，请确认阅读材料。" }
            } catch is CancellationError { update(id) { $0.status = "cancelled"; $0.detail = "已取消，可重试。" } }
            catch { update(id) { $0.status = Task.isCancelled ? "cancelled" : "failed"; $0.detail = Task.isCancelled ? "已取消，可重试。" : error.localizedDescription } }
        }
    }
    private func progress(_ id: String, _ value: ImportProgress) {
        guard tasks[id] != nil, let draft = drafts.first(where: { $0.id == id }), draft.status == "recognizing" else { return }
        update(id, { $0.progress = max($0.progress, value.fraction); $0.detail = value.detail }, saveChanges: false)
    }
    private func recognizeFile(_ url: URL, id: String) async throws {
        let isZIP = url.pathExtension.lowercased() == "zip"
        let result = try await worker { () throws -> (ReadingDocument?, CodeArchiveIndex?, String) in
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 100_000_000 else { throw FlashError.message("文件超过 100 MB，请拆分后导入。") }
            let hash = MaterialRecognition.fingerprint(try Data(contentsOf: url, options: .mappedIfSafe))
            if isZIP { return (nil, try CodeArchive(url: url).index(), hash) }
            return (try TextImporter.file(url) { [weak self] value in Task { @MainActor in self?.progress(id, value) } }, nil, hash)
        }
        try Task.checkCancellation()
        update(id) { draft in
            draft.fingerprint = result.2; draft.archive = result.1; draft.document = result.0
            if let archive = result.1 {
                draft.kind = "code"; draft.root = archive.suggestedRoot == "." ? "" : archive.suggestedRoot
                if archive.languages.isEmpty && archive.roots.isEmpty { draft.kind = "tech" }
                draft.title = url.deletingPathExtension().lastPathComponent
            } else if let document = result.0 {
                draft.title = document.title; draft.kind = MaterialRecognition.kind(text: document.chapters.prefix(3).map(\.text).joined(separator: "\n"), source: draft.source)
            }
        }
    }
    func cancel(_ id: String) { tasks[id]?.cancel() }
    func retry(_ id: String) {
        guard let draft = drafts.first(where: { $0.id == id }) else { return }
        run(id) { [self] id in
            if let file = draft.localFile {
                try await recognizeFile(URL(fileURLWithPath: file), id: id)
                if !draft.fingerprint.isEmpty { update(id) { $0.title = draft.title; $0.root = draft.root == "." ? "" : draft.root; $0.kind = draft.kind } }
                if draft.fingerprint.isEmpty, draft.source.hasPrefix("https://"), let target = try? MaterialLink.recognize(draft.source) {
                    update(id) { $0.title = target.title; $0.root = target.prefix ?? $0.root; $0.kind = target.kind }
                }
            }
            else if let text = draft.pastedText { try await parseText(text, title: draft.title, id: id) }
            else if draft.source.hasPrefix("https://") { try await fetchLink(draft.source, id: id) }
            else if draft.document != nil { return }
            else { throw FlashError.message("请重新选择原文件或粘贴正文。") }
        }
    }
    func scope(_ draft: MaterialDraft) -> String {
        let root = draft.root == "." ? "" : draft.root
        return draft.splitProjects == true && draft.kind == "code" ? "split:" + (draft.archive?.roots.filter { $0 != "." && !$0.isEmpty }.sorted().joined(separator: "|") ?? "") : root
    }
    func duplicate(_ draft: MaterialDraft) -> ReadingDocument? {
        guard !draft.fingerprint.isEmpty else { return nil }
        return app.state.documents.first { $0.fingerprint == draft.fingerprint && ($0.materialKind ?? "book") == draft.kind && ($0.importScope ?? $0.engineering?.root ?? "") == scope(draft) }
    }
    func remove(_ id: String) {
        guard tasks[id] == nil, drafts.contains(where: { $0.id == id }) else { return }
        let previous = drafts
        drafts.removeAll { $0.id == id }
        guard save() else { drafts = previous; app.state.engineering?.drafts = previous; return }
        let folder = directory.appendingPathComponent(id, isDirectory: true).standardizedFileURL
        let referenced = app.state.documents.compactMap { $0.engineering?.archiveFile } + drafts.compactMap(\.localFile)
        if !referenced.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path.hasPrefix(folder.path + "/") }) {
            do { if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) } }
            catch { self.error = "任务已移除，但临时文件清理失败：" + error.localizedDescription }
        }
    }
    func openDuplicate(_ draft: MaterialDraft) { if let doc = duplicate(draft) { app.showImport = false; app.openDocument(doc.id) } }
    func confirm(_ id: String) {
        guard var draft = drafts.first(where: { $0.id == id }), tasks[id] == nil, draft.status == "waiting_user", duplicate(draft) == nil else { return }
        if draft.root == "." { draft.root = "" }
        let selectedDraft = draft
        update(id) { $0.status = "importing"; $0.detail = "正在保存到书房…" }
        tasks[id] = Task { [weak self] in
            guard let self else { return }; defer { tasks[id] = nil }
            do {
                let draft = selectedDraft
                var documents: [ReadingDocument] = []
                if let index = draft.archive, let file = draft.localFile {
                    guard index.entries.contains(where: { $0.reason == nil && (draft.root.isEmpty || $0.path == draft.root || $0.path.hasPrefix(draft.root + "/")) }) else { throw FlashError.message("所选目录没有可阅读的文件，请调整目录范围。") }
                    if draft.kind == "code" {
                        let roots = draft.splitProjects == true ? index.roots.filter { !$0.isEmpty && $0 != "." } : [draft.root]
                        for root in roots {
                            guard index.entries.contains(where: { $0.reason == nil && (root.isEmpty || $0.path == root || $0.path.hasPrefix(root + "/")) }) else { continue }
                            var doc = ReadingDocument(title: roots.count > 1 ? draft.title + " · " + root : draft.title, source: draft.source, chapters: [Chapter(title: "工程概览", text: "本工程保留原始文件，进入工程工作台按目录与行号阅读源码。")])
                            doc.engineering = EngineeringProject(archiveFile: file, root: root, index: index, goal: draft.goal)
                            documents.append(doc)
                        }
                    } else {
                        documents = try await worker {
                            let archive = try CodeArchive(url: URL(fileURLWithPath: file))
                            var docs: [ReadingDocument] = []
                            let selected = index.entries.filter { entry in
                                entry.reason == nil && (draft.root.isEmpty || entry.path == draft.root || entry.path.hasPrefix(draft.root + "/")) && ["md", "markdown", "txt", "rst", "pdf"].contains((entry.path as NSString).pathExtension.lowercased())
                            }
                            guard selected.reduce(0, { $0 + $1.size }) <= 20 * 1024 * 1024 else { throw FlashError.message("所选资料展开后超过 20 MB，请选择更小的目录范围后重试。") }
                            for entry in selected {
                                try Task.checkCancellation()
                                let ext = (entry.path as NSString).pathExtension.lowercased()
                                guard ["md", "markdown", "txt", "rst", "pdf"].contains(ext) else { continue }
                                if ext == "pdf" {
                                    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                                    defer { try? FileManager.default.removeItem(at: temp) }
                                    try archive.data(path: entry.path).write(to: temp)
                                    var d = try TextImporter.file(temp); d.title = (entry.path as NSString).lastPathComponent; d.source = draft.source + " / " + entry.path; docs.append(d)
                                } else {
                                    let text = try archive.text(path: entry.path)
                                    let chapters = TextImporter.chapters(text)
                                    if !chapters.isEmpty { docs.append(ReadingDocument(title: (entry.path as NSString).lastPathComponent, source: draft.source + " / " + entry.path, chapters: chapters)) }
                                }
                            }
                            guard !docs.isEmpty else { throw FlashError.message("此压缩包没有所选类型的文档，请选择“软件工程”。") }
                            return docs
                        }
                    }
                } else if var doc = draft.document { doc.title = draft.title; if let start = draft.startingChapterID, let chapter = doc.chapters.firstIndex(where: { $0.id == start }) { doc.chapterIndex = chapter }; documents = [doc] }
                guard !documents.isEmpty else { throw FlashError.message("没有可保存的材料。") }
                try Task.checkCancellation()
                for i in documents.indices { documents[i].importScope = scope(draft); documents[i].materialKind = draft.kind; documents[i].fingerprint = draft.fingerprint; documents[i].personaID = app.state.selectedPersonaID }
                let previousDocuments = app.state.documents, previousDrafts = drafts
                app.state.documents.insert(contentsOf: documents, at: 0)
                update(id, { $0.status = "completed"; $0.progress = 1; $0.detail = "已加入书房 · \(documents.count) 份材料"; $0.documentIDs = documents.map(\.id) }, saveChanges: false)
                guard save() else {
                    app.state.documents = previousDocuments; drafts = previousDrafts; app.state.engineering?.drafts = previousDrafts
                    throw FlashError.message("保存失败，请重试。")
                }
                showTasks = true
                app.notice = "已导入 \(draft.title)"
            } catch is CancellationError { update(id) { $0.status = "cancelled"; $0.detail = "已取消，可重试。" } }
            catch { update(id) { $0.status = Task.isCancelled ? "cancelled" : "failed"; $0.detail = Task.isCancelled ? "已取消，可重试。" : error.localizedDescription } }
        }
    }
    func open(_ draft: MaterialDraft, mode: String = "原文") {
        if let doc = app.state.documents.first(where: { draft.documentIDs?.contains($0.id) == true }) ?? duplicate(draft) { app.showImport = false; app.openDocument(doc.id, chapterID: draft.startingChapterID); if doc.engineering == nil { app.setReadingMode(mode) } }
    }
}
private extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }

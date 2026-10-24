import SwiftUI
import AppKit
import FlashCore

private let forest = KmaTheme.primary
private let paper = KmaTheme.background

struct RootView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            Group {
                if let document = app.activeDocument, document.engineering != nil { EngineeringReaderContainer(app: app, documentID: document.id).id(document.id) }
                else if app.activeDocument != nil { ReaderView() }
                else if app.selection == "阅读记录" { HistoryView() }
                else if app.selection == "阅读笔记" { NotesView() }
                else { LibraryView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(app.activeDocument?.title ?? "同页")
        }
        .background(paper).tint(forest).preferredColorScheme(.light)
        .frame(minWidth: 1080, minHeight: 720)
        .sheet(isPresented: $app.showImport) { MaterialImportView(app: app) }
        .sheet(isPresented: $app.showPersonas) { PersonasView() }
        .sheet(isPresented: $app.showSettings) { SettingsView() }
        .alert("遇到一点问题", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) { Button("知道了") { app.error = nil } } message: { Text(app.error ?? "") }
        .overlay(alignment: .bottom) {
            if app.importing && !app.showImport { ImportProgressView().frame(width: 430).padding(20) }
            else if app.digestGenerating && app.activeDocument == nil {
                HStack(spacing: 12) { ProgressView().controlSize(.small); Text("本章导读仍在生成").font(.callout); Button("查看导读") { if let id = app.digestDocumentID { app.openDocument(id); app.setReadingMode("导读") } } }.padding(12).background(.regularMaterial, in: Capsule()).padding(20)
            } else if let notice = app.notice, !notice.contains("保存到阅读笔记") { Text(notice).font(.callout).padding(12).background(.regularMaterial, in: Capsule()).padding(20).onTapGesture { app.notice = nil } }
        }
        .overlay(alignment: .top) {
            if let notice = app.notice, notice.contains("保存到阅读笔记") {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20, weight: .semibold))
                    Text("已保存到阅读笔记").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 13)
                .background(Color(red: 0.12, green: 0.34, blue: 0.29), in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(.top, 16).allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: app.notice)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let url = Bundle.main.url(forResource: "TongyeMark", withExtension: "png"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().frame(width: 48, height: 48).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("同页").font(.system(size: 22, weight: .semibold))
                    Text("人物相伴 · 阅读有得").font(.system(size: 11)).foregroundStyle(KmaTheme.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.bottom, 26)
            ForEach([("书房", "books.vertical"), ("阅读记录", "clock"), ("阅读笔记", "square.and.pencil")], id: \.0) { item in
                Button { app.closeReader(); app.selection = item.0 } label: {
                    Label(item.0 == "阅读记录" ? "共读记录" : item.0, systemImage: item.1).font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(app.selection == item.0 ? forest.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            }
            Spacer()
            Text("和有见识的人物一起读，读到不懂，随时聊").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).padding(.bottom, 12)
            Button { app.showSettings = true } label: { Label("模型设置", systemImage: "slider.horizontal.3").padding(.vertical, 12) }.buttonStyle(.plain)
            Text("本地书房 · 私人收藏").font(.caption2).foregroundStyle(.tertiary)
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity).background(paper).foregroundStyle(forest)
    }
}

private struct LibraryView: View {
    @EnvironmentObject var app: AppModel
    @State private var deleting: ReadingDocument?
    private var documents: [ReadingDocument] { app.state.documents.filter { app.search.isEmpty || $0.title.localizedCaseInsensitiveContains(app.search) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack { VStack(alignment: .leading, spacing: 8) { Text("我的书房").font(.system(size: 30, weight: .semibold, design: .serif)); Text("从一页文字开始，走向更深的理解。").foregroundStyle(.secondary) }; Spacer(); Button { app.showImport = true } label: { Label("导入阅读", systemImage: "plus").padding(5) }.buttonStyle(.borderedProminent) }
                HStack(spacing: 30) {
                    VStack(alignment: .leading, spacing: 14) { Text("让好问题，带你读进去。").font(.system(size: 29, weight: .medium, design: .serif)); Text("选择一位思想伙伴，在原文中寻找证据，\n在对话中形成自己的认识。").font(.body).lineSpacing(7).opacity(0.8); Text("当前陪读 · " + (app.activePersona?.name ?? "通用陪读人")).font(.headline); Button("选择陪读人物  →") { app.showPersonas = true }.buttonStyle(.bordered).tint(.white) }
                    Spacer(); Image(systemName: "text.book.closed").font(.system(size: 88, weight: .ultraLight)).rotationEffect(.degrees(-10)).opacity(0.55)
                }.foregroundStyle(.white).padding(32).frame(maxWidth: .infinity, alignment: .leading).background(forest, in: RoundedRectangle(cornerRadius: 20))
                if let recent = app.state.documents.filter({ $0.lastOpenedAt != nil }).sorted(by: { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }).first {
                    HStack { VStack(alignment: .leading, spacing: 6) { Text("继续阅读").font(.caption).foregroundStyle(.secondary); Text(recent.title).font(.headline); if recent.chapters.indices.contains(recent.chapterIndex) { Text(recent.chapters[recent.chapterIndex].title).font(.caption) } }; Spacer(); Button("回到上次阅读处") { app.openDocument(recent.id) }.buttonStyle(.borderedProminent) }.padding(20).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                }
                HStack(spacing: 35) { stat("收藏读物", app.state.documents.count); stat("阅读对话", app.state.records.count); stat("沉淀笔记", app.state.notes.count); Spacer() }
                HStack { Text("书架").font(.title2.bold()); Spacer(); TextField("搜索书名或文章", text: $app.search).textFieldStyle(.roundedBorder).frame(width: 260) }
                if documents.isEmpty { ContentUnavailableView("书房里，等待第一本书", systemImage: "books.vertical", description: Text("导入 TXT、Markdown、PDF，或粘贴文字与链接。")) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 18)], spacing: 18) {
                    ForEach(documents) { document in
                        VStack(alignment: .leading, spacing: 15) {
                                HStack { Image(systemName: "book.closed").font(.title).foregroundStyle(forest); Spacer(); Text("\(document.chapters.count) 章节").font(.caption).foregroundStyle(.secondary) }
                                Text(document.title).font(.system(size: 18, weight: .semibold, design: .serif)).lineLimit(2).frame(height: 48, alignment: .topLeading)
                                Text(document.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                ProgressView(value: document.lastOpenedAt == nil ? 0 : document.progress)
                                HStack { Text(document.lastOpenedAt == nil ? "开始阅读" : "继续阅读"); Spacer(); Image(systemName: "arrow.up.right") }.font(.caption).foregroundStyle(forest)
                            HStack { if document.engineering != nil { Button("进入工程工作台") { app.openDocument(document.id) }.buttonStyle(.borderedProminent) } else { ForEach(["原文", "伴读", "导读"], id: \.self) { mode in Button(mode) { app.openDocument(document.id); app.setReadingMode(mode) }.buttonStyle(.bordered) } } }
                            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                        .contextMenu { Button("删除读物", role: .destructive) { deleting = document } }
                    }
                }
            }.padding(36)
        }.confirmationDialog("从书房移除这份读物？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("移除读物", role: .destructive) { if let deleting { app.deleteDocument(deleting.id) }; deleting = nil }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("阅读记录与笔记仍会保留。") }
    }
    private func stat(_ label: String, _ count: Int) -> some View { HStack(alignment: .firstTextBaseline, spacing: 9) { Text("\(count)").font(.system(size: 26, weight: .medium, design: .serif)); Text(label).font(.callout).foregroundStyle(.secondary) } }
}

private struct PersonasView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var category = "全部"
    @State private var favorites = false
    @State private var focusedID: String?
    private var categories: [String] { ["全部"] + Set(app.personas.map(\.category)).sorted() }
    private var filtered: [Persona] { app.personas.filter { (category == "全部" || $0.category == category) && (!favorites || app.state.favoritePersonaIDs.contains($0.id)) && (query.isEmpty || ($0.name + $0.summary + $0.aliases.joined()).localizedCaseInsensitiveContains(query)) } }
    private var focused: Persona? { app.personas.first { $0.id == (focusedID ?? app.activePersona?.id ?? app.state.selectedPersonaID) } ?? filtered.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("选择你的阅读伙伴").font(.title2.bold()); Text("借一双不同的眼睛，重新看见文字。微调要求会用于后续对话。").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("完成") { app.savePreferences(); dismiss() } }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 12) {
                    TextField("搜索人物、思想或别名", text: $query).textFieldStyle(.roundedBorder)
                    HStack { Picker("类别", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }.labelsHidden(); Toggle("仅收藏", isOn: $favorites).toggleStyle(.checkbox) }
                    ScrollView { LazyVStack(spacing: 8) { ForEach(filtered) { persona in
                        HStack(alignment: .top) {
                            Button { focusedID = persona.id; app.selectPersona(persona.id) } label: { VStack(alignment: .leading, spacing: 6) { HStack { Text(persona.name).font(.headline); if persona.id == app.activePersona?.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(forest) } }; Text(persona.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                            Button { focusedID = persona.id } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).help("查看人物详情")
                            Button { app.toggleFavorite(persona.id) } label: { Image(systemName: app.state.favoritePersonaIDs.contains(persona.id) ? "star.fill" : "star") }.buttonStyle(.plain).foregroundStyle(forest)
                        }.padding(12).background(focused?.id == persona.id ? forest.opacity(0.1) : .white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                    } } }
                }.padding(20).frame(width: 340)
                Divider()
                ScrollView { VStack(alignment: .leading, spacing: 18) {
                    if let persona = focused {
                        Text(persona.category.uppercased()).font(.caption).foregroundStyle(forest)
                        Text(persona.name).font(.system(size: 30, weight: .medium, design: .serif))
                        Text(persona.summary).font(.headline)
                        PersonaDossierView(dossier: persona.dossier)
                        Button(persona.id == app.activePersona?.id ? "正在陪读" : "邀请陪读") { if app.selectPersona(persona.id) { dismiss() } }.buttonStyle(.borderedProminent)
                    }
                    Divider()
                    Text("我的阅读要求").font(.headline)
                    TextEditor(text: $app.state.readingRequirements).font(.callout).frame(height: 90).border(.gray.opacity(0.2))
                    Toggle("深入分析 · 更多推理与解释", isOn: $app.state.deepAnswers)
                    Toggle("允许陪读适时追问", isOn: $app.state.proactive)
                }.padding(24) }
            }
        }.disabled(app.isBusy || app.digestGenerating).frame(width: 850, height: 650).background(paper).onDisappear { app.savePreferences() }
    }
}

private struct HistoryView: View {
    @EnvironmentObject var app: AppModel
    @State private var query = ""
    @State private var documentID = "all"
    @State private var expanded: Set<String> = []
    private var recentDocuments: [ReadingDocument] { app.state.documents.filter { $0.lastOpenedAt != nil }.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) } }
    private var records: [ReadingRecord] { app.state.records.filter { (documentID == "all" || $0.documentID == documentID) && (query.isEmpty || ($0.question + $0.answer + $0.personaID).localizedCaseInsensitiveContains(query)) }.sorted { $0.createdAt > $1.createdAt } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("阅读记录").font(.system(size: 30, weight: .semibold, design: .serif))
            Text("每一次对话，都是理解走过的路。").foregroundStyle(.secondary)
            if !recentDocuments.isEmpty {
                Text("最近阅读").font(.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(recentDocuments) { document in
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(document.title).font(.callout.weight(.medium)).lineLimit(1)
                                    if document.chapters.indices.contains(document.chapterIndex) { Text(document.chapters[document.chapterIndex].title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    if let date = document.lastOpenedAt { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary) }
                                }.frame(width: 180, alignment: .leading)
                                Button("继续阅读") { app.openDocument(document.id) }.buttonStyle(.bordered)
                            }.padding(14).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
                Text("阅读对话").font(.headline)
            }
            HStack { TextField("搜索问题、回答或人物", text: $query).textFieldStyle(.roundedBorder); Picker("读物", selection: $documentID) { Text("全部读物").tag("all"); ForEach(app.state.documents) { Text($0.title).tag($0.id) } }.frame(width: 240) }
            if records.isEmpty { ContentUnavailableView("还没有阅读记录", systemImage: "clock", description: Text("在阅读页发起一次对话，记录就会保存在这里。")) }
            ScrollView { LazyVStack(alignment: .leading, spacing: 16) { ForEach(records) { record in
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(app.state.documents.first { $0.id == record.documentID }?.title ?? "已移除的读物").font(.headline); Spacer(); Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    Text(record.personaID + " · " + record.action.rawValue + " · " + record.modelName).font(.caption).foregroundStyle(forest)
                    if !record.question.isEmpty { Text(record.question).fontWeight(.medium) }
                    Text(app.state.documents.first { $0.id == record.documentID }?.chapters.first { $0.id == record.chapterID }?.title ?? "原章节已移除").font(.caption).foregroundStyle(.secondary)
                    Text(.init(record.answer)).font(.callout).lineLimit(expanded.contains(record.id) ? nil : 8).textSelection(.enabled)
                    Button(expanded.contains(record.id) ? "收起回答" : "展开完整回答") { if expanded.contains(record.id) { expanded.remove(record.id) } else { expanded.insert(record.id) } }.buttonStyle(.plain).font(.caption).foregroundStyle(forest)
                    HStack { Button("回到章节") { app.openDocument(record.documentID, chapterID: record.chapterID); app.selectPersona(record.personaID) }.disabled(!app.state.documents.contains { $0.id == record.documentID }); Button("存为笔记") { app.saveRecordAsNote(record) } }.buttonStyle(.bordered)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
            } } }
        }.padding(34)
    }
}

private struct NotesView: View {
    @EnvironmentObject var app: AppModel
    @State private var query = ""
    @State private var editing: ReadingNote?
    @State private var deleting: ReadingNote?
    private var notes: [ReadingNote] { app.state.notes.filter { query.isEmpty || ($0.title + $0.body + $0.quote).localizedCaseInsensitiveContains(query) }.sorted { $0.updatedAt > $1.updatedAt } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("阅读笔记").font(.system(size: 30, weight: .semibold, design: .serif)); Spacer(); Button { editing = ReadingNote(title: "新的阅读笔记", body: "") } label: { Label("新建笔记", systemImage: "plus") }.buttonStyle(.borderedProminent) }
            Text("把有价值的思考，留下来。").foregroundStyle(.secondary)
            TextField("搜索笔记", text: $query).textFieldStyle(.roundedBorder)
            if notes.isEmpty { ContentUnavailableView("等待一个值得留下的想法", systemImage: "square.and.pencil", description: Text("摘录原文、收藏回答，或写下自己的理解。")) }
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 270))], spacing: 16) { ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 12) {
                    Text(note.title).font(.headline).lineLimit(2)
                    Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    if !note.quote.isEmpty { Text(note.quote).font(.callout).foregroundStyle(forest).lineLimit(3) }
                    Text(note.body).font(.callout).lineLimit(6).frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                    HStack { Button("编辑") { editing = note }; Button("导出") { app.exportNote(note) }; Spacer(); Button(role: .destructive) { deleting = note } label: { Image(systemName: "trash") } }.buttonStyle(.borderless)
                }.padding(20).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
            } } }
        }.padding(34).sheet(item: $editing) { note in NoteEditor(note: note) }
        .confirmationDialog("删除这篇笔记？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除笔记", role: .destructive) { if let deleting { app.deleteNote(deleting.id) }; deleting = nil }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("此操作无法撤销，可先导出备份。") }
    }
}

private struct NoteEditor: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var note: ReadingNote
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("编辑笔记").font(.title2.bold()); Spacer(); Button("取消") { dismiss() }; Button("保存") { if app.saveNote(note) { dismiss() } }.buttonStyle(.borderedProminent) }
            TextField("笔记标题", text: $note.title).font(.title3).textFieldStyle(.roundedBorder)
            if let document = app.state.documents.first(where: { $0.id == note.documentID }) {
                HStack { VStack(alignment: .leading, spacing: 3) { Text("来源 · " + document.title).font(.caption.weight(.medium)); if let chapter = document.chapters.first(where: { $0.id == note.chapterID }) { Text(chapter.title).font(.caption).foregroundStyle(.secondary) } }; Spacer(); Button("回到原文") { if app.saveNote(note) { app.openDocument(document.id, chapterID: note.chapterID); dismiss() } } }
            }
            if !note.quote.isEmpty { Text(note.quote).font(.callout).foregroundStyle(forest).lineLimit(6).textSelection(.enabled).padding(12).background(forest.opacity(0.07), in: RoundedRectangle(cornerRadius: 8)) }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $note.body).font(.body).scrollContentBackground(.hidden)
                if note.body.isEmpty { Text("写下你的理解、疑问，或值得再次回看的想法…").foregroundStyle(.tertiary).padding(.top, 2).padding(.leading, 5).allowsHitTesting(false) }
            }.frame(minHeight: 280).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
            HStack { Text("支持 Markdown 内容").font(.caption).foregroundStyle(.secondary); Spacer(); Button("导出 Markdown") { app.exportNote(note) } }
        }.padding(24).frame(width: 640, height: 530).background(paper)
    }
}

private struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ModelConfiguration()
    @State private var headersJSON = "{}"
    @State private var validation: String?
    @State private var confirmDelete = false
    private var isBuiltin: Bool { app.models.contains { $0.id == draft.id } && !app.state.customModels.contains { $0.id == draft.id } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("模型设置").font(.title2.bold()); Text("连接你自己的模型服务，所有配置存储在本机。").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("完成") { dismiss() } }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Button { load(ModelConfiguration()) } label: { Label("添加模型", systemImage: "plus") }.buttonStyle(.borderedProminent)
                    ScrollView { VStack(spacing: 8) { ForEach(app.models) { model in
                        Button { load(model) } label: { VStack(alignment: .leading, spacing: 5) { HStack { Text(model.name).font(.headline); if model.id == app.state.selectedModelID { Image(systemName: "checkmark.circle.fill") } }; Text(model.model).font(.caption).foregroundStyle(.secondary).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(draft.id == model.id ? forest.opacity(0.1) : .white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
                    } } }
                    Button("打开本地数据目录") { app.showDataFolder() }.font(.caption)
                }.padding(20).frame(width: 240)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if isBuiltin { VStack(alignment: .leading, spacing: 10) { Text("Demo 不含 API Key，不能直接调用。请复制为自定义模型，再填写模型名称、服务地址及所需凭据。").font(.caption).foregroundStyle(.secondary); Button("复制为自定义模型") { var copy = draft; copy.id = UUID().uuidString; copy.name += "（自定义）"; load(copy) } } }
                        field("显示名称", text: $draft.name).disabled(isBuiltin)
                        field("模型 ID", text: $draft.model).disabled(isBuiltin)
                        field("Base URL", text: $draft.baseURL).disabled(isBuiltin)
                        VStack(alignment: .leading, spacing: 5) { Text("API Key").font(.caption).foregroundStyle(.secondary); SecureField("输入密钥", text: $draft.apiKey).textFieldStyle(.roundedBorder).disabled(isBuiltin) }
                        Picker("协议", selection: $draft.apiStyle) { Text("OpenAI Chat Completions").tag("chat"); Text("OpenAI Responses").tag("responses") }.disabled(isBuiltin)
                        HStack { Text("最大输出 Token"); Spacer(); TextField("8192", value: $draft.maxTokens, format: .number).textFieldStyle(.roundedBorder).frame(width: 110).disabled(isBuiltin) }
                        HStack { Text("Temperature"); Slider(value: $draft.temperature, in: 0...2, step: 0.1).disabled(isBuiltin); Text(draft.temperature.formatted(.number.precision(.fractionLength(1)))).monospacedDigit().frame(width: 30) }
                        if draft.apiStyle == "chat" { Toggle("启用深度思考（服务需支持）", isOn: $draft.thinking).disabled(isBuiltin) } else { Text("Responses 协议使用服务端的思考配置。").font(.caption).foregroundStyle(.secondary) }
                        VStack(alignment: .leading, spacing: 6) { Text("自定义请求头 · JSON 字符串字典").font(.caption).foregroundStyle(.secondary); TextEditor(text: $headersJSON).disabled(isBuiltin).font(.system(.caption, design: .monospaced)).frame(height: 85).border(.gray.opacity(0.2)) }
                        if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
                        if let error = app.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        if let notice = app.notice { Text(notice).font(.caption).foregroundStyle(forest) }
                        HStack {
                            Button(app.testingModel ? "连接中…" : "测试连接") { if let config = validated() { Task { await app.testModel(config) } } }.disabled(app.testingModel)
                            Spacer()
                            if app.state.customModels.contains(where: { $0.id == draft.id }) { Button("删除", role: .destructive) { confirmDelete = true } }
                            if isBuiltin { Button("使用此模型") { app.selectModel(draft.id) }.buttonStyle(.borderedProminent) } else { Button("保存并使用") { if let config = validated(), app.saveModel(config) { app.selectModel(config.id) } }.buttonStyle(.borderedProminent) }
                        }
                    }.padding(24)
                }
            }
        }.frame(width: 850, height: 690).background(paper).onAppear { load(app.selectedModel ?? app.models.first ?? ModelConfiguration()) }
        .confirmationDialog("删除这个自定义模型？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除模型", role: .destructive) { app.deleteModel(draft.id); load(app.models.first ?? ModelConfiguration()) }
            Button("取消", role: .cancel) {}
        }
    }
    private func field(_ label: String, text: Binding<String>) -> some View { VStack(alignment: .leading, spacing: 5) { Text(label).font(.caption).foregroundStyle(.secondary); TextField(label, text: text).textFieldStyle(.roundedBorder) } }
    private func load(_ model: ModelConfiguration) { draft = model; validation = nil; if let data = try? JSONEncoder().encode(model.headers), let text = String(data: data, encoding: .utf8) { headersJSON = text } else { headersJSON = "{}" } }
    private func validated() -> ModelConfiguration? {
        do { var result = draft; result.headers = try JSONDecoder().decode([String: String].self, from: Data(headersJSON.utf8)); validation = nil; return result }
        catch { validation = "请求头必须是 JSON 字符串字典，例如 {\"X-Project\": \"reading\"}。"; return nil }
    }
}

private struct PersonaDossierView: View {
    let dossier: String
    private var values: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(dossier.utf8))) as? [String: Any] }
    private let sections = [("identity", "人物简介"), ("era", "所处时代"), ("stance", "思想立场"), ("temperament", "性情与气质"), ("speech_style", "表达风格"), ("knowledge_boundary", "知识边界"), ("interaction_style", "对话方式"), ("judgment_habits", "判断习惯"), ("value_tensions", "价值张力"), ("sample_line", "一句话认识他"), ("interpretation_note", "史料与演绎说明")]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let values {
                ForEach(sections, id: \.0) { key, label in
                    if let text = values[key] as? String, !text.isEmpty { VStack(alignment: .leading, spacing: 6) { Text(label).font(.caption.bold()).foregroundStyle(forest); Text(text).font(.callout).lineSpacing(5).textSelection(.enabled) } }
                }
                if let events = values["life_events"] as? [[String: Any]], !events.isEmpty {
                    Text("生平与重要经历").font(.headline)
                    ForEach(events.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 5) {
                            if let period = events[index]["period"] as? String { Text(period).font(.caption.bold()).foregroundStyle(forest) }
                            if let event = events[index]["event"] as? String { Text(event).font(.callout).lineSpacing(4) }
                            if let name = events[index]["source_title"] as? String { source(name, url: events[index]["source_url"] as? String) }
                        }.padding(.leading, 10)
                    }
                }
                if let sources = values["sources"] as? [[String: Any]], !sources.isEmpty {
                    Text("参考来源").font(.headline)
                    ForEach(sources.indices, id: \.self) { index in
                        if let name = sources[index]["title"] as? String { source(name, url: sources[index]["url"] as? String) }
                    }
                }
            } else { Text(dossier).font(.callout).lineSpacing(6).textSelection(.enabled) }
        }
    }
    @ViewBuilder private func source(_ name: String, url: String?) -> some View {
        if let url, let link = URL(string: url), ["http", "https"].contains(link.scheme ?? "") { Link(name, destination: link).font(.caption) }
        else { Text(name).font(.caption).foregroundStyle(.secondary) }
    }
}

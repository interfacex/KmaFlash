import AppKit
import SwiftUI
import FlashCore

struct ReaderView: View {
    @EnvironmentObject var app: AppModel
    @State private var theme = ReaderThemeID.stored()
    @State private var textSize = ReaderTextSize.stored()
    @State private var liveSelection = ""
    @State private var liveBlock: ContentBlock?
    @State private var liveDigestBlock: DigestBlock?
    private var tokens: ReaderTokens { ReaderTokens.resolve(theme, sourceType: app.activeDocument?.source ?? "") }
    private var locked: Bool { app.isBusy || app.digestGenerating }
    private var source: String { app.readingMode == "导读" ? "digest" : "original" }
    var body: some View {
        VStack(spacing: 0) {
            libraryBar
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if app.readingMode == "导读" { digestPane } else { canvas(originalSpans, original: true) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if app.companionOpen {
                    Divider()
                    companion.frame(width: 400).background(tokens.surface)
                }
            }
        }.background(tokens.background).foregroundStyle(tokens.text)
        .navigationTitle(app.activeDocument?.title ?? "同页")
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { toolbar } }
        .sheet(isPresented: $app.showCloseReading) { CloseReadingSheet() }
        .sheet(isPresented: $app.showDiscussion) { DiscussionSheet() }
        .onChange(of: app.activeChapter?.id) { _, _ in liveSelection = ""; liveBlock = nil; liveDigestBlock = nil }
        .onChange(of: app.readingMode) { _, _ in liveSelection = ""; liveBlock = nil; liveDigestBlock = nil }
    }
    private var toolbar: some View {
        Group {
            Button { app.showPersonas = true } label: {
                HStack(spacing: 6) { Text(app.activePersona?.name ?? "通用陪读人"); Image(systemName: "chevron.down") }
            }.disabled(locked)
            Button("同场讨论") { app.showDiscussion = true }.disabled(locked)
            Button("精读") { app.showCloseReading = true }.disabled(locked)
            Button("存入笔记") { app.saveDigestAsNote() }.disabled(app.digest == nil).help("保存本章导读到阅读笔记")
            Picker("目录", selection: Binding(get: { app.activeDocument?.chapterIndex ?? 0 }, set: app.changeChapter)) {
                ForEach(Array((app.activeDocument?.chapters ?? []).enumerated()), id: \.element.id) { i, chapter in Text(chapter.title).tag(i) }
            }.labelsHidden().frame(maxWidth: 180).disabled(locked)
            Button((app.readingMode == "导读" ? "导读人物 · " : "陪读人物 · ") + (app.activePersona?.name ?? "通用陪读人")) { app.showPersonas = true }.disabled(locked)
            Picker("阅读方式", selection: Binding(get: { app.readingMode }, set: app.setReadingMode)) {
                ForEach(["原文", "伴读", "导读"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).frame(width: 174)
            Menu("阅读设置") {
                Picker("模型", selection: Binding(get: { app.state.selectedModelID }, set: app.selectModel)) { ForEach(app.models) { Text($0.name).tag($0.id) } }.disabled(locked)
                Picker("纸色", selection: $theme) { ForEach(ReaderThemeID.allCases) { Text($0.label).tag($0) } }
                Picker("字号", selection: $textSize) { ForEach(ReaderTextSize.allCases) { Text($0.label).tag($0) } }
                Button("选择陪读人物…") { app.showPersonas = true }.disabled(locked)
                Picker("回答详略", selection: $app.state.deepAnswers) { Text("简洁").tag(false); Text("深入").tag(true) }
                Picker("主动提醒", selection: $app.state.proactive) { Text("安静相伴").tag(false); Text("适时提醒").tag(true) }
            }
            Menu {
                Button("重新生成导读") { app.generateDigest(force: true) }.disabled(locked)
                Button("保存导读到笔记") { app.saveDigestAsNote() }.disabled(app.digest == nil)
                Button(app.companionOpen ? "收起对话" : "展开对话") { app.companionOpen.toggle() }
                Divider()
                Button("上一章") { app.changeChapter((app.activeDocument?.chapterIndex ?? 0) - 1) }.disabled(locked || (app.activeDocument?.chapterIndex ?? 0) == 0)
                Button("下一章") { app.changeChapter((app.activeDocument?.chapterIndex ?? 0) + 1) }.disabled(locked || (app.activeDocument?.chapterIndex ?? 0) + 1 >= (app.activeDocument?.chapters.count ?? 0))
            } label: { Image(systemName: "ellipsis") }
        }
        .onChange(of: textSize) { _, value in UserDefaults.standard.set(value.rawValue, forKey: ReaderTextSize.storageKey) }
        .onChange(of: theme) { _, value in UserDefaults.standard.set(value.rawValue, forKey: ReaderThemeID.storageKey) }
        .onChange(of: app.state.deepAnswers) { _, _ in app.savePreferences() }
        .onChange(of: app.state.proactive) { _, _ in app.savePreferences() }
    }
    private var libraryBar: some View {
        HStack(spacing: 8) {
            Button("返回书房") { app.closeReader() }
            Button("书架") { app.closeReader(); app.search = "" }
            Spacer(minLength: 0)
        }.buttonStyle(.bordered).controlSize(.small)
            .padding(.horizontal, 16).padding(.vertical, 8).background(tokens.surface)
    }
    private var originalSpans: [ReadingSpan] {
        var spans = [ReadingSpan(id: "title", text: app.activeChapter?.title ?? "", role: .title), ReadingSpan(id: "hint", text: "拖选文字即可记笔记、复制、解释或讨论；也可以右键。", role: .hint)]
        let chapter = app.activeChapter
        var lastPage: Int?
        for (i, text) in (chapter?.blocks ?? []).enumerated() {
            if let pages = chapter?.blockPageNumbers, pages.indices.contains(i), let page = pages[i], page != lastPage {
                spans.append(ReadingSpan(id: "page-\(i)", text: "第 \(page) 页", role: .caption))
                lastPage = page
            }
            spans.append(ReadingSpan(id: "B\(i + 1)", text: text, role: .body, block: ContentBlock(id: "B\(i + 1)", text: text)))
        }
        return spans
    }
    private func canvas(_ spans: [ReadingSpan], original: Bool) -> some View {
        FlowReadingCanvas(spans: spans, textColor: tokens.text, secondaryColor: tokens.secondary, accentColor: tokens.accent, backgroundColor: tokens.background, highlightColor: tokens.highlight, lineSpacing: tokens.lineSpacing, bodySize: textSize.body, bookLayout: original, highlightSpanId: original ? app.focusedBlockID : "", citationSpanId: "", scrollToSpanId: original ? app.focusedBlockID : "", onSelection: { text, block in
            liveSelection = text; liveBlock = block
            // NSTextView can publish during its own update pass.
            DispatchQueue.main.async { app.setExcerpt(text, blockID: block?.id, source: original ? "original" : "digest") }
        }, onCommand: { handle($0, source: original ? "original" : "digest") })
        .id((app.activeChapter?.id ?? "") + (original ? "-original" : "-digest"))
        
    }
    private func handle(_ command: ReadingTextCommand, source: String) {
        switch command {
        case .note(let text): app.saveExcerpt(text, source: source)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(text, forType: .string) { app.notice = "已复制选中文字" }
            else { app.error = "复制失败，请重试。" }
        case .explain(let text, let block): app.discussExcerpt(text, blockID: block?.id, source: source, explain: true)
        case .discuss(let text, let block): app.discussExcerpt(text, blockID: block?.id, source: source, explain: false)
        case .bookmark(let block): if let index = Int(block.id.dropFirst()) { app.selectBlock(index - 1) }
        }
    }
    private var digestPane: some View {
        VStack(spacing: 0) {
            if app.digestGenerating || app.digestError != nil { digestStatus }
            if let content = app.digestPreview ?? app.digest?.content {
                ThemeDigestView(content: content, tokens: tokens, chapterTitle: app.activeChapter?.title ?? "", speaker: app.digestGenerating || app.digestPreview != nil ? (app.activePersona?.name ?? "通用陪读人") : (app.personas.first { $0.id == app.digest?.personaID }?.name ?? "通用陪读人"), bodySize: textSize.body, generating: app.digestGenerating,
                    onSource: { if let id = $0.sourceBlockID { app.revealCitation(id) } },
                    onSelection: { text, block in
                        if !text.isEmpty { liveSelection = text; liveDigestBlock = block }
                        else if liveDigestBlock?.id == block.id { liveSelection = ""; liveDigestBlock = nil }
                    },
                    onCommand: { command, block in handleDigest(command, block: block) },
                    onQuestion: { app.ask($0) }, onRegenerate: { app.generateDigest(force: true) })
                    
                digestFooter(content)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    if app.digestGenerating {
                        ProgressView("正在准备本章导读…")
                        ForEach(0..<5) { index in RoundedRectangle(cornerRadius: 5).fill(tokens.secondary.opacity(0.09)).frame(maxWidth: index == 4 ? 240 : .infinity).frame(height: 13) }
                        Text("模型返回的标题与段落会逐步显示，无需等待整篇完成。").font(.caption).foregroundStyle(tokens.secondary)
                    } else { Text("听听另一种阅读视角").font(.title2); Button("生成本章导读") { app.generateDigest() }.buttonStyle(.borderedProminent).disabled(app.isBusy) }
                    Spacer()
                }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var digestStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if app.digestGenerating { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.digestGenerating ? "\(app.activePersona?.name ?? "陪读人物")正在写导读" : "导读尚未完成").font(.callout.weight(.medium))
                    Text(app.digestText.isEmpty ? "等待模型返回首段内容，原文仍可阅读。" : "已接收 \(app.digestText.count) 字符 · 已完成 \(app.digestSectionCount) 个分节，后续内容仍在补充。")
                        .font(.caption).foregroundStyle(tokens.secondary)
                }
                Spacer()
                if app.digestGenerating, let started = app.digestStartedAt { Text(started, style: .timer).monospacedDigit().font(.caption).fixedSize() }
                if app.digestGenerating { Button("停止") { app.cancelDigest(keepPreview: true) } }
                else { Button("重试") { app.generateDigest(force: true) }.disabled(app.isBusy) }
            }
            if app.digestGenerating { ProgressView().progressViewStyle(.linear) }
            if let error = app.digestError { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.horizontal, 20).padding(.vertical, 12).background(tokens.highlight.opacity(0.45))
    }
    private func handleDigest(_ command: ReadingTextCommand, block: DigestBlock) {
        let source = block.isOriginal ? "original" : "digest"
        switch command {
        case .explain(let text, _): app.discussExcerpt(text, blockID: block.sourceBlockID, source: source, explain: true)
        case .discuss(let text, _): app.discussExcerpt(text, blockID: block.sourceBlockID, source: source, explain: false)
        default: handle(command, source: source)
        }
    }
    @ViewBuilder private func digestFooter(_ content: DigestContent) -> some View {
        if !content.characterItems.isEmpty {
            Divider()
            BookCharacterStrip(items: content.characterItems, tokens: tokens).environmentObject(app)
                .padding(.horizontal, 24).padding(.vertical, 10).background(tokens.background)
        }
    }
    private var companion: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text((app.activePersona?.name ?? "通用陪读人") + " · 与你共读").font(.headline); Spacer(); Button { app.companionOpen = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起对话") }
                Text("阅读伙伴").font(.caption).foregroundStyle(tokens.secondary)
                Picker("伴读内容", selection: $app.companionPane) { Text("本章对话").tag("对话"); Text("阅读记录").tag("阅读记录") }.pickerStyle(.segmented)
            }.padding(16)
            Divider()
            if !app.characterName.isEmpty && app.companionPane == "对话" {
                ScrollView { CharacterChatPanel(tokens: tokens).environmentObject(app).padding(16) }
            } else { conversation }
            Divider()
            if app.companionPane == "阅读记录" { memoryEditor } else if app.characterName.isEmpty { composer }
        }
    }
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    let records = app.companionPane == "阅读记录" ? app.chapterRecords.filter { $0.action != .guide } : app.activeRecords.filter { $0.action != .guide }
                    if records.isEmpty { Text(app.activePersona?.opening ?? "选中一段文字，或提出你的问题。").font(.callout).foregroundStyle(tokens.secondary).padding(.vertical, 20) }
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text((record.characterName ?? app.personas.first { $0.id == record.personaID }?.name ?? record.personaID) + " · " + record.action.rawValue).font(.caption.bold()); Spacer(); Button { app.saveRecordAsNote(record) } label: { Image(systemName: "bookmark") }.help("存为笔记") }
                            if !record.question.isEmpty { Text(record.question).font(.callout.weight(.medium)).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(tokens.highlight, in: RoundedRectangle(cornerRadius: 8)) }
                            Text(.init(record.answer)).font(.callout).lineSpacing(5).textSelection(.enabled)
                            Text(record.modelName).font(.caption2).foregroundStyle(tokens.secondary)
                        }
                        Divider()
                    }
                    if app.companionPane == "阅读记录", let content = app.digest?.content {
                        if !content.insights.isEmpty {
                            Text("深度洞察").font(.headline)
                            ForEach(Array(content.insights.enumerated()), id: \.offset) { _, insight in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(insight.title).font(.callout.bold())
                                    Text(.init(insight.content)).font(.callout).lineSpacing(4).textSelection(.enabled)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(tokens.highlight.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        if !content.questions.isEmpty {
                            Text("问策 · 深谈").font(.headline)
                            ForEach(Array(content.questions.enumerated()), id: \.offset) { _, prompt in
                                Button { app.ask(prompt) } label: { HStack(alignment: .top) { Text(prompt).multilineTextAlignment(.leading); Spacer(); Image(systemName: "arrow.up.right") }.font(.callout).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.bordered).disabled(locked)
                            }
                        }
                    }
                    if app.isBusy || !app.streamingText.isEmpty { VStack(alignment: .leading, spacing: 8) { Text(app.taskLabel.isEmpty ? "正在思考…" : app.taskLabel).font(.caption); Text(.init(app.streamingText)).font(.callout).textSelection(.enabled) } }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(16)
            }.onChange(of: app.streamingText) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
             .onChange(of: app.activeRecords.count) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) { HStack { ForEach(["解释", "举例", "更深入", "检验理解", "认知卡"], id: \.self) { label in Button(label) { app.ask(label + "：请结合当前章节与我的阅读上下文。", action: label == "认知卡" ? .card : .chat) }.disabled(locked) } }.font(.caption) }
            if !app.selectedText.isEmpty { Text("引用 · " + app.selectedText.prefix(70)).font(.caption).lineLimit(2).foregroundStyle(tokens.secondary) }
            TextEditor(text: $app.question).font(.callout).scrollContentBackground(.hidden).frame(height: 68).padding(7).background(tokens.background, in: RoundedRectangle(cornerRadius: 8))
            HStack { Button("重试") { app.retryLast() }.disabled(locked); Spacer(); if app.isBusy { Button("停止生成") { app.cancelGeneration() } } else { Button("发送问题") { app.ask(app.question) }.buttonStyle(.borderedProminent).disabled(app.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.digestGenerating).keyboardShortcut(.return, modifiers: .command) } }
            Text("人物视角是演绎，请回到原文核对。").font(.system(size: 10)).foregroundStyle(tokens.secondary)
        }.padding(14)
    }
    private var memoryEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("我的阅读记忆").font(.headline)
            TextField("我目前的理解", text: $app.readingUnderstanding, axis: .vertical).lineLimit(2...4)
            TextField("仍未解决的问题", text: $app.readingOpenQuestion, axis: .vertical).lineLimit(2...3)
            Button("保存理解与问题") { app.saveReadingMemory() }
        }.textFieldStyle(.roundedBorder).padding(16)
    }
}

private struct CloseReadingSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var goal = ""
    @State private var before = ""
    @State private var after = ""
    @State private var unresolved = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("精读 · 把理解向前推进一步").font(.title2); Spacer(); Button("完成") { saveDraft() } }
            Text("围绕一个问题阅读，保留阅读前后的认识。").foregroundStyle(.secondary)
            field("本次精读目标", text: $goal)
            field("阅读前，我如何理解？", text: $before)
            field("阅读后，我的新理解", text: $after)
            field("尚未解决的问题", text: $unresolved)
            HStack {
                Button("生成引导 / 检验理解") { if app.startCloseReading(goal: goal, before: before, after: after, openQuestion: unresolved) { dismiss() } }.disabled(app.isBusy || goal.isEmpty)
                Spacer()
                Button("保存精读记录") { saveDraft() }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 620).background(KmaTheme.background)
        .onAppear { if let draft = app.closeReadingDraft { goal = draft.goal; before = draft.before; after = draft.after; unresolved = draft.openQuestion } }
    }
    private func saveDraft() { if app.saveCloseReading(before: before, after: after, openQuestion: unresolved, goal: goal) { dismiss() } }
    private func field(_ title: String, text: Binding<String>) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); TextField(title, text: text, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder) } }
}

private struct DiscussionSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var selected: [Persona] { app.personas.filter { app.discussionPersonaIDs.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("同场讨论").font(.title2); Spacer(); Button("取消") { dismiss() } }
            Text("邀请 2–3 位人物，分别回应同一个阅读问题。每位人物的回答会保存在本章记录中。").font(.callout).foregroundStyle(.secondary)
            TextField("讨论问题", text: $app.discussionQuestion, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            Text("已邀请：" + selected.map(\.name).joined(separator: "、")).font(.caption)
            TextField("搜索人物", text: $search).textFieldStyle(.roundedBorder)
            ScrollView { LazyVStack(alignment: .leading, spacing: 10) { ForEach(app.personas.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { persona in
                Toggle(isOn: Binding(get: { app.discussionPersonaIDs.contains(persona.id) }, set: { chosen in if chosen { if app.discussionPersonaIDs.count < 3 { app.discussionPersonaIDs.append(persona.id) } } else { app.discussionPersonaIDs.removeAll { $0 == persona.id } } })) { VStack(alignment: .leading, spacing: 3) { Text(persona.name); Text(persona.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }.toggleStyle(.checkbox).disabled(app.discussionPersonaIDs.count >= 3 && !app.discussionPersonaIDs.contains(persona.id))
            } } }.frame(height: 300)
            HStack { Spacer(); Button("开始同场讨论") { if app.startDiscussion() { dismiss() } }.buttonStyle(.borderedProminent).disabled(app.isBusy || app.discussionPersonaIDs.count < 2 || app.discussionQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(28).frame(width: 570).background(KmaTheme.background)
    }
}

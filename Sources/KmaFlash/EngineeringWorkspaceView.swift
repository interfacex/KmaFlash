import SwiftUI
import AppKit
import FlashCore

// BEGIN SOURCE VALUE TYPES
struct CodeTextSelection: Equatable {
    let text: String
    let lineStart, lineEnd: Int
    static func resolve(text: String, range: NSRange, lineStart: Int) -> CodeTextSelection? {
        let source = text as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= source.length, range.length <= source.length - range.location else { return nil }
        let selected = source.substring(with: range)
        let first = lineStart + source.substring(to: range.location).filter { $0 == "\n" }.count
        let count = selected.filter { $0 == "\n" }.count - (selected.hasSuffix("\n") ? 1 : 0)
        return CodeTextSelection(text: selected, lineStart: first, lineEnd: first + max(0, count))
    }
}
struct CodeFileStyle {
    let label: String
    let family: String
    init(path: String) {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        let languages = ["swift": "Swift", "py": "Python", "js": "JavaScript", "jsx": "JSX", "ts": "TypeScript", "tsx": "TSX", "java": "Java", "kt": "Kotlin", "go": "Go", "rs": "Rust", "c": "C", "h": "C / C++", "cpp": "C++", "sh": "Shell", "rb": "Ruby", "sql": "SQL", "ets": "ArkTS", "css": "CSS", "html": "HTML", "xml": "XML"]
        if ["md", "markdown", "rst"].contains(ext) { label = "Markdown"; family = "document" }
        else if ["json", "jsonc", "json5", "yaml", "yml", "toml", "ini", "conf", "properties"].contains(ext) {
            label = ["yml": "YAML", "jsonc": "JSONC", "json5": "JSON5" ][ext] ?? ext.uppercased(); family = "config"
        } else if name.hasPrefix(".") || ["dockerfile", "makefile"].contains(name) { label = "配置"; family = "config" }
        else if let language = languages[ext] { label = language; family = "code" }
        else { label = "纯文本"; family = "text" }
    }
}

struct EngineeringWorkspaceView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var model: EngineeringModel
    @State private var sidebar = true
    @State private var wrapLines = true
    @State private var selection: CodeTextSelection?
    @State private var theme = ReaderThemeID.stored()
    @State private var textSize = ReaderTextSize.stored()
    private var tokens: ReaderTokens { ReaderTokens.resolve(theme, sourceType: "code") }
    private let goals = [("A", "架构与核心概念"), ("B", "逐个模块学透"), ("C", "二次开发")]
    var body: some View {
        VStack(spacing: 0) {
            navigation
            Divider()
            if let error = model.error {
                HStack { Image(systemName: "exclamationmark.triangle"); Text(error).textSelection(.enabled); Spacer(); Button("重试") { model.retry() } }
                    .font(.caption).foregroundStyle(.red).padding(12)
                Divider()
            }
            HStack(spacing: 0) {
                if sidebar { fileSidebar.frame(width: 245); Divider() }
                Group {
                    if model.loading { ProgressView("读取文件…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if model.showJourney, let journey = model.journey { journeyView(journey) }
                    else if let source = model.source { sourceView(source) }
                    else { overview }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !model.answer.isEmpty || model.busy {
                    Divider()
                    answerPane.frame(width: 350)
                }
            }
        }.foregroundStyle(tokens.text).background(tokens.background)
            .navigationTitle(model.documentTitle)
            .task { model.load() }
            .onChange(of: model.source?.id) { _, _ in selection = nil }
            .onChange(of: theme) { _, value in UserDefaults.standard.set(value.rawValue, forKey: ReaderThemeID.storageKey) }
            .onChange(of: textSize) { _, value in UserDefaults.standard.set(value.rawValue, forKey: ReaderTextSize.storageKey) }
    }
    private var navigation: some View {
        HStack(spacing: 10) {
            Button("返回书房") { model.saveNote(); model.cancel(); app.closeReader() }
            Button { sidebar.toggle() } label: { Image(systemName: "sidebar.left") }.help("项目文件与模块")
            Button("工程概览") { model.backToOverview() }.disabled(model.busy)
            if let journey = model.journey {
                Button(journey.steps.allSatisfy(\.completed) ? "回顾路线" : "继续学习") { model.selectJourney(journey.id) }.disabled(model.busy)
            }
            Button("新建路线") { model.backToOverview(); model.prompt = "" }.disabled(model.busy)
            Spacer(minLength: 0)
            Picker("学习目标", selection: Binding(get: { model.goal }, set: model.setGoal)) {
                ForEach(goals, id: \.0) { Text($0.0 + " · " + $0.1).tag($0.0) }
            }.frame(maxWidth: 220).disabled(model.busy)
            if !model.history.isEmpty {
                Menu("历史路线") { ForEach(model.history) { journey in Button(journey.title) { model.selectJourney(journey.id) } } }.disabled(model.busy)
            }
            Menu("阅读设置") {
                Picker("模型", selection: Binding(get: { app.state.selectedModelID }, set: app.selectModel)) { ForEach(app.models) { Text($0.name).tag($0.id) } }.disabled(model.busy)
                Picker("纸色", selection: $theme) { ForEach(ReaderThemeID.allCases) { Text($0.label).tag($0) } }
                Picker("字号", selection: $textSize) { ForEach(ReaderTextSize.allCases) { Text($0.label).tag($0) } }
            }
        }.controlSize(.small).padding(12).background(tokens.surface)
    }
    private var directoryPrefix: String { model.prefix.isEmpty ? "" : model.prefix + "/" }
    private var childDirectories: [String] {
        guard model.query.isEmpty else { return [] }
        return Array(Set(model.filteredFiles.compactMap { entry -> String? in
            guard entry.path.hasPrefix(directoryPrefix) else { return nil }
            let remaining = String(entry.path.dropFirst(directoryPrefix.count))
            guard let separator = remaining.firstIndex(of: "/") else { return nil }
            return directoryPrefix + String(remaining[..<separator])
        })).sorted()
    }
    private var visibleFiles: [CodeArchiveEntry] {
        guard model.query.isEmpty else { return model.filteredFiles }
        return model.filteredFiles.filter { entry in
            entry.path.hasPrefix(directoryPrefix) && !entry.path.dropFirst(directoryPrefix.count).contains("/")
        }
    }
    private var fileSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("项目文件").font(.headline)
            TextField("搜索完整文件树", text: $model.query).textFieldStyle(.roundedBorder)
            HStack {
                Button("根目录") { model.prefix = ""; model.query = "" }
                if !model.prefix.isEmpty { Button("上一级") { model.prefix = model.prefix.split(separator: "/").dropLast().joined(separator: "/") } }
            }.controlSize(.small)
            Text(model.prefix.isEmpty ? (model.project?.root ?? "工程") : model.prefix)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(tokens.secondary).textSelection(.enabled)
            if model.loading { ProgressView().controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(childDirectories, id: \.self) { directory in
                        Button { model.prefix = directory; model.query = "" } label: {
                            Label((directory as NSString).lastPathComponent, systemImage: "folder")
                                .font(.system(size: textSize.scaled(12))).padding(6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    ForEach(visibleFiles) { entry in
                        Button { model.openSource(entry.path) } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "doc.text")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.query.isEmpty ? (entry.path as NSString).lastPathComponent : entry.path).lineLimit(3).multilineTextAlignment(.leading)
                                    Text(entry.reason ?? "按需读取").font(.system(size: 10)).foregroundStyle(tokens.secondary)
                                }
                                Spacer(minLength: 0)
                            }.font(.system(size: textSize.scaled(12))).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.source?.path == entry.path ? tokens.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).disabled(model.busy)
                    }
                }
            }
            Text("\(model.filteredFiles.count) 项 · 静态文件索引").font(.caption).foregroundStyle(tokens.secondary)
        }.padding(14).background(tokens.surface)
    }
    private var suggestion: String {
        switch model.goal {
        case "B": return "从核心模块入手，梳理职责、关键流程和模块边界"
        case "C": return "我想二次开发这个工程，请定位扩展入口并规划修改和验证步骤"
        default: return "这个工程解决什么问题？带我理解整体架构和核心概念"
        }
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("工程学习工作台").font(.system(size: textSize.scaled(28), weight: .bold))
                Text(model.documentTitle).font(.system(size: textSize.scaled(20), weight: .semibold))
                Text("先理解架构，再深入模块，最后规划改造。文件导航始终可用；模型只在你创建路线或提问时调用。")
                    .font(.system(size: textSize.scaled(15))).foregroundStyle(tokens.secondary)
                HStack(spacing: 16) {
                    Label("\(model.files.count) 个文件", systemImage: "doc.on.doc")
                    Label("\(model.modules.count) 个模块", systemImage: "square.grid.2x2")
                }.font(.caption).foregroundStyle(tokens.secondary)
                Button(suggestion) { model.prompt = suggestion }.buttonStyle(.bordered)
                composer
                Text("模块地图 · 按目录静态归纳").font(.headline)
                Text("模块边界由文件布局推断，运行时依赖仍需结合源码验证。").font(.caption).foregroundStyle(tokens.secondary)
                ForEach(model.modules, id: \.self) { module in
                    Button { model.prefix = module; model.query = ""; sidebar = true } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text((module as NSString).lastPathComponent).font(.system(size: textSize.scaled(17), weight: .semibold))
                            Text("\(model.files.filter { $0.path.hasPrefix(module + "/") }.count) 个文件 · 查看模块源码").font(.system(size: textSize.scaled(14)))
                            Text(module).font(.system(size: 11, design: .monospaced))
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(tokens.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
            }.padding(28).frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("你想带着什么问题读这个工程？").font(.headline)
            TextField("例如：请求从哪里进入，又如何流转到核心逻辑？", text: $model.prompt, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
            HStack {
                Text("基于本地源码规划学习路线").font(.caption).foregroundStyle(tokens.secondary)
                Spacer()
                Button("创建学习路线") { model.createJourney() }.buttonStyle(.borderedProminent).tint(tokens.accent)
                    .disabled(model.busy || model.loading || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(16).background(tokens.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func sourceView(_ source: CodeExcerpt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(source.path).font(.system(size: textSize.scaled(18), weight: .semibold, design: .monospaced)).textSelection(.enabled)
            HStack {
                Text(CodeFileStyle(path: source.path).label).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(tokens.accent.opacity(0.1), in: Capsule())
                Text("L\(source.lineStart)–\(source.lineEnd) / \(model.sourceTotalLines) 行").font(.caption).foregroundStyle(tokens.secondary)
                Spacer()
                Toggle("自动换行", isOn: $wrapLines).toggleStyle(.checkbox).font(.caption)
                Button("上一段") { model.openSource(source.path, start: max(1, source.lineStart - 120)) }.disabled(source.lineStart <= 1 || model.loading || model.busy)
                Button("下一段") { model.openSource(source.path, start: source.lineEnd + 1) }.disabled(source.lineEnd >= model.sourceTotalLines || model.loading || model.busy)
            }.controlSize(.small)
            if let selection {
                VStack(alignment: .leading, spacing: 8) {
                    Text("已选 L\(selection.lineStart)–\(selection.lineEnd) · " + selection.text.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).font(.caption).foregroundStyle(tokens.secondary)
                    HStack(spacing: 16) {
                        ForEach(CodeSourceCommand.allCases, id: \.self) { command in
                            Button(command.rawValue) { runCommand(command, source: source, selection: selection) }.disabled(command.needsModel && model.busy)
                        }
                    }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(tokens.accent)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(tokens.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            EngineeringSourceText(text: source.text, path: source.path, lineStart: source.lineStart, wrapLines: wrapLines, fontSize: textSize.scaled(12), foreground: NSColor(tokens.text), background: NSColor(tokens.background), onSelection: { selected in
                guard model.source?.id == source.id else { return }
                selection = selected
                if let selected { model.quote(selected.text, start: selected.lineStart, end: selected.lineEnd) }
                else { model.selectedExcerpt = nil }
            }, onCommand: { command, selected in runCommand(command, source: source, selection: selected) })
                .frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            Text("拖选代码或配置内容，可记笔记、复制、解释和讨论；右键也可操作。").font(.caption).foregroundStyle(tokens.secondary)
            askBar
        }.padding(22)
    }
    private var askBar: some View {
        HStack {
            TextField("针对当前文件或选区提问…", text: $model.prompt).textFieldStyle(.roundedBorder).onSubmit { if !model.busy && !model.loading { model.ask(model.prompt) } }
            Button("问模型助手") { model.ask(model.prompt) }.disabled(model.busy || model.loading || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private func journeyView(_ journey: EngineeringJourney) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(journey.title).font(.system(size: textSize.scaled(25), weight: .bold))
                Text("学习路线 · \(journey.steps.filter(\.completed).count) / \(journey.steps.count) 已读").foregroundStyle(tokens.secondary)
                ProgressView(value: Double(journey.steps.filter(\.completed).count), total: Double(max(1, journey.steps.count))).tint(tokens.accent)
                ForEach(Array(journey.steps.enumerated()), id: \.element.id) { index, step in
                    Button { model.selectStep(index) } label: {
                        HStack {
                            Image(systemName: step.completed ? "checkmark.circle.fill" : "circle")
                            Text("\(index + 1). " + step.title).font(.system(size: textSize.scaled(15), weight: index == journey.stepIndex ? .semibold : .regular))
                            Spacer()
                            if index == journey.stepIndex { Text("正在学习").font(.caption) }
                        }.padding(12).background(index == journey.stepIndex ? tokens.accent.opacity(0.1) : tokens.surface, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(model.busy)
                }
                if journey.steps.indices.contains(journey.stepIndex) {
                    let step = journey.steps[journey.stepIndex]
                    Divider()
                    Text(step.title).font(.title2.bold())
                    Text(step.question).font(.system(size: textSize.body)).textSelection(.enabled)
                    stepDetails(step)
                    Text("源码入口").font(.headline)
                    ForEach(step.excerpts ?? []) { excerpt in
                        VStack(alignment: .leading, spacing: 8) {
                            sourceCitation(excerpt)
                            Text(excerpt.text).font(.system(size: textSize.scaled(12), design: .monospaced)).lineLimit(12).textSelection(.enabled)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(tokens.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(step.paths.filter { path in !(step.excerpts ?? []).contains { $0.path == path } }, id: \.self) { path in
                        Button { model.openSource(path) } label: { Label(path, systemImage: "chevron.left.forwardslash.chevron.right").font(.system(size: 12, design: .monospaced)) }.disabled(model.busy)
                    }
                    Button("讲解这一站") { model.ask(step.question) }.disabled(model.busy)
                    stepCheck(step)
                    Text("我的理解与未解决问题").font(.headline)
                    TextEditor(text: $model.understanding).font(.system(size: textSize.scaled(14))).frame(minHeight: 100).padding(6).background(tokens.surface, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("保存学习笔记") { model.saveNote() }
                        Spacer()
                        Button(step.completed ? "已标记读过" : "标记读过，继续下一站") { model.completeStep() }.disabled(model.busy || step.completed)
                    }
                    askBar
                }
                if !journey.turns.isEmpty {
                    Divider()
                    Text("本路线讨论记录").font(.headline)
                    ForEach(journey.turns) { turn in
                        DisclosureGroup(turn.question) {
                            Text(turn.answer).font(.system(size: textSize.scaled(14))).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                            ForEach(turn.excerpts) { excerpt in Button("\(excerpt.path) · L\(excerpt.lineStart)–\(excerpt.lineEnd)") { model.openSource(excerpt.path, start: excerpt.lineStart) } }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    @ViewBuilder private func detail(_ label: String, _ value: String?) -> some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.system(size: textSize.scaled(13), weight: .semibold)).foregroundStyle(tokens.secondary)
                Text(value).font(.system(size: textSize.scaled(15))).lineSpacing(4).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func stepDetails(_ step: EngineeringStep) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            detail("承接上一步", step.recap)
            detail("为什么读这里", step.why)
            detail("这一步看什么", step.layers?[model.goal] ?? step.focus)
            if model.goal == "C" { detail("二次开发 · 修改与验证", step.development) }
            detail("下一步方向", step.next)
        }
    }
    @ViewBuilder private func stepCheck(_ step: EngineeringStep) -> some View {
        if let question = step.checkPrompt, !question.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("停一下，检查理解", systemImage: "questionmark.circle").font(.headline)
                Text(question).font(.system(size: textSize.scaled(14), weight: .medium)).textSelection(.enabled)
                if let hint = step.checkHint, !hint.isEmpty {
                    DisclosureGroup("看看提示") { Text(hint).font(.system(size: textSize.scaled(14))).textSelection(.enabled).padding(.vertical, 6) }
                }
                Button("结合源码讲解自检问题") { model.ask("请讲解这个自检问题，并结合源码给出可验证的推理：" + question) }.disabled(model.busy)
            }.padding(16).background(tokens.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private func sourceCitation(_ excerpt: CodeExcerpt) -> some View {
        Button { model.openSource(excerpt.path, start: excerpt.lineStart) } label: {
            Label("\(excerpt.path) · L\(excerpt.lineStart)–\(excerpt.lineEnd)", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: textSize.scaled(12), design: .monospaced)).multilineTextAlignment(.leading)
        }.buttonStyle(.plain).foregroundStyle(tokens.accent).disabled(model.busy)
    }
    private var answerPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("工程对话").font(.headline); Spacer(); if model.busy { ProgressView().controlSize(.small); Button("停止") { model.cancel() } } }
            if let excerpt = model.selectedExcerpt {
                Text("引用 · \(excerpt.path):L\(excerpt.lineStart)–\(excerpt.lineEnd)").font(.caption).foregroundStyle(tokens.secondary).lineLimit(3)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(model.answer.isEmpty ? "正在结合源码生成…" : model.answer).font(.system(size: textSize.scaled(15))).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if !model.answerExcerpts.isEmpty {
                        Divider()
                        Text("源码依据").font(.headline)
                        ForEach(model.answerExcerpts) { excerpt in sourceCitation(excerpt) }
                    }
                }
            }
            if !model.busy && !model.answer.isEmpty { Button("复制回答") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.answer, forType: .string) } }
        }.padding(18).background(tokens.surface)
    }
    private func runCommand(_ command: CodeSourceCommand, source: CodeExcerpt, selection: CodeTextSelection) {
        guard model.source?.id == source.id else { return }
        let location = "\(source.path):L\(selection.lineStart)–L\(selection.lineEnd)"
        switch command {
        case .copy, .reference:
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command == .copy ? selection.text : location, forType: .string)
        case .note:
            model.quote(selection.text, start: selection.lineStart, end: selection.lineEnd); model.saveSourceNote()
        case .explain, .discuss:
            model.quote(selection.text, start: selection.lineStart, end: selection.lineEnd)
            model.ask(command == .explain ? "解释所选内容的职责、关键逻辑、依赖与边界条件，区分源码事实和推测。" : "围绕所选内容讨论设计意图、取舍与潜在问题。先提出一个值得思考的问题，不要假设未读取的实现。")
        }
    }
}

private struct EngineeringSourceText: NSViewRepresentable {
    let text: String
    let path: String
    let lineStart: Int
    let wrapLines: Bool
    let fontSize: CGFloat
    let foreground, background: NSColor
    let onSelection: (CodeTextSelection?) -> Void
    let onCommand: (CodeSourceCommand, CodeTextSelection) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = EngineeringTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = true
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.autoresizingMask = [.width]; view.isVerticallyResizable = true
        view.delegate = context.coordinator
        scroll.documentView = view; scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.verticalRulerView = EngineeringLineRuler(textView: view)
        scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onSelection = onSelection
        guard let view = scroll.documentView as? EngineeringTextView else { return }
        view.onCommand = onCommand; view.lineStart = lineStart
        context.coordinator.lineStart = lineStart
        scroll.hasHorizontalScroller = !wrapLines
        view.isHorizontallyResizable = !wrapLines
        view.textContainer?.widthTracksTextView = wrapLines
        view.textContainer?.containerSize = NSSize(width: wrapLines ? max(1, scroll.contentSize.width) : 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        if wrapLines { view.setFrameSize(NSSize(width: scroll.contentSize.width, height: view.frame.height)) }
        view.backgroundColor = background
        scroll.backgroundColor = background
        scroll.contentView.backgroundColor = background
        let styleKey = "\(path)|\(foreground.description)|\(wrapLines)|\(fontSize)"
        let sourceFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.font = sourceFont
        if view.string != text || view.styleKey != styleKey {
            let changed = view.string != text
            let oldSelection = view.selectedRange()
            view.styleKey = styleKey
            view.string = text
            let storage = view.textStorage
            let whole = NSRange(location: 0, length: (text as NSString).length)
            storage?.setAttributes([.font: sourceFont, .foregroundColor: foreground], range: whole)
            var patterns: [(String, NSColor)] = [
                (#"\b(func|function|class|struct|enum|import|from|def|return|if|else|for|while|let|var|const|public|private|async|await|throw|try|new|true|false|null|nil)\b"#, .systemPurple),
                (#""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#, .systemRed),
                (#"(?m)//[^\n]*|^\s*#[^\n]*"#, .systemGreen)
            ]
            let style = CodeFileStyle(path: path)
            if style.family == "config" {
                patterns += [(#"(?m)^\s*[\w.\-]+(?=\s*[=:])"#, .systemBlue), (#"(?m)^\s*\[[^\n]+\]"#, .systemPurple)]
            } else if style.family == "document" {
                patterns = [(#"(?m)^#{1,6} .*$"#, .systemBlue), (#"`[^`\n]+`"#, .systemPurple)]
            } else if style.family == "text" { patterns = [] }
            for (pattern, color) in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    for match in regex.matches(in: text, range: whole) { storage?.addAttribute(.foregroundColor, value: color, range: match.range) }
                }
            }
            if changed { view.scrollToBeginningOfDocument(nil) }
            else { view.setSelectedRange(oldSelection) }
        }
        if let ruler = scroll.verticalRulerView as? EngineeringLineRuler {
            ruler.lineStart = lineStart
            ruler.sourceBackground = background
            ruler.sourceForeground = foreground
            ruler.sourceFontSize = max(9, fontSize - 2)
            ruler.needsDisplay = true
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelection: ((CodeTextSelection?) -> Void)?
        var lineStart = 1
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            guard NSMaxRange(range) <= (view.string as NSString).length else { return }
            let selected = CodeTextSelection.resolve(text: view.string, range: range, lineStart: lineStart)
            let callback = onSelection
            DispatchQueue.main.async { callback?(selected) }
        }
    }
}

private final class EngineeringLineRuler: NSRulerView {
    weak var sourceView: NSTextView?
    var lineStart = 1
    var sourceBackground = NSColor.textBackgroundColor
    var sourceForeground = NSColor.labelColor
    var sourceFontSize: CGFloat = 10
    init(textView: NSTextView) {
        sourceView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 48
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        sourceBackground.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = sourceView, let layout = view.layoutManager, let container = view.textContainer else { return }
        sourceBackground.setFill(); bounds.fill()
        layout.ensureLayout(for: container)
        let content = view.string as NSString
        var index = 0
        var line = lineStart
        while index < content.length {
            let glyph = layout.glyphIndexForCharacter(at: index)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = convert(NSPoint(x: 0, y: fragment.minY + view.textContainerOrigin.y), from: view)
            if position.y >= -20 && position.y <= bounds.height + 20 {
                let label = String(line) as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: sourceFontSize, weight: .regular), .foregroundColor: sourceForeground.withAlphaComponent(0.45)]
                label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attrs).width - 8, y: position.y + 2), withAttributes: attrs)
            }
            index = NSMaxRange(content.lineRange(for: NSRange(location: index, length: 0)))
            line += 1
        }
    }
}

private enum CodeSourceCommand: String, CaseIterable {
    case note = "记笔记", copy = "复制", explain = "解释选段", discuss = "一起讨论", reference = "复制位置"
    var needsModel: Bool { self == .explain || self == .discuss }
}
private final class EngineeringTextView: NSTextView {
    var lineStart = 1
    var styleKey = ""
    var onCommand: ((CodeSourceCommand, CodeTextSelection) -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard selectedRange().length > 0 else { return super.menu(for: event) }
        let menu = NSMenu(title: "代码选区")
        for (index, command) in CodeSourceCommand.allCases.enumerated() {
            let item = NSMenuItem(title: command.rawValue, action: #selector(runCommand(_:)), keyEquivalent: "")
            item.tag = index; item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func runCommand(_ item: NSMenuItem) {
        guard let selection = CodeTextSelection.resolve(text: string, range: selectedRange(), lineStart: lineStart) else { return }
        onCommand?(CodeSourceCommand.allCases[item.tag], selection)
    }
}

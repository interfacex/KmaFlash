import SwiftUI
import UniformTypeIdentifiers
import FlashCore

struct MaterialImportView: View {
    @StateObject private var model: MaterialImportModel
    @Environment(\.dismiss) private var dismiss
    @State private var targeted = false
    init(app: AppModel) { _model = StateObject(wrappedValue: MaterialImportModel(app: app)) }
    private let kinds = [("book", "普通书籍"), ("paper", "学术论文"), ("tech", "科技读物"), ("wechat", "微信公众号"), ("code", "软件工程")]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("同页").font(.headline)
                    Text("书房 / 添加阅读材料").foregroundStyle(.secondary)
                    Spacer()
                    Button("导入任务 · \(model.drafts.count)") { model.showTasks.toggle() }
                    Button("返回书房") { dismiss() }.disabled(model.busy)
                }
                Text("把想读的，带到同页").font(.system(size: 32, weight: .bold, design: .serif))
                Text("一本书、一篇论文，或一个想读懂的开源项目。").foregroundStyle(.secondary)
                intake
                if model.showTasks {
                    ForEach(model.drafts.filter { $0.status == "completed" }) { draft in
                        HStack { Image(systemName: "checkmark.circle.fill").foregroundStyle(KmaTheme.primary); Text(draft.title); Spacer(); Text(draft.detail).font(.caption); if draft.kind == "code" { Button("进入工程工作台") { model.open(draft) } } else { Button("先读原文") { model.open(draft) }; Button("开始共读") { model.open(draft, mode: "伴读") } }; Button("移除任务") { model.remove(draft.id) } }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                ForEach(model.drafts.filter { $0.status != "completed" }) { draft in confirmation(draft) }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }.padding(28).frame(maxWidth: 920).frame(maxWidth: .infinity)
        }
        .frame(minWidth: 880, idealWidth: 940, minHeight: 650, idealHeight: 760)
        .background(KmaTheme.background)
        .interactiveDismissDisabled(model.busy)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.receive([url]) } }
                }
            }
            return !providers.isEmpty
        }
    }
    private var intake: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ForEach([("link", "粘贴链接"), ("file", "上传文件"), ("text", "粘贴文字")], id: \.0) { entry in
                    Button(entry.1) { model.intake = entry.0 }.buttonStyle(.bordered).tint(model.intake == entry.0 ? KmaTheme.primary : .gray)
                }
            }
            switch model.intake {
            case "link":
                TextField("粘贴文章、论文或开源项目链接", text: $model.link, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                Text("支持微信公众号、arXiv 论文及 GitHub、GitLab.com、Gitee 公开仓库。其他来源可上传文件或粘贴正文。").font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("识别链接") { model.recognizeLink() }.buttonStyle(.borderedProminent).disabled(model.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            case "text":
                TextField("标题（可选）", text: $model.title).textFieldStyle(.roundedBorder)
                TextEditor(text: $model.bodyText).frame(height: 120).overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.25)))
                HStack { Text("保留原文，可在确认页调整材料类型。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("识别文字") { model.recognizeText() }.buttonStyle(.borderedProminent).disabled(model.bodyText.isEmpty) }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    Text(targeted ? "松开即可识别" : "拖入书籍、论文、文档或代码 ZIP").font(.headline)
                    Text("PDF、TXT、Markdown、代码 ZIP，支持多文件。文件在本机静态解析，不安装依赖或执行工程脚本。").font(.caption).foregroundStyle(.secondary)
                    Text("工程保留文件目录，源码按需读取。依赖、构建产物与敏感文件会跳过；确认页可查看明细。").font(.caption).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 16).stroke(targeted ? KmaTheme.primary : .gray.opacity(0.3)))
                Button("选择文件") { model.chooseFiles() }.controlSize(.large)
            }
        }.padding(18).background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
    }
    private func binding(_ id: String, _ path: WritableKeyPath<MaterialDraft, String>) -> Binding<String> {
        Binding(get: { model.drafts.first { $0.id == id }?[keyPath: path] ?? "" }, set: { value in model.update(id) { $0[keyPath: path] = value } })
    }
    @ViewBuilder private func confirmation(_ draft: MaterialDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if ["recognizing", "importing"].contains(draft.status) {
                HStack { ProgressView().controlSize(.small); Text(draft.title).font(.headline); Spacer(); Button("取消") { model.cancel(draft.id) } }
                ProgressView(value: draft.progress)
                Text(draft.detail).foregroundStyle(.secondary)
            } else if draft.status != "waiting_user" {
                HStack { VStack(alignment: .leading) { Text(draft.title).font(.headline); Text(draft.detail).foregroundStyle(.secondary) }; Spacer(); Button("重试") { model.retry(draft.id) }; Button("移除") { model.remove(draft.id) } }
            } else {
                HStack(alignment: .top, spacing: 22) {
                    preview(draft)
                    options(draft)
                }
            }
        }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.gray.opacity(0.15)))
    }
    private func preview(_ draft: MaterialDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
                        Text(draft.archive == nil ? "原文预览" : draft.kind == "code" ? "工程文件预览" : "资料文件预览").font(.caption).foregroundStyle(.secondary)
                        Text(draft.title).font(.system(size: 25, weight: .semibold, design: .serif))
                        if let archive = draft.archive {
                            Text("\(archive.entries.count) 个条目 · \(archive.entries.filter { $0.reason == nil }.count) 个可读文件").foregroundStyle(KmaTheme.primary)
                            Text(archive.languages.joined(separator: " · ")).font(.caption)
                            Text(archive.entries.filter { $0.reason == nil }.prefix(12).map(\.path).joined(separator: "\n")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            DisclosureGroup("跳过的文件 · \(archive.entries.filter { $0.reason != nil }.count)") {
                                ScrollView { LazyVStack(alignment: .leading) { ForEach(archive.entries.filter { $0.reason != nil }) { entry in Text(entry.path + " · " + (entry.reason ?? "")).font(.caption).textSelection(.enabled) } } }.frame(maxHeight: 150)
                            }
                        } else {
                            Text(String(draft.document?.chapters.first?.text.prefix(550) ?? "")).lineSpacing(4).textSelection(.enabled)
                            Text("\(draft.document?.chapters.count ?? 0) 个章节").font(.caption).foregroundStyle(.secondary)
                            if let document = draft.document {
                                DisclosureGroup("查看目录") { ForEach(document.chapters) { Text($0.title).font(.caption) } }
                            }
                        }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func options(_ draft: MaterialDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
                        Text(draft.source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        TextField("标题", text: binding(draft.id, \.title)).textFieldStyle(.roundedBorder)
                        if !draft.fingerprint.isEmpty { Text("内容指纹 · " + String(draft.fingerprint.prefix(12))).font(.caption2).foregroundStyle(.secondary) }
                        if let document = draft.document {
                            Picker("从哪里开始", selection: Binding(get: { model.drafts.first { $0.id == draft.id }?.startingChapterID ?? document.chapters.first?.id ?? "" }, set: { value in model.update(draft.id) { $0.startingChapterID = value } })) {
                                ForEach(document.chapters) { Text($0.title).tag($0.id) }
                            }
                        }
                        Picker("材料类型", selection: binding(draft.id, \.kind)) { ForEach(kinds, id: \.0) { Text($0.1).tag($0.0) } }
                        if let archive = draft.archive {
                            Picker("目录范围", selection: binding(draft.id, \.root)) {
                                Text("整个压缩包").tag("")
                                ForEach(Array(Set(archive.roots.filter { !$0.isEmpty && $0 != "." } + (draft.root.isEmpty ? [] : [draft.root]))).sorted(), id: \.self) { Text($0).tag($0) }
                            }
                            if draft.kind == "code" {
                                if archive.roots.filter({ !$0.isEmpty && $0 != "." }).count > 1 {
                                    Toggle("将各工程分别加入书房", isOn: Binding(get: { model.drafts.first { $0.id == draft.id }?.splitProjects == true }, set: { value in model.update(draft.id) { $0.splitProjects = value } }))
                                    if draft.splitProjects == true { Text("按识别到的全部工程拆分，忽略单个目录范围。").font(.caption).foregroundStyle(.secondary) }
                                }
                                Picker("想从哪里开始", selection: binding(draft.id, \.goal)) {
                                    Text("先了解项目").tag("overview"); Text("跟一条核心流程").tag("flow"); Text("深入一个模块").tag("module")
                                }
                            } else { Text("按独立文档导入压缩包中的 PDF、Markdown 和文本。").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(draft.kind == "code" ? "源码向导 · 贴着真实文件和行号理解工程" : draft.kind == "paper" ? "实证先生 · 先核对论文主张与依据" : draft.kind == "wechat" ? "取舍编辑 · 抓住文章真正要说的一句" : "细读先生 · 贴着原文慢慢读").font(.caption).foregroundStyle(.secondary)
                        if model.duplicate(draft) != nil {
                            Text("这份材料已经在书房中。").foregroundStyle(.secondary)
                            Button("打开已有材料") { model.openDuplicate(draft) }.buttonStyle(.borderedProminent)
                        } else {
                            Button("确认导入") { model.confirm(draft.id) }.buttonStyle(.borderedProminent).disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Button("移除草稿") { model.remove(draft.id) }.foregroundStyle(.secondary)
        }.frame(width: 280)
    }
}

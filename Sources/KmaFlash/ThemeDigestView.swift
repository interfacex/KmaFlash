import SwiftUI
import FlashCore

/// Port of KMA ThemeDigestView: original excerpts and continuous persona interpretation.
struct ThemeDigestView: View {
    let content: DigestContent
    let tokens: ReaderTokens
    let chapterTitle: String
    let speaker: String
    let bodySize: CGFloat
    let generating: Bool
    let onSource: (DigestBlock) -> Void
    let onSelection: (String, DigestBlock) -> Void
    let onCommand: (ReadingTextCommand, DigestBlock) -> Void
    let onQuestion: (String) -> Void
    let onRegenerate: () -> Void
    private var originals: [DigestBlock] { content.sections.flatMap(\.blocks).filter(\.isOriginal) }
    private var goldenQuotes: [DigestBlock] {
        var seen = Set<String>()
        return Array(originals.filter { $0.featured == true && seen.insert($0.text).inserted }.prefix(3))
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(chapterTitle).font(.caption).foregroundStyle(tokens.secondary)
                        Text(content.headline).font(.system(size: bodySize + 8, weight: .bold)).textSelection(.enabled)
                        HStack {
                            Text("\(speaker) · 解读 · AI 生成")
                            Spacer()
                            Menu("本章目录") {
                                ForEach(Array(content.sections.enumerated()), id: \.offset) { index, section in
                                    Button(section.heading) { withAnimation { proxy.scrollTo("theme-\(index)", anchor: .top) } }
                                }
                                if !content.insights.isEmpty { Button("本章总结") { withAnimation { proxy.scrollTo("chapter-summary", anchor: .top) } } }
                                if !goldenQuotes.isEmpty { Button("原文金句") { withAnimation { proxy.scrollTo("chapter-quotes", anchor: .top) } } }
                            }.menuStyle(.borderlessButton).fixedSize()
                        }.font(.caption).foregroundStyle(tokens.secondary)
                        Text(originals.isEmpty ? "本版尚无可核验的原文摘录，以下为转述与角色解读。" : "引线内为原文摘录，下方为角色解读。右键可收藏、讨论或查看原文。")
                            .font(.caption).foregroundStyle(tokens.secondary)
                    }
                    if originals.isEmpty && !generating {
                        HStack(alignment: .firstTextBaseline) {
                            Text("这版导读仅含要点转述或未核验内容，重新生成可补充原文摘录。")
                            Spacer(minLength: 8)
                            Button("重新生成", action: onRegenerate).buttonStyle(.link)
                        }.font(.caption).foregroundStyle(tokens.secondary)
                    }
                    ForEach(Array(content.sections.enumerated()), id: \.offset) { index, section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(section.heading).font(.system(size: bodySize + 3, weight: .bold))
                            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in passage(block) }
                        }.id("theme-\(index)")
                        Divider().overlay(tokens.secondary.opacity(0.12))
                    }
                    if !content.insights.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("本章总结").font(.system(size: bodySize + 3, weight: .bold))
                            Text("\(speaker) · 总结与判断").font(.caption).foregroundStyle(tokens.secondary)
                            ForEach(Array(content.insights.enumerated()), id: \.offset) { _, insight in
                                VStack(alignment: .leading, spacing: 5) {
                                    if insight.title != "本章总结" && !insight.title.isEmpty { Text(insight.title).font(.system(size: bodySize, weight: .semibold)) }
                                    passage(.init(type: "voice", text: insight.content))
                                }
                            }
                        }.id("chapter-summary")
                    }
                    if !goldenQuotes.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            Text("原文金句").font(.system(size: bodySize + 3, weight: .bold))
                            ForEach(Array(goldenQuotes.enumerated()), id: \.offset) { _, block in passage(block) }
                        }.id("chapter-quotes")
                    }
                    if !content.questions.isEmpty {
                        DisclosureGroup("继续聊聊") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(content.questions, id: \.self) { question in
                                    Button { onQuestion(question) } label: {
                                        HStack(alignment: .top) { Text(question).multilineTextAlignment(.leading); Image(systemName: "arrow.up.right") }
                                    }.buttonStyle(.plain).foregroundStyle(tokens.accent).disabled(generating)
                                }
                            }.padding(.top, 8)
                        }.font(.system(size: bodySize - 1)).foregroundStyle(tokens.secondary)
                    }
                }.padding(.vertical, 24).padding(.horizontal, 36)
                    .frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity)
                    .foregroundStyle(tokens.text)
            }
        }
    }
    private func interpretation(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    private func passage(_ block: DigestBlock) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if block.recoveredFromCitation == true { Text("依据原导读引用，从本章补充的原文").font(.caption).foregroundStyle(tokens.secondary) }
            if block.type == "quote" || block.type == "unverified" || (block.type == "excerpt" && !block.isOriginal) {
                Text(block.contentLabel).font(.caption).foregroundStyle(tokens.secondary)
            }
            InlineReadingPassage(text: block.isOriginal ? ReadingPresentation.flowingExcerpt(block.text) : block.text, size: bodySize, color: block.isOriginal ? tokens.secondary : tokens.text,
                italic: false, markdown: block.type == "voice",
                onSelection: { onSelection($0, block) }, onCommand: { onCommand($0, block) })
                .frame(maxWidth: .infinity, alignment: .leading)

        }.padding(.leading, block.isOriginal ? 13 : 0).padding(.trailing, block.isOriginal ? 24 : 0)
            .padding(.vertical, block.isOriginal ? 3 : 0)
            .overlay(alignment: .leading) { if block.isOriginal { Rectangle().fill(tokens.secondary.opacity(0.25)).frame(width: 2) } }
            .overlay(alignment: .topTrailing) {
                if block.isOriginal { Button { onSource(block) } label: { Image(systemName: "arrow.up.right").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(tokens.secondary).help("查看原文 · \(chapterTitle)").accessibilityLabel("查看原文") }
            }
    }
}

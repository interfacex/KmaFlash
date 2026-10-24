import SwiftUI
import FlashCore

struct BookCharacterStrip: View {
    @EnvironmentObject var app: AppModel
    let items: [BookCharacter]
    let tokens: ReaderTokens
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本章人物 · 点一下，右侧开始对话")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(tokens.accent)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { character in
                        let engaged = app.characterName == character.name
                        Button { app.engageCharacter(character.name) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(character.name).font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(engaged ? tokens.accent : tokens.text)
                                    if engaged {
                                        Text("对话中").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(tokens.accent))
                                    }
                                }
                                if let blurb = character.blurb, !blurb.isEmpty {
                                    Text(blurb).font(.system(size: 11)).foregroundStyle(tokens.secondary)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                }
                            }.padding(.horizontal, 12).padding(.vertical, 10).frame(width: 260, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 12).fill(engaged ? tokens.accent.opacity(0.14) : tokens.surface))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(engaged ? tokens.accent : tokens.secondary.opacity(0.25), lineWidth: engaged ? 2 : 1))
                        }.buttonStyle(.plain).disabled(app.isBusy || app.digestGenerating)
                    }
                }.padding(2)
            }
        }.padding(.top, 8)
    }
}

struct CharacterChatPanel: View {
    @EnvironmentObject var app: AppModel
    let tokens: ReaderTokens
    @FocusState private var fieldFocused: Bool
    private var name: String { app.characterName }
    private func send(_ prompt: String) { app.askCharacter(name, question: prompt) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            openingPrompts
            ForEach(app.characterRecords.suffix(20)) { record in
                recordView(record)
            }
            responseStatus
            composer
            if let error = app.characterError { Text(error).font(.system(size: 11)).foregroundStyle(.red); Button("重试") { send(app.characterQuestion) } }
        }.padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(tokens.accent.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(tokens.accent, lineWidth: 1.5))
            .onAppear { fieldFocused = true }
            .onChange(of: app.characterChatNonce) { _, _ in fieldFocused = true }
    }
    private var header: some View {
        HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在与\(name)对话").font(.system(size: 15, weight: .semibold)).foregroundStyle(tokens.accent)
                    if let blurb = app.bookCharacters.first(where: { $0.name == name })?.blurb, !blurb.isEmpty {
                        Text(blurb).font(.system(size: 12)).foregroundStyle(tokens.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button("结束") { app.disengageCharacter() }.buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(tokens.secondary)
        }
    }
    @ViewBuilder private var openingPrompts: some View {
        if app.characterRecords.isEmpty && !app.isBusy {
                Text("选一个开头，或在下面直接问\(name)。").font(.system(size: 12)).foregroundStyle(tokens.secondary)
                characterPrompt("请用你的身份，讲讲你在这一章里的处境。")
                characterPrompt("这一章里，你最想让我看懂的是什么？")
        }
    }
    private func recordView(_ record: ReadingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
                    Text("我问：" + record.question).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                    Text(LocalizedStringKey(record.answer)).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    HStack(spacing: 12) {
                        Button("一键存笔记") { app.saveRecordAsNote(record) }.foregroundStyle(tokens.accent)
                        Button("摘抄笔记") { app.saveExcerpt(record.answer, source: "character") }.foregroundStyle(tokens.secondary)
                    }.buttonStyle(.borderless)
                    Text("出处 · 人物对话 · \(name)").font(.system(size: 11)).foregroundStyle(tokens.secondary)
                    HStack { ForEach(DigestParser.citations(in: record.answer, blockCount: app.activeChapter?.blocks.count ?? 0), id: \.self) { id in
                        Button("[\(id)]") { app.revealCitation(id) }.buttonStyle(.link)
                    } }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 12).fill(tokens.background))
    }
    @ViewBuilder private var responseStatus: some View {
        if app.isBusy {
                HStack { ProgressView().controlSize(.small); Text("\(name)正在回应…").font(.system(size: 12)); Spacer(); Button("停止") { app.cancelGeneration() } }
            }
        if !app.streamingText.isEmpty { Text(LocalizedStringKey(app.streamingText)).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled) }
    }
    private var composer: some View {
        HStack(spacing: 8) {
                TextField("向\(name)提问…", text: $app.characterQuestion).textFieldStyle(.plain).focused($fieldFocused)
                    .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(tokens.background))
                    .onSubmit { send(app.characterQuestion) }
                Button { send(app.characterQuestion) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundStyle(tokens.accent)
                }.buttonStyle(.plain).help("发送人物问题")
                    .disabled(app.isBusy || app.digestGenerating || app.characterQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private func characterPrompt(_ prompt: String) -> some View {
        Button { send(prompt) } label: {
            Text(prompt).font(.system(size: 12)).foregroundStyle(tokens.text).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(tokens.background))
        }.buttonStyle(.plain).disabled(app.isBusy || app.digestGenerating)
    }
}

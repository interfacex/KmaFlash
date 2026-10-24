import Foundation
import FlashCore
@main struct FlashCheck {
    static func main() async {
        do {
            let models = try Builtins.models()
            let requested = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
            let model = models.first { $0.id == requested } ?? models[0]
            if CommandLine.arguments.contains("--digest") {
                let chapter = Chapter(title: "主动阅读", text: "真正的理解，是用自己的话说清一个观点，指出它依赖的条件，并知道它何时不适用。\n\n阅读笔记要区分原文、自己的理解和未解决的问题，前者准确，后两者可以改变。\n\n不同人物的阅读视角可以揭示盲点，但回答仍须回到原文检验，不能用表达代替证据。")
                let document = ReadingDocument(title: "阅读示例", source: "测试", chapters: [chapter])
                let persona = try Builtins.personas().first { $0.id == "通用陪读人" }!
                let probe = DigestProbe()
                let result = try await ModelClient.complete(config: model, messages: PromptBuilder.digestMessages(document: document, chapter: chapter, persona: persona, requirements: "")) { delta in await probe.receive(delta) }
                var decoder = DigestStreamDecoder(); try decoder.append(result)
                let guide = DigestGrounding.verify(try decoder.finish(), chapter: chapter)
                print("PASS digest: \(guide.sections.count) sections, \(guide.insights.count) insights, \(guide.questions.count) questions")
                let excerpts = guide.sections.flatMap(\.blocks).filter(\.isOriginal).count
                print("Verified excerpts: \(excerpts); stream \(await probe.report())")
                guard guide.sections.count >= 2, guide.insights.count >= 1, guide.questions.count >= 1, excerpts > 0 else { throw FlashError.message("导读结构未满足原版最低要求") }
                return
            }
            let text = try await ModelClient.complete(config: model, messages: [.init(role: "system", content: "这是客户端连接测试，请简短回答。"), .init(role: "user", content: "请只回复：KMA Flash 连接成功")]) { _ in }
            print("PASS \(model.name) / \(model.apiStyle): \(text.prefix(150))")
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
}

actor DigestProbe {
    var decoder = DigestStreamDecoder()
    var deltas = 0
    var progressiveUpdates = 0
    var previousBlocks = 0
    func receive(_ text: String) {
        deltas += 1
        try? decoder.append(text)
        let blocks = decoder.preview?.sections.flatMap(\.blocks).count ?? 0
        if blocks > previousBlocks { progressiveUpdates += 1; previousBlocks = blocks }
    }
    func report() -> String { "\(deltas) deltas, \(progressiveUpdates) progressive block updates" }
}

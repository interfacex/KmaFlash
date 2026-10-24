import Foundation

public struct DigestBlock: Codable, Identifiable, Equatable {
    public var type: String
    public var text: String
    public var sourceBlockID: String?
    public var featured: Bool?
    public var recoveredFromCitation: Bool?
    public var isOriginal: Bool { type == "excerpt" && sourceBlockID != nil }
    public var contentLabel: String { type == "quote" ? "要点转述 · 非原文" : type == "unverified" || type == "excerpt" && !isOriginal ? "未核验摘录 · 请核对原文" : isOriginal ? "原文摘录" : "角色解读" }
    public var id: String { type + text }
    public init(type: String, text: String) { self.type = type; self.text = text }
}
public struct DigestSection: Codable, Identifiable, Equatable {
    public var heading: String
    public var blocks: [DigestBlock]
    public var id: String { heading }
    public init(heading: String, blocks: [DigestBlock]) { self.heading = heading; self.blocks = blocks }
}
public struct DigestInsight: Codable, Identifiable, Equatable {
    public var title: String
    public var content: String
    public var id: String { title }
    public init(title: String, content: String) { self.title = title; self.content = content }
}
public struct BookCharacter: Codable, Identifiable, Equatable {
    public var name: String
    public var blurb: String?
    public var id: String { name }
    public init(name: String, blurb: String? = nil) { self.name = name; self.blurb = blurb }
}
public struct DigestContent: Codable, Equatable {
    public var headline: String
    public var sections: [DigestSection]
    public var insights: [DigestInsight]
    public var questions: [String]
    public var characterItems: [BookCharacter]
    public var characters: [String] { characterItems.map(\.name) }
    public init(headline: String, sections: [DigestSection], insights: [DigestInsight] = [], questions: [String] = [], characters: [String] = []) { self.headline = headline; self.sections = sections; self.insights = insights; self.questions = questions; self.characterItems = characters.map { BookCharacter(name: $0) } }
    enum CodingKeys: String, CodingKey { case headline, sections, insights, questions, characters, characterDetails }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = try c.decode(String.self, forKey: .headline)
        sections = try c.decode([DigestSection].self, forKey: .sections)
        insights = try c.decodeIfPresent([DigestInsight].self, forKey: .insights) ?? []
        questions = try c.decodeIfPresent([String].self, forKey: .questions) ?? []
        if let details = try c.decodeIfPresent([BookCharacter].self, forKey: .characterDetails) { characterItems = details }
        else if let rich = try? c.decode([BookCharacter].self, forKey: .characters) { characterItems = rich }
        else { characterItems = (try c.decodeIfPresent([String].self, forKey: .characters) ?? []).map { BookCharacter(name: $0) } }
        var seen = Set<String>()
        characterItems = characterItems.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.name).inserted }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(headline, forKey: .headline); try c.encode(sections, forKey: .sections)
        try c.encode(insights, forKey: .insights); try c.encode(questions, forKey: .questions)
        try c.encode(characters, forKey: .characters)
        try c.encode(characterItems, forKey: .characterDetails)
    }
    public var markdown: String {
        var parts = ["# " + headline]
        for section in sections {
            let body = section.blocks.map { block in (block.type == "quote" ? "原意转述：" : "") + block.text }.joined(separator: "\n\n")
            parts.append("## " + section.heading + "\n\n" + body)
        }
        if !insights.isEmpty {
            parts.append("## 深度洞察")
            for insight in insights { parts.append("### " + insight.title + "\n" + insight.content) }
        }
        if !questions.isEmpty { parts.append("## 问策·深谈\n\n" + questions.map { "- " + $0 }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }
}
public struct ReaderDigest: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var documentID: String
    public var chapterID: String
    public var personaID: String
    public var modelName: String
    public var createdAt = Date()
    public var content: DigestContent
    public init(documentID: String, chapterID: String, personaID: String, modelName: String, content: DigestContent) { self.documentID = documentID; self.chapterID = chapterID; self.personaID = personaID; self.modelName = modelName; self.content = content }
}
public struct ReadingMemory: Codable, Equatable {
    public var understanding: String
    public var openQuestion: String
    public var updatedAt = Date()
    public init(understanding: String, openQuestion: String) { self.understanding = understanding; self.openQuestion = openQuestion }
}
public struct CloseReadingDraft: Codable, Equatable {
    public var goal: String
    public var before: String
    public var after: String
    public var openQuestion: String
    public var updatedAt = Date()
    public init(goal: String, before: String, after: String, openQuestion: String) { self.goal = goal; self.before = before; self.after = after; self.openQuestion = openQuestion }
}
public struct ReadingWorkspaceState: Codable {
    public var digests: [ReaderDigest] = []
    public var memories: [String: ReadingMemory] = [:]
    public var closeReadings: [String: CloseReadingDraft] = [:]
    public var documentPersonas: [String: String] = [:]
    public var modes: [String: String] = [:]
    public var pendingHomePersonaID: String?
    public init() {}
}
public extension LibraryState {
    mutating func upgradeReadingState() {
        guard reading == nil else { return }
        reading = ReadingWorkspaceState()
        // V1 hardcoded Zhang as the fallback. Keep intentional choices (recent list), not the old fallback.
        if selectedPersonaID == "张居正" && !recentPersonaIDs.contains("张居正") { selectedPersonaID = "通用陪读人" }
        for i in documents.indices {
            if documents[i].personaID == "张居正" && !recentPersonaIDs.contains("张居正") { documents[i].personaID = "通用陪读人" }
            if documents[i].personaID != "通用陪读人" || recentPersonaIDs.contains(documents[i].personaID) { reading?.documentPersonas[documents[i].id] = documents[i].personaID }
        }
    }
}

public enum DigestParser {
    public static func parse(_ text: String) throws -> DigestContent {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { throw FlashError.message("导读格式不完整，请重试。原文与已有导读均保留。") }
        let content = try JSONDecoder().decode(DigestContent.self, from: Data(text[start...end].utf8))
        guard !content.headline.isEmpty, !content.sections.isEmpty, content.sections.allSatisfy({ !$0.heading.isEmpty && !$0.blocks.isEmpty && $0.blocks.allSatisfy { ["quote", "voice", "excerpt", "unverified"].contains($0.type) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }) else { throw FlashError.message("导读缺少完整正文，请重新生成。") }
        return content
    }
    public static func preview(_ text: String) -> DigestContent? {
        guard let arrayStart = text.range(of: #""sections"\s*:\s*\["#, options: .regularExpression) else { return nil }
        var sections: [DigestSection] = []; var depth = 0; var inString = false; var escaped = false; var start: String.Index?
        for i in text[arrayStart.upperBound...].indices {
            let c = text[i]
            if inString { if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }; continue }
            if c == "\"" { inString = true; continue }
            if c == "{" { if depth == 0 { start = i }; depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0, let start, let section = try? JSONDecoder().decode(DigestSection.self, from: Data(text[start...i].utf8)) { sections.append(section) } }
            else if c == "]" && depth == 0 { break }
        }
        guard !sections.isEmpty else { return nil }
        return DigestContent(headline: "正在撰写本章导读", sections: sections)
    }
    public static func citations(in text: String, blockCount: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[B(\d+)\]"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text), let n = Int(text[range]), n > 0, n <= blockCount else { return nil }
            let id = "B\(n)"; return seen.insert(id).inserted ? id : nil
        }
    }
}

import Foundation

/// NDJSON protocol shared with KMA; incomplete sections are previews, never saved as complete.
public struct DigestStreamDecoder {
    private var pending = ""
    private var content = DigestContent(headline: "正在撰写本章导读", sections: [])
    private var seen = false
    private var failure: String?
    public private(set) var completedSections = 0
    public init() {}
    public mutating func append(_ delta: String) throws {
        pending += delta
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline]); pending.removeSubrange(...newline)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                do { try consume(line) } catch { failure = error.localizedDescription; throw error }
            }
        }
    }
    private mutating func consume(_ line: String) throws {
        let data = Data(line.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let kind = object["type"] as? String else { throw FlashError.message("导读流格式无效，已有内容保留，可重试。") }
        switch kind {
        case "headline": content.headline = object["text"] as? String ?? content.headline
        case "section": content.sections.append(try JSONDecoder().decode(DigestSection.self, from: data)); completedSections += 1
        case "insight": content.insights.append(try JSONDecoder().decode(DigestInsight.self, from: data))
        case "question": if let text = object["prompt"] as? String { content.questions.append(text) }
        case "character": content.characterItems.append(try JSONDecoder().decode(BookCharacter.self, from: data))
        default: throw FlashError.message("导读流包含未知内容类型，请重试。")
        }
        seen = true
    }
    public var preview: DigestContent? {
        var draft = content
        // A complete line can arrive before its newline. Avoid waiting for the next token.
        var copy = self
        if !pending.isEmpty, (try? copy.consume(pending)) != nil { return copy.content }
        if let heading = Self.stringField("heading", in: pending), let range = pending.range(of: #""blocks"\s*:\s*\["#, options: .regularExpression) {
            let tail = String(pending[range.upperBound...])
            let blocks = Self.objects(tail).compactMap { try? JSONDecoder().decode(DigestBlock.self, from: Data($0.utf8)) }
            if !blocks.isEmpty { draft.sections.append(.init(heading: heading, blocks: blocks)) }
        }
        return seen || !draft.sections.isEmpty ? draft : nil
    }
    public mutating func finish() throws -> DigestContent {
        if let failure { throw FlashError.message(failure) }
        if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try consume(pending); pending = "" }
        guard !content.sections.isEmpty, content.sections.allSatisfy({ !$0.heading.isEmpty && !$0.blocks.isEmpty && $0.blocks.allSatisfy { ["excerpt", "quote", "voice", "unverified"].contains($0.type) && !$0.text.isEmpty } }) else { throw FlashError.message("导读正文不完整，请重试。") }
        return content
    }
    private static func stringField(_ key: String, in text: String) -> String? {
        guard let range = text.range(of: "\"" + key + #""\s*:\s*("(?:[^"\\]|\\.)*")"#, options: .regularExpression), let colon = text[range].firstIndex(of: ":") else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(text[text.index(after: colon)..<range.upperBound].utf8))
    }
    private static func objects(_ text: String) -> [String] {
        var results: [String] = []; var depth = 0; var quoted = false; var escaped = false; var start: String.Index?
        for i in text.indices {
            let c = text[i]
            if quoted { if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }; continue }
            if c == "\"" { quoted = true }
            else if c == "{" { if depth == 0 { start = i }; depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0, let start { results.append(String(text[start...i])) } }
            else if c == "]" && depth == 0 { break }
        }
        return results
    }
}

public enum DigestGrounding {
    public static func verify(_ content: DigestContent, chapter: Chapter) -> DigestContent {
        var result = content
        let sources = chapter.blocks.enumerated().map { index, text -> (String, String, [String.Index], String) in
            let offsets = text.indices.filter { !text[$0].isWhitespace }
            return ("B\(index + 1)", text, offsets, String(offsets.map { text[$0] }))
        }
        for i in result.sections.indices { for j in result.sections[i].blocks.indices {
            var block = result.sections[i].blocks[j]
            guard block.type == "excerpt" else { continue }
            block.sourceBlockID = nil; block.type = "unverified"
            let needle = String(block.text.filter { !$0.isWhitespace })
            if !needle.isEmpty { for (id, original, offsets, compact) in sources {
                guard let range = compact.range(of: needle) else { continue }
                let start = compact.distance(from: compact.startIndex, to: range.lowerBound)
                let end = compact.distance(from: compact.startIndex, to: range.upperBound) - 1
                block.text = String(original[offsets[start]...offsets[end]])
                block.sourceBlockID = id; block.type = "excerpt"; break
            } }
            result.sections[i].blocks[j] = block
        } }
        return result
    }
}

public extension DigestGrounding {
    /// Repair the presentation of legacy summaries from their explicit source citations.
    /// Keep cached model output untouched; never turn its rewritten wording into a quotation.
    static func restoringLegacyExcerpts(_ content: DigestContent, chapter: Chapter) -> DigestContent {
        var result = verify(content, chapter: chapter)
        for i in result.sections.indices {
            for j in result.sections[i].blocks.indices {
                let block = result.sections[i].blocks[j]
                guard block.type == "quote",
                      let id = DigestParser.citations(in: block.text, blockCount: chapter.blocks.count).first,
                      let number = Int(id.dropFirst()), chapter.blocks.indices.contains(number - 1) else { continue }
                let source = chapter.blocks[number - 1]
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                // Skip chapter labels, then take a contiguous, sentence-bounded source slice.
                let first = source.components(separatedBy: .newlines).first { line in
                    let value = line.trimmingCharacters(in: .whitespaces)
                    return !value.isEmpty && value != chapter.title && Int(value) == nil
                }
                let start = first.flatMap { source.range(of: $0)?.lowerBound } ?? source.startIndex
                var quote = String(source[start...].prefix(260))
                if let end = quote.range(of: "。", options: .backwards), quote.distance(from: quote.startIndex, to: end.upperBound) >= 60 {
                    quote = String(quote[..<end.upperBound])
                }
                var excerpt = DigestBlock(type: "excerpt", text: quote)
                excerpt.sourceBlockID = id
                excerpt.recoveredFromCitation = true
                result.sections[i].blocks[j] = excerpt
            }
        }
        return result
    }
}

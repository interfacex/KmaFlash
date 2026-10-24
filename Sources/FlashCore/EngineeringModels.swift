import Foundation
import CryptoKit

public struct EngineeringProject: Codable, Equatable {
    public var archiveFile: String
    public var root: String
    public var index: CodeArchiveIndex
    public var goal: String
    public init(archiveFile: String, root: String, index: CodeArchiveIndex, goal: String = "overview") {
        self.archiveFile = archiveFile; self.root = root; self.index = index; self.goal = goal
    }
    public var files: [CodeArchiveEntry] { index.entries.filter { root.isEmpty || $0.path.hasPrefix(root + "/") || $0.path == root } }
}
public struct MaterialDraft: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var title: String
    public var source: String
    public var kind = "book"
    public var goal = "overview"
    public var root = ""
    public var status = "waiting_user"
    public var detail = ""
    public var progress: Double = 0
    public var fingerprint = ""
    public var localFile: String?
    public var document: ReadingDocument?
    public var archive: CodeArchiveIndex?
    public var startingChapterID: String?
    public var pastedText: String?
    public var splitProjects: Bool?
    public var documentIDs: [String]?
    public var createdAt = Date()
    public init(title: String, source: String) { self.title = title; self.source = source }
}
public struct CodeExcerpt: Codable, Equatable, Identifiable {
    public var path: String
    public var text: String
    public var lineStart: Int
    public var lineEnd: Int
    public var id: String { "\(path):\(lineStart)-\(lineEnd)" }
    public init(path: String, text: String, lineStart: Int, lineEnd: Int) { self.path = path; self.text = text; self.lineStart = lineStart; self.lineEnd = lineEnd }
    public var context: String { "[\(path):L\(lineStart)-L\(lineEnd)]\n" + text }
}
public struct EngineeringStep: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var title: String
    public var question: String
    public var paths: [String]
    public var why: String?
    public var focus: String?
    public var layers: [String: String]?
    public var recap: String?
    public var next: String?
    public var checkPrompt: String?
    public var checkHint: String?
    public var development: String?
    public var excerpts: [CodeExcerpt]?
    public var completed = false
    public var understanding = ""
    public init(title: String, question: String, paths: [String]) { self.title = title; self.question = question; self.paths = paths }
}
public struct EngineeringTurn: Codable, Identifiable, Equatable {
    public var stepID: String?
    public var id = UUID().uuidString
    public var question: String
    public var answer: String
    public var excerpts: [CodeExcerpt]
    public var createdAt = Date()
    public init(question: String, answer: String, excerpts: [CodeExcerpt]) { self.question = question; self.answer = answer; self.excerpts = excerpts }
}
public struct EngineeringJourney: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var documentID: String
    public var title: String
    public var goal: String
    public var steps: [EngineeringStep]
    public var stepIndex = 0
    public var turns: [EngineeringTurn] = []
    public var createdAt = Date()
    public init(documentID: String, title: String, goal: String, steps: [EngineeringStep]) { self.documentID = documentID; self.title = title; self.goal = goal; self.steps = steps }
}
public struct EngineeringState: Codable {
    public var drafts: [MaterialDraft] = []
    public var journeys: [EngineeringJourney] = []
    public init() {}
}
public enum MaterialRecognition {
    public static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func kind(text: String, source: String) -> String {
        let lower = (source + "\n" + String(text.prefix(8000))).lowercased()
        if lower.contains("mp.weixin.qq.com") { return "wechat" }
        if lower.contains("abstract") && (lower.contains("references") || lower.contains("doi") || lower.contains("arxiv")) { return "paper" }
        if ["软件", "编程", "计算机", "技术", "algorithm", "programming"].contains(where: { lower.contains($0) }) { return "tech" }
        return "book"
    }
    public static func sourcePage(path: String, text: String, start: Int = 1, count: Int = 120) -> CodeExcerpt {
        let lines = text.components(separatedBy: "\n")
        let first = min(max(1, start), max(1, lines.count))
        let last = min(lines.count, first + max(1, count) - 1)
        return CodeExcerpt(path: path, text: lines[(first - 1)..<last].joined(separator: "\n"), lineStart: first, lineEnd: last)
    }
}

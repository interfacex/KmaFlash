import Foundation

public struct Chapter: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var title: String
    public var text: String
    public var blockPageNumbers: [Int?]?
    public init(title: String, text: String) { self.title = title; self.text = text }
    public var blocks: [String] { text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}
public struct ReadingDocument: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var title: String
    public var source: String
    public var chapters: [Chapter]
    public var engineering: EngineeringProject?
    public var materialKind: String?
    public var fingerprint: String?
    public var importScope: String?
    public var createdAt = Date()
    public var lastOpenedAt: Date?
    public var chapterIndex = 0
    public var blockIndex = 0
    public var personaID = "通用陪读人"
    public init(title: String, source: String, chapters: [Chapter]) { self.title = title; self.source = source; self.chapters = chapters }
    public var progress: Double { guard !chapters.isEmpty else { return 0 }; let index = min(max(chapterIndex, 0), chapters.count - 1); return (Double(index) + Double(blockIndex + 1) / Double(max(1, chapters[index].blocks.count))) / Double(chapters.count) }
}
public enum ReadingAction: String, Codable, CaseIterable, Identifiable {
    case chat = "原文问答", guide = "生成导读", closeRead = "精读这段", discussion = "人物讨论", character = "书中人物", card = "认知卡"
    public var id: String { rawValue }
    public var instruction: String {
        switch self {
        case .chat: return "先直接回答问题，随后用原文块编号支持你的判断。"
        case .guide: return "生成本章导读：一句话概括、3 个关键观点（各带原文编号）、阅读路径、一个值得思考的问题。用清晰 Markdown，不返回 JSON。"
        case .closeRead: return "对当前选段进行精读：原意、词句和论证结构、隐含前提、与上下文关系、一个理解检验问题。先给分析再提问；引用原文块编号。"
        case .discussion: return "组织当前陪读人物与用户指定人物讨论本章；若未指定，邀请费曼与苏格拉底式导师。分清发言者，至少两轮互相回应，最后给共识、分歧和证据边界。不把演绎当史实。"
        case .character: return "作为用户指定的书中人物，依据本章内容对话。若用户未指明人物，先列出材料中确实出现的人物供选择，不擅造人物。资料外经历明确说明不知。"
        case .card: return "生成一张认知卡：核心认识、原文依据（块编号）、我的可能误区、可迁移的场景、一个可执行行动。区分原文与推断。"
        }
    }
}
public struct ReadingRecord: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var documentID: String
    public var chapterID: String
    public var personaID: String
    public var modelName: String
    public var action: ReadingAction
    public var question: String
    public var answer: String
    public var characterName: String?
    public var createdAt = Date()
    public init(documentID: String, chapterID: String, personaID: String, modelName: String, action: ReadingAction, question: String, answer: String) {
        self.documentID = documentID; self.chapterID = chapterID; self.personaID = personaID; self.modelName = modelName; self.action = action; self.question = question; self.answer = answer
    }
}
public struct ReadingNote: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var title: String
    public var body: String
    public var documentID: String?
    public var chapterID: String?
    public var quote: String
    public var createdAt = Date()
    public var updatedAt = Date()
    public init(title: String, body: String, documentID: String? = nil, chapterID: String? = nil, quote: String = "") { self.title = title; self.body = body; self.documentID = documentID; self.chapterID = chapterID; self.quote = quote }
}
public struct Persona: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var category: String
    public var summary: String
    public var opening: String
    public var aliases: [String]
    public var dossier: String
    public var systemPrompt: String
}
public struct ModelConfiguration: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var model: String
    public var baseURL: String
    public var apiKey: String
    public var apiStyle: String
    public var maxTokens: Int
    public var temperature: Double
    public var thinking: Bool
    public var headers: [String: String]
    public init(id: String = UUID().uuidString, name: String = "自定义模型", model: String = "", baseURL: String = "https://api.openai.com/v1", apiKey: String = "", apiStyle: String = "chat", maxTokens: Int = 8192, temperature: Double = 0.2, thinking: Bool = false, headers: [String: String] = [:]) {
        self.id = id; self.name = name; self.model = model; self.baseURL = baseURL; self.apiKey = apiKey; self.apiStyle = apiStyle; self.maxTokens = maxTokens; self.temperature = temperature; self.thinking = thinking; self.headers = headers
    }
}
public struct LibraryState: Codable {
    public var version = 1
    public var starterMaterialsVersion: Int?
    public var documents: [ReadingDocument] = []
    public var records: [ReadingRecord] = []
    public var notes: [ReadingNote] = []
    public var favoritePersonaIDs: [String] = []
    public var recentPersonaIDs: [String] = []
    public var customModels: [ModelConfiguration] = []
    public var selectedModelID = "demo"
    public var selectedPersonaID = "通用陪读人"
    public var readingRequirements = ""
    public var deepAnswers = false
    public var proactive = false
    public var engineering: EngineeringState?
    public var reading: ReadingWorkspaceState?
    public init() {}
}
public enum Builtins {
    public static func personas() throws -> [Persona] { try decode("personas") }
    public static func models() throws -> [ModelConfiguration] { try decode("models") }
    private static func decode<T: Decodable>(_ name: String) throws -> T {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("KmaFlash_FlashCore.bundle")
        let bundle = packaged.flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let url = bundle.url(forResource: name, withExtension: "json") else { throw FlashError.message("缺少内置资源：\(name)") }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}
public enum FlashError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

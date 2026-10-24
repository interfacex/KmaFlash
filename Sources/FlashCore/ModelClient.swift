import Foundation

public struct ModelMessage: Codable {
    public let role: String
    public let content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}
public enum ModelClient {
    public static func request(config: ModelConfiguration, messages: [ModelMessage], stream: Bool) throws -> URLRequest {
        guard config.id != "demo", URL(string: config.baseURL)?.host?.lowercased() != "example.com" else {
            throw FlashError.message("Demo 仅为配置示例。请在模型设置复制为自定义模型，填写自己的模型名称、服务地址及所需 API Key。")
        }
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: base), ["https", "http"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil, baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { throw FlashError.message("请输入有效的模型 Base URL（含 http:// 或 https://，不含查询参数）。") }
        guard !config.model.trimmingCharacters(in: .whitespaces).isEmpty, config.maxTokens > 0, config.temperature.isFinite, (0...2).contains(config.temperature), ["responses", "chat"].contains(config.apiStyle) else { throw FlashError.message("请检查模型名称、协议、Token 上限和 Temperature（0–2）。") }
        let suffix = config.apiStyle == "responses" ? "/responses" : "/chat/completions"
        guard let endpoint = URL(string: base.hasSuffix(suffix) ? base : base + suffix) else { throw FlashError.message("模型地址无效。") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = (config.apiStyle == "responses" || config.thinking) ? 480 : 90
        for (key, value) in config.headers {
            guard !key.contains("\n"), !key.contains("\r"), !value.contains("\n"), !value.contains("\r") else { throw FlashError.message("请求头不能包含换行。") }
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        let values = messages.map { ["role": $0.role, "content": $0.content] }
        var body: [String: Any] = ["model": config.model, "temperature": config.temperature, "stream": stream]
        if config.apiStyle == "responses" {
            body["input"] = values
            body["max_output_tokens"] = config.maxTokens
            if request.value(forHTTPHeaderField: "X-Provider") == nil { request.setValue("cc-switch", forHTTPHeaderField: "X-Provider") }
        } else {
            body["messages"] = values
            body["max_tokens"] = config.maxTokens
            if config.thinking { body["thinking"] = ["type": "enabled"] }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    public static func responseText(_ data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FlashError.message("模型返回了无法识别的数据。") }
        if object["error"] is [String: Any] || ["failed", "incomplete"].contains(object["status"] as? String ?? "") { throw FlashError.message("模型未完成回答，请稍后重试或调整 Token 上限。") }
        if let text = object["output_text"] as? String, !text.isEmpty { return text }
        if let choices = object["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] {
            if choices.first?["finish_reason"] as? String == "length" { throw FlashError.message("回答达到 Token 上限，请提高上限或缩小问题后重试。") }
            let text = visibleText(message["content"])
            if !text.isEmpty { return text }
        }
        if let output = object["output"] as? [[String: Any]] {
            let text = output.filter { $0["type"] as? String == "message" }.map { visibleText($0["content"]) }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        throw FlashError.message("模型没有返回可显示的正文，请重试或换一个模型。")
    }
    private static func visibleText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return "" }
        return blocks.filter { ["text", "output_text"].contains($0["type"] as? String ?? "") }.compactMap { $0["text"] as? String }.joined()
    }
    public static func eventText(_ payload: String) throws -> (delta: String, done: Bool) {
        if payload == "[DONE]" { return ("", true) }
        guard let data = payload.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FlashError.message("模型流式响应格式无效。") }
        let type = object["type"] as? String ?? ""
        if ["error", "response.failed", "response.incomplete"].contains(type) || object["error"] is [String: Any] {
            let response = object["response"] as? [String: Any] ?? [:]
            let detail = object["error"] as? [String: Any] ?? response["error"] as? [String: Any] ?? [:]
            let code = detail["code"] as? String ?? type
            let safeCode = String(code.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }.prefix(60))
            throw FlashError.message("模型生成中断（\(safeCode)），请重试或切换模型。")
        }
        if type == "response.output_text.delta" { return (object["delta"] as? String ?? "", false) }
        if type == "response.completed" { return ("", true) }
        if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
            if choice["finish_reason"] as? String == "length" { throw FlashError.message("回答达到 Token 上限。请提高上限或缩小问题后重试。") }
            return ((choice["delta"] as? [String: Any])?["content"] as? String ?? "", false)
        }
        return ("", false)
    }
    public static func complete(config: ModelConfiguration, messages: [ModelMessage], onDelta: @escaping @Sendable (String) async -> Void) async throws -> String {
        let request = try request(config: config, messages: messages, stream: true)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = request.timeoutInterval
        sessionConfig.timeoutIntervalForResource = request.timeoutInterval + 30
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw FlashError.message("无法读取模型服务响应。") }
        guard (200..<300).contains(http.statusCode) else { throw FlashError.message(statusMessage(http.statusCode)) }
        let isStream = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/event-stream")
        if !isStream {
            var data = Data()
            for try await byte in bytes { try Task.checkCancellation(); data.append(byte); if data.count > 8_000_000 { throw FlashError.message("模型响应过大。") } }
            let text = try responseText(data)
            await onDelta(text)
            return text
        }
        var answer = ""
        var decoder = SSEDecoder()
        var finished = false
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let payload = try decoder.append(byte) else { continue }
            let event = try eventText(payload)
            answer += event.delta
            if !event.delta.isEmpty { await onDelta(event.delta) }
            if event.done { finished = true; break }
            if answer.utf8.count > 8_000_000 { throw FlashError.message("模型回答过长，请缩小问题。") }
        }
        if !finished, let payload = decoder.finish() {
            let event = try eventText(payload); answer += event.delta
            if !event.delta.isEmpty { await onDelta(event.delta) }
            finished = event.done
        }
        guard finished else { throw FlashError.message("连接在回答完成前断开，请重试。") }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FlashError.message("模型没有返回正文。") }
        return answer
    }
    private static func statusMessage(_ code: Int) -> String {
        switch code {
        case 401, 403: return "模型认证失败（\(code)），请检查 API Key 和网关权限。"
        case 429: return "模型请求过于频繁或额度不足（429），请稍后重试。"
        case 400, 404, 422: return "模型地址、名称或参数不被服务接受（\(code)），请检查模型设置。"
        default: return "模型服务暂时不可用（\(code)），原文仍可阅读，请稍后重试。"
        }
    }
}

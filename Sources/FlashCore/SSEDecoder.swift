import Foundation
/// Byte-based framing preserves empty lines (the SSE event boundary).
public struct SSEDecoder {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var size = 0
    public init() {}
    public mutating func append(_ byte: UInt8) throws -> String? {
        size += 1
        guard size < 8_000_000 else { throw FlashError.message("模型流式事件过大。") }
        if byte == 10 { return consumeLine() }
        line.append(byte)
        return nil
    }
    private mutating func consumeLine() -> String? {
        if line.last == 13 { line.removeLast() }
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            size = 0
            guard !dataLines.isEmpty else { return nil }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            return payload
        }
        if text.hasPrefix("data:") {
            var payload = String(text.dropFirst(5))
            if payload.first == " " { payload.removeFirst() }
            dataLines.append(payload)
        }
        return nil
    }
    public mutating func finish() -> String? {
        if !line.isEmpty, let payload = consumeLine() { return payload }
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(); size = 0
        return payload
    }
}

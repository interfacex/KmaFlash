import Foundation
import PDFKit
public struct ImportProgress: Sendable {
    public var fraction: Double
    public var detail: String
    public init(_ fraction: Double, _ detail: String) { self.fraction = fraction; self.detail = detail }
}
public enum TextImporter {
    public static func chapters(_ text: String) -> [Chapter] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let pattern = #"(?m)^(?:#{1,3}\s+[^\n]{1,76}|第[一二三四五六七八九十百千万零〇两0-9]+[章节部篇卷][^\n]{0,68})$"#
        let matches = (try? NSRegularExpression(pattern: pattern))?.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) ?? []
        let headings = matches.compactMap { Range($0.range, in: normalized) }
        guard !headings.isEmpty else { return split(normalized, heading: nil) }
        var result: [Chapter] = []
        if let first = headings.first, first.lowerBound != normalized.startIndex { result += split(String(normalized[..<first.lowerBound]), heading: "卷首") }
        for (index, range) in headings.enumerated() {
            let end = index + 1 < headings.count ? headings[index + 1].lowerBound : normalized.endIndex
            let title = String(normalized[range]).replacingOccurrences(of: #"^#{1,3}\s+"#, with: "", options: .regularExpression)
            result += split(String(normalized[range.lowerBound..<end]), heading: title)
        }
        return result
    }
    private static func split(_ text: String, heading: String?) -> [Chapter] {
        var remaining = text[...]; var results: [Chapter] = []
        while !remaining.isEmpty {
            var end = remaining.index(remaining.startIndex, offsetBy: 8000, limitedBy: remaining.endIndex) ?? remaining.endIndex
            if end != remaining.endIndex, let boundary = remaining[..<end].range(of: "\n\n", options: .backwards), remaining.distance(from: remaining.startIndex, to: boundary.upperBound) > 3000 { end = boundary.upperBound }
            let part = String(remaining[..<end])
            let firstLine = part.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "正文"
            let title = heading ?? String(firstLine.prefix(32))
            let label = results.isEmpty ? title : title + " · 续\(results.count + 1)"
            results.append(Chapter(title: label, text: part)); remaining = remaining[end...]
        }
        return results
    }
    public static func file(_ url: URL, onProgress: @Sendable (ImportProgress) -> Void = { _ in }) throws -> ReadingDocument {
        onProgress(.init(0, "正在读取文件"))
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 100_000_000 else { throw FlashError.message("文件超过 100 MB，请拆分后导入。") }
        let parts: [Chapter]
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url), !pdf.isLocked else { throw FlashError.message("无法打开 PDF。请检查文件是否损坏或加密。") }
            var pages: [String] = []
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                pages.append(try pdf.page(at: index).map { try PDFReadingOrder.text($0) } ?? "")
                onProgress(.init(Double(index + 1) / Double(max(1, pdf.pageCount)) * 0.9, "正在提取 PDF 第 \(index + 1) / \(pdf.pageCount) 页"))
            }
            onProgress(.init(0.92, "正在整理目录与章节"))
            var outline: [(page: Int, title: String)] = []
            func visit(_ item: PDFOutline) {
                if let page = item.destination?.page, let title = item.label {
                    let index = pdf.index(for: page)
                    if index != NSNotFound { outline.append((index, title)) }
                }
                for i in 0..<item.numberOfChildren { if let child = item.child(at: i) { visit(child) } }
            }
            if let root = pdf.outlineRoot { visit(root) }
            var used = Set<Int>()
            outline = outline.sorted { $0.page < $1.page }.filter { used.insert($0.page).inserted }
            if outline.count >= 2 {
                if outline[0].page > 0 { outline.insert((0, "卷首"), at: 0) }
                var collected: [Chapter] = []
                for (i, item) in outline.enumerated() {
                    let end = i + 1 < outline.count ? outline[i + 1].page : pdf.pageCount
                    let text = (item.page..<end).map { pages[$0] }.joined(separator: "\n\n")
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { collected += split(text, heading: item.title) }
                }
                parts = ReadingPresentation.pageNumbers(for: collected, pages: pages)
            } else {
                parts = ReadingPresentation.pageNumbers(for: chapters(pages.joined(separator: "\n\n")), pages: pages)
            }
        } else {
            let data = try Data(contentsOf: url)
            guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw FlashError.message("无法识别文本编码，请转换为 UTF-8。") }
            onProgress(.init(0.6, "正在划分文本章节"))
            parts = chapters(decoded)
        }
        guard !parts.isEmpty else { throw FlashError.message("未找到可阅读文字。扫描 PDF 请先进行 OCR，再导入。") }
        onProgress(.init(1, "已解析 \(parts.count) 个章节"))
        return ReadingDocument(title: url.deletingPathExtension().lastPathComponent, source: url.lastPathComponent, chapters: parts)
    }
}

import Foundation
import PDFKit
import Vision
import AppKit

public enum PDFReadingOrder {
    /// PDFKit misorders some embedded CJK fonts with negative text matrices.
    /// Use on-device recognition for those pages instead of guessing glyph positions.
    public static func text(_ page: PDFPage) throws -> String {
        let raw = page.string ?? ""
        var mirrored = 0
        for index in 0..<page.numberOfCharacters {
            let bounds = page.characterBounds(at: index)
            if bounds.maxX < 0 && bounds.maxY < 0 { mirrored += 1 }
            if mirrored >= 20 { break }
        }
        guard mirrored >= 20 else { return raw }
        let preview = page.thumbnail(of: NSSize(width: 1800, height: 2400), for: .mediaBox)
        guard let image = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw FlashError.message("PDF 的文字顺序异常，无法生成页面图像，请转换为文本后导入。")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { throw FlashError.message("无法识别 PDF 页面，请转换为文本后导入。") }
        return lines.joined(separator: "\n")
    }
}

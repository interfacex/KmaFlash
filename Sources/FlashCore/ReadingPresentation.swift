import Foundation

public enum ReadingPresentation {
    /// PDF line breaks are layout artifacts; preserve actual blank-line paragraphs.
    public static func flowingExcerpt(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n").map { paragraph in
                paragraph.replacingOccurrences(of: "\n", with: "")
            }.joined(separator: "\n\n")
    }

    public static func pageNumbers(for chapters: [Chapter], pages: [String]) -> [Chapter] {
        let compactPages = pages.map { String($0.filter { !$0.isWhitespace }) }
        var cursor = 0
        return chapters.map { chapter in
            var result = chapter
            result.blockPageNumbers = chapter.blocks.map { block in
                let needle = String(block.filter { !$0.isWhitespace })
                guard !needle.isEmpty else { return nil }
                // A split chapter can start or finish within a physical page.
                for index in cursor..<compactPages.count {
                    if compactPages[index].contains(needle) {
                        cursor = index
                        return index + 1
                    }
                }
                return nil
            }
            return result
        }
    }
}

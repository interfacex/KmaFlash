import Foundation
public enum CodeCitation {
    /// Never turn an ungrounded model path or line number into a source locator.
    public static func verifiedText(_ text: String, excerpts: [CodeExcerpt]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]\n]+):L(\d+)(?:[-–]L?(\d+))?\]"#) else { return text }
        let original = text as NSString
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            let path = original.substring(with: match.range(at: 1))
            let start = Int(original.substring(with: match.range(at: 2))) ?? 0
            let end = match.range(at: 3).location == NSNotFound ? start : (Int(original.substring(with: match.range(at: 3))) ?? 0)
            let valid = start > 0 && end >= start && excerpts.contains { $0.path == path && start >= $0.lineStart && end <= $0.lineEnd }
            if !valid { result.replaceCharacters(in: match.range, with: "[未核实的源码引用]") }
        }
        return result as String
    }
}

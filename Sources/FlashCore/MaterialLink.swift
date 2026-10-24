import Foundation

public struct MaterialLinkTarget: Codable, Equatable, Sendable {
    public var kind: String
    public var url: String
    public var title: String
    public var branch: String?
    public var prefix: String?
    public init(kind: String, url: String, title: String, branch: String? = nil, prefix: String? = nil) {
        self.kind = kind; self.url = url; self.title = title; self.branch = branch; self.prefix = prefix
    }
}
public struct MaterialLinkResult {
    public var target: MaterialLinkTarget
    public var localFile: URL?
    public var document: ReadingDocument?
}

public enum MaterialLink {
    public static func recognize(_ input: String) throws -> MaterialLinkTarget {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else {
            throw FlashError.message("请粘贴不含登录信息的 HTTPS 链接。")
        }
        let p = url.path.split(separator: "/").map(String.init)
        if ["github.com", "gitee.com", "gitlab.com"].contains(host) {
            var project: [String]; var tail: [String]
            if host == "gitlab.com", let marker = p.firstIndex(of: "-") {
                project = Array(p[..<marker]); tail = Array(p.dropFirst(marker + 1))
            } else if host == "gitlab.com" { project = p; tail = [] }
            else { project = Array(p.prefix(2)); tail = Array(p.dropFirst(2)) }
            guard project.count >= 2, !project.contains(where: { $0 == "." || $0 == ".." }) else { throw FlashError.message("请粘贴具体的公开仓库链接。") }
            if project[project.count - 1].hasSuffix(".git") { project[project.count - 1].removeLast(4) }
            guard tail.isEmpty || (["tree", "blob"].contains(tail[0]) && tail.count >= 2) else {
                throw FlashError.message("讨论、PR 和其他页面不能作为仓库导入，请使用仓库或分支目录链接。")
            }
            let prefix = tail.count > 2 ? tail.dropFirst(2).joined(separator: "/") : nil
            guard !(prefix?.split(separator: "/").contains("..") ?? false) else { throw FlashError.message("仓库路径无效。") }
            return .init(kind: "code", url: "https://\(host)/\(project.joined(separator: "/"))", title: project.joined(separator: "/"), branch: tail.count >= 2 ? tail[1] : nil, prefix: prefix)
        }
        if host == "mp.weixin.qq.com", p.first == "s" { return .init(kind: "wechat", url: raw, title: "微信公众号文章") }
        if host == "arxiv.org", p.count >= 2, ["abs", "pdf"].contains(p[0]) {
            let id = p.dropFirst().joined(separator: "/").replacingOccurrences(of: #"\.pdf$"#, with: "", options: .regularExpression)
            guard id.range(of: #"^(?:[0-9]{4}\.[0-9]{4,5}|[A-Za-z.-]+/[0-9]{7})(?:v[0-9]+)?$"#, options: .regularExpression) != nil else { throw FlashError.message("arXiv 论文编号无效。") }
            return .init(kind: "paper", url: "https://arxiv.org/pdf/\(id)", title: id)
        }
        if host == "doi.org", url.path.hasPrefix("/10."), p.count >= 2 { return .init(kind: "paper", url: raw, title: String(url.path.dropFirst())) }
        throw FlashError.message("支持 GitHub、GitLab.com、Gitee 公开仓库、微信文章和 arXiv。其他来源请上传文件或粘贴正文。")
    }

    public static func fetch(_ input: String, directory: URL, progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) async throws -> MaterialLinkResult {
        let target = try recognize(input)
        guard let source = URL(string: target.url) else { throw FlashError.message("链接无效。") }
        if source.host == "doi.org" { throw FlashError.message("DOI 链接通常指向出版商页面，无法保证取得论文全文。请下载并上传 PDF。") }
        try Task.checkCancellation()
        progress(.init(0.02, "正在连接公开来源"))
        var download = source
        if target.kind == "code" {
            let ref = target.branch ?? "HEAD"
            let encoded = ref.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ref
            let host = source.host ?? ""
            if host == "github.com" { download = URL(string: "https://api.github.com/repos\(source.path)/zipball/\(encoded)")! }
            else if host == "gitlab.com" {
                let project = String(source.path.dropFirst()).addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
                download = URL(string: "https://gitlab.com/api/v4/projects/\(project)/repository/archive.zip?sha=\(encoded)")!
            } else {
                var branch = ref
                if target.branch == nil {
                    let meta = try await boundedData(URL(string: "https://gitee.com/api/v5/repos\(source.path)")!, limit: 2_000_000, progress: { _ in })
                    guard let object = try JSONSerialization.jsonObject(with: meta) as? [String: Any], let defaultBranch = object["default_branch"] as? String else { throw FlashError.message("无法取得默认分支，请使用明确的分支链接或上传 ZIP。") }
                    branch = defaultBranch
                }
                let safeBranch = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
                download = URL(string: "https://gitee.com\(source.path)/repository/archive/\(safeBranch).zip")!
            }
        }
        let data = try await boundedData(download, limit: target.kind == "wechat" ? 8_000_000 : 100_000_000, progress: progress)
        try Task.checkCancellation()
        if target.kind == "wechat" {
            guard let html = String(data: data, encoding: .utf8) else { throw FlashError.message("文章编码无法识别，请粘贴正文。") }
            let article = try articleText(html)
            let doc = ReadingDocument(title: article.title, source: target.url, chapters: TextImporter.chapters(article.body))
            progress(.init(1, "文章正文已提取"))
            return .init(target: target, localFile: nil, document: doc)
        }
        let isPDF = target.kind == "paper"
        guard isPDF ? data.starts(with: Data("%PDF-".utf8)) : data.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
            throw FlashError.message("来源未返回有效的\(isPDF ? "PDF" : "ZIP")，可能需要登录或验证。请下载文件后导入。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(isPDF ? "pdf" : "zip")
        try data.write(to: file, options: .atomic)
        progress(.init(1, "下载完成，正在准备导入"))
        return .init(target: target, localFile: file, document: nil)
    }

    static func articleText(_ html: String) throws -> (title: String, body: String) {
        // Restrict extraction to the actual WeChat content element, excluding challenge/login pages.
        guard let opening = html.range(of: #"(?is)<(?:div|section)\b[^>]*\bid\s*=\s*["']js_content["'][^>]*>"#, options: .regularExpression) else {
            throw FlashError.message("未取得微信文章正文，可能已删除、需要验证或限制访问。请在浏览器打开后粘贴正文。")
        }
        let remainder = String(html[opening.upperBound...])
        let tag = String(html[opening]).lowercased().hasPrefix("<div") ? "div" : "section"
        let regex = try NSRegularExpression(pattern: "(?is)</?\(tag)\\b[^>]*>")
        var depth = 1; var end = remainder.endIndex
        for match in regex.matches(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)) {
            guard let range = Range(match.range, in: remainder) else { continue }
            depth += remainder[range].hasPrefix("</") ? -1 : 1
            if depth == 0 { end = range.lowerBound; break }
        }
        guard depth == 0 else { throw FlashError.message("文章正文结构不完整，请粘贴正文或上传文件。") }
        let body = plainHTML(String(remainder[..<end]))
        guard body.count >= 40 else { throw FlashError.message("文章正文不完整，请粘贴正文或上传文件。") }
        let titlePattern = #"(?is)<title[^>]*>(.*?)</title>"#
        let titleRegex = try NSRegularExpression(pattern: titlePattern)
        let title = titleRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)).flatMap { Range($0.range(at: 1), in: html) }.map { plainHTML(String(html[$0])) } ?? "微信公众号文章"
        return (title.isEmpty ? "微信公众号文章" : title, body)
    }
    static func plainHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|div|section|h[1-6]|li|blockquote)>"#, with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] { text = text.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let r = Range(match.range, in: text), let digits = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[digits]); let number = value.hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
                if let number, let scalar = UnicodeScalar(number) { text.replaceSubrange(r, with: String(scalar)) }
            }
        }
        return text.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression).replacingOccurrences(of: #"\n\s*\n(?:\s*\n)+"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func allowedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) && ["github.com", "api.github.com", "codeload.github.com", "gitlab.com", "gitee.com", "mp.weixin.qq.com", "arxiv.org", "export.arxiv.org"].contains(url.host?.lowercased() ?? "")
    }
    private static func boundedData(_ url: URL, limit: Int, progress: @escaping @Sendable (ImportProgress) -> Void) async throws -> Data {
        guard allowedDownload(url) else { throw FlashError.message("来源跳转到了未支持的地址，请手动下载文件。") }
        let delegate = LinkRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("KmaFlash/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let final = response.url, allowedDownload(final) else { throw FlashError.message("公开来源无法访问，可能需要登录、验证或触发限流。请重试或下载文件后导入。") }
        guard response.expectedContentLength <= limit else { throw FlashError.message("下载超过大小限制，请缩小仓库范围或上传文件。") }
        var data = Data(); data.reserveCapacity(min(limit, 1_000_000))
        for try await byte in bytes {
            if data.count % 65_536 == 0 { try Task.checkCancellation() }
            guard data.count < limit else { throw FlashError.message("下载超过大小限制，请上传较小的文件。") }
            data.append(byte)
            if data.count % 262_144 == 0 { progress(.init(response.expectedContentLength > 0 ? min(0.95, Double(data.count) / Double(response.expectedContentLength)) : 0.4, "已下载 \(data.count / 1024) KB")) }
        }
        return data
    }
}
private final class LinkRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(MaterialLink.allowedDownload) == true && task.countOfBytesReceived < 100_000_000 ? request : nil)
    }
}

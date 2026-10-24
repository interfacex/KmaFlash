import Foundation
import zlib

public struct CodeArchiveEntry: Codable, Identifiable, Equatable {
    public var path: String
    public var size: Int
    public var reason: String?
    public var id: String { path }
}
public struct CodeArchiveIndex: Codable, Equatable {
    public var entries: [CodeArchiveEntry]
    public var roots: [String]
    public var suggestedRoot: String
    public var languages: [String]
    public var archiveName: String
}
public enum CodeArchiveError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// Reads ZIP members in memory without extracting files or executing project code.
public final class CodeArchive {
    private struct Member { var name: String; var size: Int; var compressed: Int; var offset: Int; var method: Int; var crc: UInt32; var flags: Int; var symlink: Bool }
    private let bytes: Data
    private let archiveName: String
    private var members: [String: Member] = [:]
    private var inventory: [CodeArchiveEntry] = []
    private var centralOffset = 0
    private let lock = NSRecursiveLock()
    private static let excluded = Set("node_modules vendor dist build .git __pycache__ .venv venv target pods deriveddata .next coverage .idea .gradle out bin obj third_party thirdparty external .svn bower_components".split(separator: " ").map(String.init))
    private static let locks = Set("package-lock.json yarn.lock pnpm-lock.yaml podfile.lock cargo.lock composer.lock gemfile.lock".split(separator: " ").map(String.init))
    private static let markers = Set("package.json pyproject.toml go.mod cargo.toml pom.xml build.gradle build.gradle.kts cmakelists.txt composer.json gemfile requirements.txt setup.py package.swift".split(separator: " ").map(String.init))
    private static let extensions = Set("py js ts tsx jsx go rs java kt kts swift c h cc cpp hpp m mm rb php cs scala vue ets sql json jsonc yaml yml toml ini cfg conf xml sh bash zsh css scss html md markdown txt pdf rst".split(separator: " ").map(String.init))
    private static let names = Set("makefile dockerfile .gitignore .gitattributes .editorconfig .rgignore readme license licence".split(separator: " ").map(String.init))
    private static let sensitiveName = #"(^|/)\.env($|\.)|(^|/)id_rsa($|\.)|credentials\.json$|\.pem$|\.p12$|(^|/)secrets?\.|(^|/)[^/]*secret[^/]*\.(json|ya?ml|txt)$"#
    private static let sensitiveBody = #"-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|xox[baprs]-"#
    private func fail(_ message: String) -> CodeArchiveError { .invalid(message) }
    private func number(_ at: Int, _ count: Int) throws -> Int {
        guard at >= 0, count <= bytes.count, at <= bytes.count - count else { throw fail("ZIP 数据已截断") }
        let value = (0..<count).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << ($1 * 8) }
        guard value <= UInt64(Int.max) else { throw fail("ZIP 数值超过安全范围") }
        return Int(value)
    }
    private static func valid(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("\0") && !name.contains(":") && !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
    }
    public init(url: URL) throws {
        archiveName = url.lastPathComponent
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= 512 * 1024 * 1024 else { throw CodeArchiveError.invalid("ZIP 超过 512 MB 扫描上限") }
        bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count >= 22 else { throw fail("不是有效的 ZIP") }
        var end: Int?
        for p in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) {
            if try number(p, 4) == 0x06054b50, p + 22 + (try number(p + 20, 2)) == bytes.count { end = p; break }
        }
        guard let end else { throw fail("ZIP 中央目录缺失") }
        var count = try number(end + 10, 2), centralSize = try number(end + 12, 4), central = try number(end + 16, 4)
        var centralEnd = end
        guard try number(end + 4, 2) == 0, try number(end + 6, 2) == 0, try number(end + 8, 2) == count else { throw fail("不支持多卷 ZIP") }
        let hasLocator = try end >= 20 && number(end - 20, 4) == 0x07064b50
        if hasLocator {
            guard try number(end - 16, 4) == 0, try number(end - 4, 4) == 1 else { throw fail("不支持多卷 ZIP64") }
            let record = try number(end - 12, 8)
            guard record <= end - 76, try number(record, 4) == 0x06064b50 else { throw fail("ZIP64 目录记录无效") }
            let length = try number(record + 4, 8)
            guard length >= 44, length == end - 20 - record - 12,
                  try number(record + 16, 4) == 0, try number(record + 20, 4) == 0 else { throw fail("ZIP64 目录长度或磁盘无效") }
            count = try number(record + 32, 8)
            guard try number(record + 24, 8) == count else { throw fail("ZIP64 成员计数不匹配") }
            centralSize = try number(record + 40, 8)
            central = try number(record + 48, 8)
            centralEnd = record
        } else if count == 65535 || central == 0xffffffff || centralSize == 0xffffffff { throw fail("ZIP64 定位记录缺失") }
        guard count <= 200_000 else { throw fail("ZIP 超过 200,000 项安全扫描上限，未导入任何文件") }
        guard central <= centralEnd, centralSize == centralEnd - central else { throw fail("ZIP 中央目录范围无效") }
        centralOffset = central
        var p = central
        var scanned: [Member] = []
        for _ in 0..<count {
            guard try number(p, 4) == 0x02014b50 else { throw fail("ZIP 中央目录损坏") }
            let flags = try number(p + 8, 2), method = try number(p + 10, 2), crc = try number(p + 16, 4)
            var compressed = try number(p + 20, 4), size = try number(p + 24, 4)
            let nameLength = try number(p + 28, 2), extra = try number(p + 30, 2), comment = try number(p + 32, 2)
            let attr = try number(p + 38, 4)
            var offset = try number(p + 42, 4), disk = try number(p + 34, 2)
            let next = p + 46 + nameLength + extra + comment
            guard next <= centralEnd else { throw fail("ZIP 成员目录损坏") }
            var field = p + 46 + nameLength
            let extraEnd = field + extra
            var foundZIP64 = false
            while field < extraEnd {
                guard extraEnd - field >= 4 else { throw fail("ZIP 扩展字段截断") }
                let tag = try number(field, 2), length = try number(field + 2, 2)
                let fieldEnd = field + 4 + length
                guard fieldEnd <= extraEnd else { throw fail("ZIP 扩展字段长度无效") }
                if tag == 1 {
                    guard !foundZIP64 else { throw fail("ZIP64 扩展字段重复") }
                    foundZIP64 = true
                    var value = field + 4
                    func take(_ width: Int) throws -> Int {
                        guard value <= fieldEnd - width else { throw fail("ZIP64 扩展字段截断") }
                        defer { value += width }
                        return try number(value, width)
                    }
                    if size == 0xffffffff { size = try take(8) }
                    if compressed == 0xffffffff { compressed = try take(8) }
                    if offset == 0xffffffff { offset = try take(8) }
                    if disk == 65535 { disk = try take(4) }
                }
                field = fieldEnd
            }
            guard size != 0xffffffff, compressed != 0xffffffff, offset < central, disk == 0 else { throw fail("ZIP64 扩展字段缺失或成员目录无效") }
            let raw = bytes.subdata(in: p+46..<p+46+nameLength)
            guard let decoded = String(data: raw, encoding: .utf8) ?? ((flags & 0x800 == 0) ? String(data: raw, encoding: .isoLatin1) : nil) else { throw fail("ZIP 文件名编码无效") }
            let name = decoded.replacingOccurrences(of: "\\", with: "/")
            let directory = name.hasSuffix("/")
            let checked = directory ? String(name.dropLast()) : name
            guard Self.valid(checked) else { throw fail("压缩包路径越界：\(name)") }
            guard flags & 0x41 == 0 else { throw fail("压缩包已加密") }
            guard !(size > 1024 * 1024 && Double(size) / Double(max(compressed, 1)) > 80) else { throw fail("压缩比异常：\(name)") }
            if !directory { scanned.append(Member(name: name, size: size, compressed: compressed, offset: offset, method: method, crc: UInt32(crc), flags: flags, symlink: (attr >> 16) & 0o170000 == 0o120000)) }
            p = next
        }
        guard p == centralEnd else { throw fail("ZIP 中央目录长度不匹配") }
        let tops = Set(scanned.map { String($0.name.split(separator: "/")[0]) })
        let prefix = tops.count == 1 && scanned.allSatisfy({ $0.name.contains("/") }) ? (tops.first! + "/") : ""
        for member in scanned {
            let path = String(member.name.dropFirst(prefix.count))
            guard members[path] == nil else { throw fail("ZIP 包含重复路径：\(path)") }
            members[path] = member
            inventory.append(CodeArchiveEntry(path: path, size: member.size, reason: Self.reason(path, member)))
        }
        guard inventory.filter({ $0.reason == nil }).count <= 100_000 else { throw fail("ZIP 超过 100,000 个可读文件上限，未导入任何文件") }
        inventory.sort { $0.path < $1.path }
    }
    private static func reason(_ path: String, _ m: Member) -> String? {
        let lower = path.lowercased(), name = (lower as NSString).lastPathComponent, ext = (name as NSString).pathExtension
        if m.symlink { return "符号链接，不跟随、不读取" }
        if lower.split(separator: "/").contains(where: { excluded.contains(String($0)) }) { return "依赖目录、构建产物或缓存，默认不读" }
        if locks.contains(name) { return "锁定文件，默认不读" }
        if lower.range(of: sensitiveName, options: .regularExpression) != nil { return "疑似凭据，已默认排除" }
        if m.size > 200_000 { return "超过单文件 200 KB 上限" }
        if ![0, 8].contains(m.method) { return "不支持此 ZIP 压缩算法" }
        if !extensions.contains(ext) && !markers.contains(name) && !names.contains(name) && !name.hasPrefix("readme") && ext != "sln" && ext != "xcodeproj" { return "非支持的文本格式" }
        return nil
    }
    public func index() throws -> CodeArchiveIndex {
        let paths = inventory.filter { $0.reason == nil }.map(\.path)
        var roots = Set<String>()
        for path in paths where Self.markers.contains((path as NSString).lastPathComponent.lowercased()) || path.hasSuffix(".sln") || path.hasSuffix(".xcodeproj") {
            roots.insert(path.contains("/") ? String(path.split(separator: "/")[0]) : ".")
        }
        if roots.contains(".") { roots = ["."] }
        let languages = ["py":"Python", "js":"JavaScript", "jsx":"JavaScript", "ts":"TypeScript", "tsx":"TypeScript", "go":"Go", "rs":"Rust", "java":"Java", "kt":"Kotlin", "swift":"Swift", "c":"C", "cpp":"C++", "ets":"ArkTS", "rb":"Ruby", "php":"PHP", "cs":"C#", "h":"C", "cc":"C++", "hpp":"C++", "m":"Objective-C", "mm":"Objective-C++", "kts":"Kotlin", "scala":"Scala", "vue":"Vue", "sql":"SQL"]
        return CodeArchiveIndex(entries: inventory, roots: roots.sorted(), suggestedRoot: roots.sorted().first ?? ".", languages: Set(paths.compactMap { languages[($0 as NSString).pathExtension.lowercased()] }).sorted(), archiveName: archiveName)
    }
    public func data(path: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard Self.valid(path), let m = members[path] else { throw fail("ZIP 中没有这个文件") }
        if let reason = Self.reason(path, m) { throw fail(reason) }
        let p = m.offset
        guard try number(p, 4) == 0x04034b50, try number(p+6, 2) == m.flags, try number(p+8, 2) == m.method else { throw fail("ZIP 本地文件头不匹配") }
        let nameLength = try number(p+26, 2), extra = try number(p+28, 2)
        let start = p + 30 + nameLength + extra
        guard start <= centralOffset, m.compressed <= centralOffset - start else { throw fail("ZIP 文件数据已截断") }
        let localName = bytes.subdata(in: p+30..<p+30+nameLength)
        guard let name = String(data: localName, encoding: .utf8) ?? String(data: localName, encoding: .isoLatin1), name.replacingOccurrences(of: "\\", with: "/") == m.name else { throw fail("ZIP 本地路径不匹配") }
        let compressed = bytes.subdata(in: start..<start+m.compressed)
        var result: Data
        if m.method == 0 { result = compressed } else {
            result = Data(count: max(m.size, 1))
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw fail("ZIP 解压初始化失败") }
            defer { inflateEnd(&stream) }
            let status = compressed.withUnsafeBytes { source in result.withUnsafeMutableBytes { destination -> Int32 in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return inflate(&stream, Z_FINISH)
            } }
            guard status == Z_STREAM_END, stream.total_out == m.size, stream.total_in == m.compressed else { throw fail("ZIP 解压失败或大小不匹配") }
            result.count = m.size
        }
        let checksum = result.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        guard result.count == m.size, UInt32(checksum) == m.crc else { throw fail("ZIP 文件 CRC 校验失败") }
        if let text = String(data: result, encoding: .utf8), text.range(of: Self.sensitiveBody, options: .regularExpression) != nil { throw fail("文件含疑似密钥，已排除") }
        return result
    }
    public func text(path: String) throws -> String {
        guard (path as NSString).pathExtension.lowercased() != "pdf" else { throw fail("PDF 请使用文档阅读器解析") }
        let result = try data(path: path)
        guard !result.prefix(1024).contains(0), let text = String(data: result, encoding: .utf8) else { throw fail("文件不是 UTF-8 文本") }
        return text
    }
}

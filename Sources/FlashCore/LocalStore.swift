import Foundation
public final class LocalStore {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("library.json") }
    public var backupURL: URL { directory.appendingPathComponent("library.backup.json") }
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KmaFlash", isDirectory: true)
    }
    public func load() throws -> LibraryState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        var state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: fileURL))
        guard state.version == 1 else { throw FlashError.message("数据来自更新的应用版本，请升级后打开。") }
        // Optional recovery metadata for books imported before PDF page tracking existed.
        let recovery = directory.appendingPathComponent("pdf-page-index.json")
        if let data = try? Data(contentsOf: recovery), let map = try? JSONDecoder().decode([String: [Int?]].self, from: data) {
            for d in state.documents.indices {
                for c in state.documents[d].chapters.indices {
                    let chapter = state.documents[d].chapters[c]
                    if chapter.blockPageNumbers == nil, let pages = map[chapter.id], pages.count == chapter.blocks.count {
                        state.documents[d].chapters[c].blockPageNumbers = pages
                    }
                }
            }
        }
        return state
    }
    public func save(_ state: LibraryState) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        if fm.fileExists(atPath: fileURL.path) {
            let previous = try Data(contentsOf: fileURL)
            _ = try JSONDecoder().decode(LibraryState.self, from: previous)
            try previous.write(to: backupURL, options: .atomic)
        }
        try data.write(to: fileURL, options: .atomic)
    }
}

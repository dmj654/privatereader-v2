import Foundation

/// 在线书的本地清单。存在书自己的目录里，不占数据库。
///
/// 目录本身只有章节名和地址，很小；正文按章缓存在 `Cache/<bookId>/<index>/body.txt`。
/// 这样「加入书架」不用等整本下载，打开第一章就能读。
public struct OnlineManifest: Codable, Equatable, Sendable {
    public var bookId: String
    public var sourceId: String
    public var bookUrl: String
    public var tocUrl: String
    public var title: String
    public var author: String
    public var coverUrl: String
    public var intro: String
    public var kind: String
    public var chapters: [OnlineChapter]
    public var updatedAt: Int

    public init(bookId: String,
                sourceId: String,
                bookUrl: String,
                tocUrl: String = "",
                title: String,
                author: String = "",
                coverUrl: String = "",
                intro: String = "",
                kind: String = "",
                chapters: [OnlineChapter],
                updatedAt: Int = Int(Date().timeIntervalSince1970)) {
        self.bookId = bookId
        self.sourceId = sourceId
        self.bookUrl = bookUrl
        self.tocUrl = tocUrl
        self.title = title
        self.author = author
        self.coverUrl = coverUrl
        self.intro = intro
        self.kind = kind
        self.chapters = chapters
        self.updatedAt = updatedAt
    }
}

/// 在线书在沙盒里的落盘规则：清单 + 按章正文缓存。
public struct OnlineLibrary {
    public let paths: SandboxPaths
    private let fileManager = FileManager.default

    public init(paths: SandboxPaths) {
        self.paths = paths
    }

    // MARK: 清单

    /// 数据库里 `book.filePath` 存的就是这个相对路径。
    public func manifestRelativePath(bookId: String) -> String {
        "Books/\(bookId)/online-manifest.json"
    }

    public func manifestURL(bookId: String) -> URL {
        paths.bookDirectory(bookId).appendingPathComponent("online-manifest.json")
    }

    @discardableResult
    public func save(_ manifest: OnlineManifest) throws -> String {
        let directory = paths.bookDirectory(manifest.bookId)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(bookId: manifest.bookId), options: .atomic)
        return manifestRelativePath(bookId: manifest.bookId)
    }

    public func loadManifest(bookId: String) throws -> OnlineManifest {
        let data = try Data(contentsOf: manifestURL(bookId: bookId))
        return try JSONDecoder().decode(OnlineManifest.self, from: data)
    }

    public func loadManifest(book: Book) throws -> OnlineManifest {
        if let filePath = book.filePath, !filePath.isEmpty {
            let url = paths.root.appendingPathComponent(filePath)
            if fileManager.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(OnlineManifest.self, from: data)
            }
        }
        return try loadManifest(bookId: book.id)
    }

    // MARK: 正文缓存

    private func bodyURL(bookId: String, index: Int) -> URL {
        paths.cacheDirectory(bookID: bookId, chapterIndex: index)
            .appendingPathComponent("body.txt", isDirectory: false)
    }

    public func chapterText(bookId: String, index: Int) -> String? {
        let url = bodyURL(bookId: bookId, index: index)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.isEmpty ? nil : text
    }

    public func hasChapter(bookId: String, index: Int) -> Bool {
        chapterText(bookId: bookId, index: index) != nil
    }

    public func storeChapterText(_ text: String, bookId: String, index: Int) throws {
        let directory = paths.cacheDirectory(bookID: bookId, chapterIndex: index)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: bodyURL(bookId: bookId, index: index), options: .atomic)
    }

    public func removeChapterText(bookId: String, index: Int) throws {
        let directory = paths.cacheDirectory(bookID: bookId, chapterIndex: index)
        try? fileManager.removeItem(at: directory)
    }

    /// 已缓存的章节下标，升序。离线时用它告诉用户"能看哪些"。
    public func cachedChapterIndices(bookId: String, chapterCount: Int) -> [Int] {
        guard chapterCount > 0 else { return [] }
        return (0..<chapterCount).filter { hasChapter(bookId: bookId, index: $0) }
    }

    public func cachedCount(bookId: String) -> Int {
        cacheSize(bookId: bookId).chapterCount
    }

    // MARK: 占用

    public struct CacheUsage: Equatable, Sendable {
        public var bytes: Int64
        public var chapterCount: Int

        public var text: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    public func cacheSize(bookId: String) -> CacheUsage {
        let root = paths.cache.appendingPathComponent(bookId, isDirectory: true)
        return usage(of: root)
    }

    public func totalCacheSize() -> CacheUsage {
        usage(of: paths.cache)
    }

    private func usage(of directory: URL) -> CacheUsage {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return CacheUsage(bytes: 0, chapterCount: 0)
        }

        var bytes: Int64 = 0
        var chapters = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            bytes += Int64(values?.fileSize ?? 0)
            if url.lastPathComponent == "body.txt" { chapters += 1 }
        }
        return CacheUsage(bytes: bytes, chapterCount: chapters)
    }

    public func clearCache(bookId: String) {
        try? fileManager.removeItem(at: paths.cache.appendingPathComponent(bookId, isDirectory: true))
    }

    public func clearAllCache() {
        try? fileManager.removeItem(at: paths.cache)
        try? fileManager.createDirectory(at: paths.cache, withIntermediateDirectories: true)
    }

    /// 删书时把清单目录和缓存一起清掉。
    public func remove(bookId: String) {
        try? fileManager.removeItem(at: paths.bookDirectory(bookId))
        clearCache(bookId: bookId)
    }
}

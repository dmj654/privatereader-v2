import Foundation

/// 章节正文的来源：首次打开解析原文件，之后走内存缓存。
/// 不写盘——本地书本来就在手机上，再存一份正文等于双倍占用。
public final class ChapterProvider {
    private let paths: SandboxPaths
    private let importer: ImportService
    private let online: OnlineReadingService?
    private var cache: [String: [NovelChapter]] = [:]
    private let lock = NSLock()

    public init(paths: SandboxPaths,
                importer: ImportService = ImportService(),
                online: OnlineReadingService? = nil) {
        self.paths = paths
        self.importer = importer
        self.online = online
    }

    public func chapters(for book: Book) throws -> [NovelChapter] {
        // 在线书每次都从清单读：正文缓存会变，不能把「空正文」缓存下来。
        if book.origin == .remote {
            guard let online else { throw ImportError.unreadableFile(book.title) }
            return try online.chapters(for: book)
        }

        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[book.id] { return cached }

        guard let filePath = book.filePath else {
            throw ImportError.unreadableFile(book.title)
        }
        let url = paths.root.appendingPathComponent(filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.unreadableFile(book.title)
        }

        let content = try importer.parse(url: url)
        guard case .novel(let novel) = content else {
            throw ImportError.unsupportedFormat(url.pathExtension)
        }

        cache[book.id] = novel.chapters
        return novel.chapters
    }

    public func cachedChapterCount(bookId: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return cache[bookId]?.count
    }

    // MARK: 在线正文

    public var supportsOnlineReading: Bool { online != nil }

    /// 取一章正文。本地书直接返回解析结果，在线书走「缓存优先 + 按需下载」。
    public func body(for book: Book, index: Int, forceRefresh: Bool = false) async throws -> String {
        if book.origin == .remote {
            guard let online else { throw ImportError.unreadableFile(book.title) }
            return try await online.body(for: book, index: index, forceRefresh: forceRefresh)
        }
        let chapters = try chapters(for: book)
        guard chapters.indices.contains(index) else { throw ImportError.unreadableFile(book.title) }
        return chapters[index].body
    }

    public func cachedBody(for book: Book, index: Int) -> String? {
        guard book.origin == .remote, let online else { return nil }
        return online.cachedBody(for: book, index: index)
    }

    public func prefetch(for book: Book, around index: Int) async {
        guard book.origin == .remote, let online else { return }
        await online.prefetch(for: book, around: index)
    }

    public func refreshToc(for book: Book) async throws -> Int {
        guard book.origin == .remote, let online else { return 0 }
        return try await online.refreshToc(for: book)
    }

    public func cachedChapterIndices(for book: Book) -> [Int] {
        guard book.origin == .remote, let online else { return [] }
        return online.cachedChapterIndices(for: book)
    }

    public func cacheUsage(for book: Book) -> OnlineLibrary.CacheUsage? {
        guard book.origin == .remote, let online else { return nil }
        return online.cacheUsage(for: book)
    }

    public func clearCache(for book: Book) {
        guard book.origin == .remote, let online else { return }
        online.clearCache(for: book)
    }

    public func downloadAll(for book: Book) async throws -> Int {
        guard book.origin == .remote, let online else { return 0 }
        return try await online.downloadAll(for: book)
    }

    public func invalidate(bookId: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: bookId)
    }

    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}

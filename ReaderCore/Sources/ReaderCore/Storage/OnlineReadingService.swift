import Foundation

/// 在线书在阅读器里的取数入口。
///
/// 把「清单在哪、源规则长什么样、正文从哪来」这三件事收在一处：
/// `ChapterProvider` 只负责区分本地 / 在线，阅读器只看章节数组。
public final class OnlineReadingService: @unchecked Sendable {
    private let library: OnlineLibrary
    private let sources: SourceRepository
    private let client: SourceClient

    public init(library: OnlineLibrary, sources: SourceRepository, client: SourceClient) {
        self.library = library
        self.sources = sources
        self.client = client
    }

    // MARK: 清单

    public func manifest(for book: Book) throws -> OnlineManifest {
        try library.loadManifest(book: book)
    }

    /// 章节目录。正文只带已缓存的部分，未缓存的留空，由阅读器按需拉取。
    public func chapters(for book: Book) throws -> [NovelChapter] {
        let manifest = try manifest(for: book)
        return manifest.chapters.enumerated().map { index, chapter in
            NovelChapter(
                title: chapter.name,
                body: library.chapterText(bookId: manifest.bookId, index: index) ?? ""
            )
        }
    }

    // MARK: 正文

    public func body(for book: Book, index: Int, forceRefresh: Bool = false) async throws -> String {
        let manifest = try manifest(for: book)
        guard manifest.chapters.indices.contains(index) else { throw SourceError.emptyContent }
        guard let source = try resolveSource(manifest.sourceId) else {
            throw SourceError.emptyRule("书源已被删除")
        }

        // 没网但有缓存：直接给缓存，别让用户看见错误页。
        if !forceRefresh, let cached = library.chapterText(bookId: manifest.bookId, index: index) {
            return cached
        }

        do {
            let service = OnlineBookService(client: client, library: library)
            return try await service.chapterBody(
                manifest: manifest,
                source: source,
                index: index,
                forceRefresh: forceRefresh
            )
        } catch {
            if let cached = library.chapterText(bookId: manifest.bookId, index: index) {
                return cached
            }
            throw error
        }
    }

    public func cachedBody(for book: Book, index: Int) -> String? {
        guard let manifest = try? manifest(for: book) else { return nil }
        return library.chapterText(bookId: manifest.bookId, index: index)
    }

    public func prefetch(for book: Book, around index: Int) async {
        guard let manifest = try? manifest(for: book),
              let source = try? resolveSource(manifest.sourceId) else { return }
        let service = OnlineBookService(client: client, library: library)
        await service.prefetch(manifest: manifest, source: source, around: index)
    }

    // MARK: 更新

    /// 重新拉目录，返回新增章数。清单已落盘，调用方负责更新 Book.chapterCount。
    public func refreshToc(for book: Book) async throws -> Int {
        let manifest = try manifest(for: book)
        guard let source = try resolveSource(manifest.sourceId) else {
            throw SourceError.emptyRule("书源已被删除")
        }
        let service = OnlineBookService(client: client, library: library)
        let (_, added) = try await service.refreshToc(manifest: manifest, source: source)
        return added
    }

    // MARK: 缓存

    public func cacheUsage(for book: Book) -> OnlineLibrary.CacheUsage {
        library.cacheSize(bookId: book.id)
    }

    public func cachedChapterIndices(for book: Book) -> [Int] {
        guard let manifest = try? manifest(for: book) else { return [] }
        return library.cachedChapterIndices(bookId: book.id, chapterCount: manifest.chapters.count)
    }

    public func clearCache(for book: Book) {
        library.clearCache(bookId: book.id)
    }

    /// 下载整本：逐章拉取，已缓存跳过。返回实际下载章数。
    public func downloadAll(for book: Book,
                            progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Int {
        let manifest = try manifest(for: book)
        guard let source = try resolveSource(manifest.sourceId) else {
            throw SourceError.emptyRule("书源已被删除")
        }
        let service = OnlineBookService(client: client, library: library)
        var downloaded = 0

        for index in manifest.chapters.indices {
            try Task.checkCancellation()
            if library.hasChapter(bookId: manifest.bookId, index: index) {
                progress?(index + 1, manifest.chapters.count)
                continue
            }
            _ = try await service.chapterBody(manifest: manifest, source: source, index: index)
            downloaded += 1
            progress?(index + 1, manifest.chapters.count)
        }
        return downloaded
    }

    // MARK: 内部

    private func resolveSource(_ id: String) throws -> LegadoSource? {
        guard let record = try sources.fetch(id: id) else { return nil }
        return SourceImportService(repo: sources).executable(from: record)
    }
}

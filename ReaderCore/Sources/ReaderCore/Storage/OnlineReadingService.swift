import Foundation

/// 在线书在阅读器里的取数入口。
///
/// 把「清单在哪、源规则长什么样、正文从哪来」这三件事收在一处：
/// `ChapterProvider` 只负责区分本地 / 在线，阅读器只看章节数组。
public final class OnlineReadingService: @unchecked Sendable {
    private let library: OnlineLibrary
    private let sources: SourceRepository
    private let client: SourceClient
    private let venera: VeneraRuntime

    public init(library: OnlineLibrary,
                sources: SourceRepository,
                client: SourceClient,
                venera: VeneraRuntime = VeneraRuntime()) {
        self.library = library
        self.sources = sources
        self.client = client
        self.venera = venera
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
        guard let source = try resolveTarget(manifest.sourceId) else {
            throw SourceError.emptyRule("书源已被删除")
        }

        // 没网但有缓存：直接给缓存，别让用户看见错误页。
        if !forceRefresh, let cached = library.chapterText(bookId: manifest.bookId, index: index) {
            return cached
        }

        do {
            switch source {
            case .legado(let legado):
                let service = OnlineBookService(client: client, library: library, venera: venera)
                return try await service.chapterBody(
                    manifest: manifest,
                    source: legado,
                    index: index,
                    forceRefresh: forceRefresh,
                    purify: false
                )
            case .venera:
                throw VeneraEngineError.unsupported("漫画正文请在漫画阅读页加载图片。")
            }
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
              let target = try? resolveTarget(manifest.sourceId),
              let source = target.legadoSource else { return }
        let service = OnlineBookService(client: client, library: library, venera: venera)
        await service.prefetch(manifest: manifest, source: source, around: index)
    }

    // MARK: 更新

    /// 重新拉目录，返回新增章数。清单已落盘，调用方负责更新 Book.chapterCount。
    public func refreshToc(for book: Book) async throws -> Int {
        let manifest = try manifest(for: book)
        guard let source = try resolveTarget(manifest.sourceId) else {
            throw SourceError.emptyRule("书源已被删除")
        }
        let service = OnlineBookService(client: client, library: library, venera: venera)
        switch source {
        case .legado(let legado):
            let (_, added) = try await service.refreshToc(manifest: manifest, source: legado)
            return added
        case .venera(let script):
            let (_, added) = try await service.refreshTocVenera(
                manifest: manifest, source: script, runtime: venera
            )
            return added
        }
    }

    // MARK: 缓存

    public func cacheUsage(for book: Book) -> OnlineLibrary.CacheUsage {
        library.cacheSize(bookId: book.id)
    }

    /// 已缓存的正文 / 漫画话数。正文缓存目录按 `body.txt` 计数；漫画图片
    /// 存在 `Cache/<bookId>/online/<chapter>/`，只看非空目录，不把空占位算进去。
    public func cachedChapterCount(for book: Book) -> Int {
        guard let manifest = try? manifest(for: book) else { return 0 }
        if book.type == .comic {
            let root = library.paths.cache
                .appendingPathComponent(book.id, isDirectory: true)
                .appendingPathComponent("online", isDirectory: true)
            let directories = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            var count = 0
            for directory in directories {
                guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                if files.contains(where: {
                    (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }) {
                    count += 1
                }
            }
            return min(count, manifest.chapters.count)
        }
        return min(library.cacheSize(bookId: book.id).chapterCount, manifest.chapters.count)
    }

    public func cachedChapterIndices(for book: Book) -> [Int] {
        guard let manifest = try? manifest(for: book) else { return [] }
        return library.cachedChapterIndices(bookId: book.id, chapterCount: manifest.chapters.count)
    }

    public func clearCache(for book: Book) {
        library.clearCache(bookId: book.id)
    }

    /// 从 `start` 开始缓存 `count` 章（包含已缓存的，已缓存的只报进度不重复下载）。
    /// 只用于小说正文；漫画请在漫画阅读页缓存图片。
    @discardableResult
    public func downloadChapters(for book: Book,
                                 from start: Int,
                                 count: Int,
                                 progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Int {
        let manifest = try manifest(for: book)
        guard !manifest.chapters.isEmpty else { return 0 }
        let lower = max(start, 0)
        guard lower < manifest.chapters.count else { return 0 }
        let upper = min(lower + max(count, 1) - 1, manifest.chapters.count - 1)
        let total = upper - lower + 1

        guard let source = try resolveTarget(manifest.sourceId) else {
            throw SourceError.emptyRule("书源已被删除")
        }
        if case .venera = source {
            throw VeneraEngineError.unsupported("漫画请在阅读页里缓存章节。")
        }
        guard let legado = source.legadoSource else {
            throw SourceError.emptyRule("书源已被删除")
        }

        let service = OnlineBookService(client: client, library: library, venera: venera)
        var downloaded = 0
        for (done, index) in (lower...upper).enumerated() {
            try Task.checkCancellation()
            if !library.hasChapter(bookId: manifest.bookId, index: index) {
                _ = try await service.chapterBody(
                    manifest: manifest,
                    source: legado,
                    index: index,
                    purify: false
                )
                downloaded += 1
            }
            progress?(done + 1, total)
        }
        return downloaded
    }

    /// 下载整本：逐章拉取，已缓存跳过。返回实际下载章数。
    public func downloadAll(for book: Book,
                            progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Int {
        let manifest = try manifest(for: book)
        guard let source = try resolveTarget(manifest.sourceId) else {
            throw SourceError.emptyRule("书源已被删除")
        }
        if case .venera = source {
            throw VeneraEngineError.unsupported("漫画请在阅读页里缓存章节。")
        }
        guard let legado = source.legadoSource else {
            throw SourceError.emptyRule("书源已被删除")
        }
        let service = OnlineBookService(client: client, library: library, venera: venera)
        var downloaded = 0

        for index in manifest.chapters.indices {
            try Task.checkCancellation()
            if library.hasChapter(bookId: manifest.bookId, index: index) {
                progress?(index + 1, manifest.chapters.count)
                continue
            }
            _ = try await service.chapterBody(manifest: manifest,
                                              source: legado,
                                              index: index,
                                              purify: false)
            downloaded += 1
            progress?(index + 1, manifest.chapters.count)
        }
        return downloaded
    }

    // MARK: 内部

    public func resolveTarget(_ id: String) throws -> SearchTarget? {
        guard let record = try sources.fetch(id: id) else { return nil }
        return SourceImportService(repo: sources).target(from: record)
    }
}

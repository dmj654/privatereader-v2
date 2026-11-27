import Foundation

/// 准备好的一本在线书：数据库行 + 本地清单。
public struct OnlineBookBundle: Sendable {
    public let book: Book
    public let manifest: OnlineManifest

    public init(book: Book, manifest: OnlineManifest) {
        self.book = book
        self.manifest = manifest
    }
}

/// 在线书的取数：详情、目录、正文。
///
/// 正文策略是「用缓存、缺了才下、下完就存」。不预下载整本——
/// 一本两千章的书全下完要几百 MB，而用户可能只看到第 30 章。
public actor OnlineBookService {
    private let client: SourceClient
    private let venera: VeneraRuntime
    private let library: OnlineLibrary
    private let paths: SandboxPaths?

    public init(client: SourceClient,
                library: OnlineLibrary,
                venera: VeneraRuntime = VeneraRuntime(),
                paths: SandboxPaths? = nil) {
        self.client = client
        self.venera = venera
        self.library = library
        self.paths = paths
    }

    // MARK: 加入书架

    private func downloadCover(urlString: String,
                               baseURL: String?,
                               headers: [String: String],
                               bookID: String) async -> String? {
        guard let paths else { return nil }
        return await OnlineCoverStore.download(
            urlString: urlString,
            baseURL: baseURL,
            headers: headers,
            bookID: bookID,
            paths: paths
        )
    }

    /// 详情页已经取过详情和目录时把结果传进来，避免为了打开阅读器再请求一遍。
    /// 参数保持默认值，老调用点的行为不变。
    public func prepare(_ online: OnlineBook,
                        source: LegadoSource,
                        knownDetail: OnlineBook? = nil,
                        knownChapters: [OnlineChapter]? = nil) async throws -> OnlineBookBundle {
        var detail = knownDetail ?? online
        // 详情页取不到就退回搜索结果里的字段：有目录照样能读。
        if knownDetail == nil,
           let enriched = try? await client.bookInfo(source: source, book: online) {
            detail = enriched
        }
        if detail.coverUrl.isEmpty { detail.coverUrl = online.coverUrl }

        let toc: [OnlineChapter]
        if let knownChapters, !knownChapters.isEmpty {
            toc = knownChapters
        } else {
            toc = try await client.chapters(source: source, book: detail)
        }
        guard !toc.isEmpty else { throw SourceError.emptyRule("目录是空的") }

        let bookId = UUID().uuidString
        let coverPath = await downloadCover(urlString: detail.coverUrl,
                                            baseURL: source.url,
                                            headers: client.imageHeaders(source: source),
                                            bookID: bookId)
        let manifest = OnlineManifest(
            bookId: bookId,
            sourceId: source.id,
            bookUrl: detail.bookUrl,
            tocUrl: detail.bookUrl,
            title: detail.name,
            author: detail.author,
            coverUrl: detail.coverUrl,
            intro: detail.intro,
            kind: detail.kind,
            chapters: toc
        )
        let relativePath = try library.save(manifest)

        let book = Book(
            id: bookId,
            type: source.isComic ? .comic : .novel,
            origin: .remote,
            title: detail.name,
            author: detail.author.isEmpty ? nil : detail.author,
            coverPath: coverPath,
            filePath: relativePath,
            sourceId: source.id,
            sourceBookId: detail.bookUrl,
            sourceUrl: detail.bookUrl,
            chapterCount: toc.count
        )
        return OnlineBookBundle(book: book, manifest: manifest)
    }

    /// 给已在书架的书换源：清单覆盖到同一个书 id 下，进度与书签都不丢。
    /// 只写文件 + 返回更新后的 Book，入库由调用方决定。
    public func switchSource(book: Book,
                             to online: OnlineBook,
                             source: LegadoSource) async throws -> Book {
        var detail = online
        if let enriched = try? await client.bookInfo(source: source, book: online) {
            detail = enriched
        }

        let toc = try await client.chapters(source: source, book: detail)
        guard !toc.isEmpty else { throw SourceError.emptyRule("目录是空的") }

        let manifest = OnlineManifest(
            bookId: book.id,
            sourceId: source.id,
            bookUrl: detail.bookUrl,
            tocUrl: detail.bookUrl,
            title: detail.name,
            author: detail.author,
            coverUrl: detail.coverUrl,
            intro: detail.intro,
            kind: detail.kind,
            chapters: toc
        )
        let relativePath = try library.save(manifest)

        var updated = book
        updated.type = source.isComic ? .comic : .novel
        updated.title = detail.name
        updated.author = detail.author.isEmpty ? nil : detail.author
        updated.filePath = relativePath
        updated.sourceId = source.id
        updated.sourceBookId = detail.bookUrl
        updated.sourceUrl = detail.bookUrl
        updated.chapterCount = toc.count
        updated.newChapterCount = 0
        return updated
    }

    // MARK: Venera 漫画

    public func prepareVenera(_ online: OnlineBook,
                              source: VeneraSource,
                              runtime: VeneraRuntime) async throws -> OnlineBookBundle {
        let detail = try await runtime.detail(source: source, comicId: online.bookUrl)
        guard !detail.chapters.isEmpty else { throw SourceError.emptyRule("目录是空的") }

        let bookId = UUID().uuidString
        let resolvedCover = detail.coverUrl.isEmpty ? online.coverUrl : detail.coverUrl
        let coverPath = await downloadCover(urlString: resolvedCover,
                                            baseURL: nil,
                                            headers: runtime.imageHeaders,
                                            bookID: bookId)
        let manifest = OnlineManifest(
            bookId: bookId,
            sourceId: source.id,
            bookUrl: detail.comicId,
            tocUrl: detail.comicId,
            title: detail.title,
            author: detail.author,
            coverUrl: resolvedCover,
            intro: detail.intro,
            kind: detail.kind,
            chapters: detail.chapters
        )
        let relativePath = try library.save(manifest)
        let book = Book(
            id: bookId,
            type: .comic,
            origin: .remote,
            title: detail.title,
            author: detail.author.isEmpty ? nil : detail.author,
            coverPath: coverPath,
            filePath: relativePath,
            sourceId: source.id,
            sourceBookId: detail.comicId,
            sourceUrl: detail.comicId,
            chapterCount: detail.chapters.count
        )
        return OnlineBookBundle(book: book, manifest: manifest)
    }

    public func switchSourceVenera(book: Book,
                                   to online: OnlineBook,
                                   source: VeneraSource,
                                   runtime: VeneraRuntime) async throws -> Book {
        let detail = try await runtime.detail(source: source, comicId: online.bookUrl)
        guard !detail.chapters.isEmpty else { throw SourceError.emptyRule("目录是空的") }

        let manifest = OnlineManifest(
            bookId: book.id,
            sourceId: source.id,
            bookUrl: detail.comicId,
            tocUrl: detail.comicId,
            title: detail.title,
            author: detail.author,
            coverUrl: detail.coverUrl,
            intro: detail.intro,
            kind: detail.kind,
            chapters: detail.chapters
        )
        let relativePath = try library.save(manifest)

        var updated = book
        updated.type = .comic
        updated.title = detail.title
        updated.author = detail.author.isEmpty ? nil : detail.author
        updated.filePath = relativePath
        updated.sourceId = source.id
        updated.sourceBookId = detail.comicId
        updated.sourceUrl = detail.comicId
        updated.chapterCount = detail.chapters.count
        updated.newChapterCount = 0
        return updated
    }

    public func refreshTocVenera(manifest: OnlineManifest,
                                 source: VeneraSource,
                                 runtime: VeneraRuntime) async throws -> (manifest: OnlineManifest, added: Int) {
        let detail = try await runtime.detail(source: source, comicId: manifest.bookUrl)
        guard !detail.chapters.isEmpty else { throw SourceError.emptyRule("目录是空的") }
        var updated = manifest
        updated.chapters = detail.chapters
        updated.updatedAt = Int(Date().timeIntervalSince1970)
        try library.save(updated)
        return (updated, max(detail.chapters.count - manifest.chapters.count, 0))
    }

    // MARK: 正文

    /// 取一章正文。缓存优先，缺了才请求；请求成功立刻落盘。
    /// - Parameter forceRefresh: 用户手动「重新加载」时传 true，跳过缓存。
    /// - Parameter purify: false 时把未执行源内净化规则的原文落盘，阅读器再按开关净化。
    public func chapterBody(manifest: OnlineManifest,
                            source: LegadoSource,
                            index: Int,
                            forceRefresh: Bool = false,
                            purify: Bool = true) async throws -> String {
        guard manifest.chapters.indices.contains(index) else {
            throw SourceError.emptyContent
        }

        if !forceRefresh, let cached = library.chapterText(bookId: manifest.bookId, index: index) {
            return cached
        }

        let text = try await client.content(source: source,
                                            chapter: manifest.chapters[index],
                                            purify: purify)
        try library.storeChapterText(text, bookId: manifest.bookId, index: index)
        return text
    }

    /// 缓存里有就用，没有就返回 nil。离线模式靠它判断能读哪些章。
    public func cachedBody(manifest: OnlineManifest, index: Int) -> String? {
        library.chapterText(bookId: manifest.bookId, index: index)
    }

    /// 预取相邻章，翻页时不至于空白。失败静默——预取本来就不该影响阅读。
    public func prefetch(manifest: OnlineManifest,
                         source: LegadoSource,
                         around index: Int,
                         radius: Int = 1) async {
        let lower = max(index - radius, 0)
        let upper = min(index + radius, manifest.chapters.count - 1)
        guard lower <= upper else { return }

        for target in lower...upper {
            guard !library.hasChapter(bookId: manifest.bookId, index: target) else { continue }
            _ = try? await chapterBody(manifest: manifest, source: source, index: target)
        }
    }

    // MARK: 更新

    /// 重新拉目录。返回的清单已经落盘；`added` 是新增章数。
    public func refreshToc(manifest: OnlineManifest,
                           source: LegadoSource) async throws -> (manifest: OnlineManifest, added: Int) {
        let book = OnlineBook(
            sourceId: manifest.sourceId,
            name: manifest.title,
            author: manifest.author,
            coverUrl: manifest.coverUrl,
            intro: manifest.intro,
            kind: manifest.kind,
            bookUrl: manifest.bookUrl
        )
        let toc = try await client.chapters(source: source, book: book)
        guard !toc.isEmpty else { throw SourceError.emptyRule("目录是空的") }

        var updated = manifest
        updated.chapters = toc
        updated.updatedAt = Int(Date().timeIntervalSince1970)
        try library.save(updated)

        let added = max(toc.count - manifest.chapters.count, 0)
        return (updated, added)
    }
}

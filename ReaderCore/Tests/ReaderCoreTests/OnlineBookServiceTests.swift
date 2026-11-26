import XCTest
@testable import ReaderCore

final class OnlineBookServiceTests: XCTestCase {
    private var root: URL!
    private var paths: SandboxPaths!
    private var library: OnlineLibrary!
    private var client: SourceClient!
    private var service: OnlineBookService!

    private static let detailHTML = """
    <html><body>
      <div class="book-name">剑来</div>
      <div class="book-author">烽火戏诸侯</div>
      <div id="intro">大千世界，无奇不有。</div>
      <a class="toc-link" href="/book/1/toc">目录</a>
    </body></html>
    """

    private static let tocHTML = """
    <html><body><div id="list"><dl>
      <dd><a href="/c/1">第一章 惊蛰</a></dd>
      <dd><a href="/c/2">第二章 开门</a></dd>
    </dl></div></body></html>
    """

    private static let contentHTML = """
    <html><body><div id="content">第一段文字。<br>第二段文字。</div></body></html>
    """

    private static let source = LegadoSource(
        id: "s1",
        name: "测试源",
        url: "https://example.com",
        searchUrl: "https://example.com/search?q={{key}}",
        ruleSearch: SearchRule(bookList: ".book", name: ".name@text", bookUrl: ".name@href"),
        ruleBookInfo: BookInfoRule(
            name: ".book-name@text",
            author: ".book-author@text",
            intro: "#intro@text",
            tocUrl: ".toc-link@href"
        ),
        ruleToc: TocRule(
            chapterList: "#list dd",
            chapterName: "a@text",
            chapterUrl: "a@href"
        ),
        ruleContent: ContentRule(content: "#content@html")
    )

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnlineBookServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
        try paths.prepare()
        library = OnlineLibrary(paths: paths)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StaticURLProtocol.self]
        client = SourceClient(session: URLSession(configuration: config))
        service = OnlineBookService(client: client, library: library)

        StaticURLProtocol.routes = [
            "/book/1": (200, Data(Self.detailHTML.utf8), "text/html; charset=utf-8"),
            "/book/1/toc": (200, Data(Self.tocHTML.utf8), "text/html; charset=utf-8"),
            "/c/1": (200, Data(Self.contentHTML.utf8), "text/html; charset=utf-8"),
            "/c/2": (200, Data(Self.contentHTML.utf8), "text/html; charset=utf-8")
        ]
    }

    override func tearDownWithError() throws {
        StaticURLProtocol.routes = [:]
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func onlineBook() -> OnlineBook {
        OnlineBook(
            sourceId: "s1",
            name: "剑来",
            author: "烽火戏诸侯",
            bookUrl: "https://example.com/book/1"
        )
    }

    // MARK: 加入书架

    func testPrepareBuildsBookAndManifest() async throws {
        let bundle = try await service.prepare(onlineBook(), source: Self.source)

        XCTAssertEqual(bundle.book.title, "剑来")
        XCTAssertEqual(bundle.book.author, "烽火戏诸侯")
        XCTAssertEqual(bundle.book.origin, .remote)
        XCTAssertEqual(bundle.book.sourceId, "s1")
        XCTAssertEqual(bundle.book.chapterCount, 2)
        XCTAssertEqual(bundle.manifest.chapters.map(\.name), ["第一章 惊蛰", "第二章 开门"])
        XCTAssertEqual(bundle.manifest.chapters[0].url, "https://example.com/c/1",
                       "相对地址要按源站补全")

        let reloaded = try library.loadManifest(book: bundle.book)
        XCTAssertEqual(reloaded.bookUrl, "https://example.com/book/1")
        XCTAssertEqual(reloaded.intro, "大千世界，无奇不有。")
    }

    func testPrepareMarksComicSourceAsComicBook() async throws {
        var source = Self.source
        source.type = 2

        let bundle = try await service.prepare(onlineBook(), source: source)

        XCTAssertEqual(bundle.book.type, .comic)
        XCTAssertEqual(bundle.book.origin, .remote)
    }

    func testSwitchSourceKeepsBookIdAndUpdatesManifest() async throws {
        let bundle = try await service.prepare(onlineBook(), source: Self.source)

        var other = Self.source
        other.id = "https://other.example"
        other.name = "另一个源"

        let updated = try await service.switchSource(book: bundle.book,
                                                     to: onlineBook(),
                                                     source: other)

        XCTAssertEqual(updated.id, bundle.book.id, "换源必须沿用同一个书 id，进度才不丢")
        XCTAssertEqual(updated.sourceId, other.id)
        XCTAssertEqual(updated.chapterCount, bundle.book.chapterCount)

        let manifest = try library.loadManifest(bookId: bundle.book.id)
        XCTAssertEqual(manifest.sourceId, other.id)
    }

    func testPrepareThrowsWhenTocEmpty() async {
        StaticURLProtocol.routes["/book/1/toc"] = (200, Data("<html><body></body></html>".utf8), "text/html")

        do {
            _ = try await service.prepare(onlineBook(), source: Self.source)
            XCTFail("空目录应当报错")
        } catch {
            // 预期
        }
    }

    // MARK: 正文

    func testChapterBodyFetchesThenCaches() async throws {
        let bundle = try await service.prepare(onlineBook(), source: Self.source)

        let first = try await service.chapterBody(
            manifest: bundle.manifest, source: Self.source, index: 0
        )
        XCTAssertTrue(first.contains("第一段文字"))
        XCTAssertTrue(first.contains("第二段文字"))
        XCTAssertEqual(library.chapterText(bookId: bundle.book.id, index: 0), first)

        // 断网后再读同一章：必须还能读到
        StaticURLProtocol.routes = [:]
        let second = try await service.chapterBody(
            manifest: bundle.manifest, source: Self.source, index: 0
        )
        XCTAssertEqual(second, first)
    }

    func testForceRefreshSkipsCacheAndFailsWhenOffline() async throws {
        let bundle = try await service.prepare(onlineBook(), source: Self.source)
        _ = try await service.chapterBody(manifest: bundle.manifest, source: Self.source, index: 0)

        StaticURLProtocol.routes = [:]
        do {
            _ = try await service.chapterBody(
                manifest: bundle.manifest, source: Self.source, index: 0, forceRefresh: true
            )
            XCTFail("强制刷新在断网时应当失败")
        } catch {
            XCTAssertNotNil(library.chapterText(bookId: bundle.book.id, index: 0),
                            "刷新失败不能把已有缓存清掉")
        }
    }

    func testPrefetchFillsNeighboursOnly() async throws {
        let bundle = try await service.prepare(onlineBook(), source: Self.source)

        await service.prefetch(manifest: bundle.manifest, source: Self.source, around: 1, radius: 1)

        XCTAssertTrue(library.hasChapter(bookId: bundle.book.id, index: 0))
        XCTAssertTrue(library.hasChapter(bookId: bundle.book.id, index: 1),
                      "当前章也要下，否则打开就是空白")
        XCTAssertFalse(library.hasChapter(bookId: bundle.book.id, index: 2))
    }

    func testCachedBodyDoesNotTouchNetwork() async throws {
        let bundle = try await service.prepare(onlineBook(), source: Self.source)
        try library.storeChapterText("本地已有", bookId: bundle.book.id, index: 1)

        let cached = await service.cachedBody(manifest: bundle.manifest, index: 1)
        let missing = await service.cachedBody(manifest: bundle.manifest, index: 0)
        XCTAssertEqual(cached, "本地已有")
        XCTAssertNil(missing)
    }

    // MARK: 更新

    func testRefreshTocReportsAddedChapters() async throws {
        let bundle = try await service.prepare(onlineBook(), source: Self.source)

        StaticURLProtocol.routes["/book/1/toc"] = (200, Data("""
        <html><body><div id="list"><dl>
          <dd><a href="/c/1">第一章 惊蛰</a></dd>
          <dd><a href="/c/2">第二章 开门</a></dd>
          <dd><a href="/c/3">第三章 新章</a></dd>
        </dl></div></body></html>
        """.utf8), "text/html")

        let (updated, added) = try await service.refreshToc(
            manifest: bundle.manifest, source: Self.source
        )

        XCTAssertEqual(added, 1)
        XCTAssertEqual(updated.chapters.count, 3)
        XCTAssertEqual(try library.loadManifest(bookId: bundle.book.id).chapters.count, 3,
                       "刷新后的目录要落盘，下次打开才算数")
    }
}

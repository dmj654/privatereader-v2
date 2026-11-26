import XCTest
import GRDB
@testable import ReaderCore

final class OnlineReadingServiceTests: XCTestCase {
    private var root: URL!
    private var paths: SandboxPaths!
    private var library: OnlineLibrary!
    private var database: AppDatabase!
    private var sources: SourceRepository!
    private var service: OnlineReadingService!

    private static let sourceJSON = """
    {
      "bookSourceName": "本地测试源",
      "bookSourceUrl": "https://example.com",
      "bookSourceType": 0,
      "searchUrl": "https://example.com/search?q={{key}}",
      "ruleSearch": {"bookList": ".book", "name": ".name@text", "bookUrl": ".name@href"},
      "ruleBookInfo": {"name": ".book-name@text", "tocUrl": ".toc-link@href"},
      "ruleToc": {"chapterList": "#list dd", "chapterName": "a@text", "chapterUrl": "a@href"},
      "ruleContent": {"content": "#content@html"}
    }
    """

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnlineReadingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
        try paths.prepare()
        library = OnlineLibrary(paths: paths)

        database = try AppDatabase.inMemory()
        sources = SourceRepository(db: database.writer)
        _ = try SourceImportService(repo: sources).importJSON(Self.sourceJSON)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StaticURLProtocol.self]
        let client = SourceClient(session: URLSession(configuration: config))
        service = OnlineReadingService(library: library, sources: sources, client: client)

        StaticURLProtocol.routes = [
            "/book/1": (200, Data("<a class=\"toc-link\" href=\"/book/1/toc\">目录</a>".utf8), "text/html"),
            "/c/0": (200, Data("<div id=\"content\">第零章正文</div>".utf8), "text/html"),
            "/c/1": (200, Data("<div id=\"content\">第一章正文</div>".utf8), "text/html"),
            "/c/2": (200, Data("<div id=\"content\">第二章正文</div>".utf8), "text/html"),
            "/book/1/toc": (200, Data("""
            <div id="list"><dl>
              <dd><a href="/c/0">第零章</a></dd>
              <dd><a href="/c/1">第一章</a></dd>
              <dd><a href="/c/2">第二章</a></dd>
            </dl></div>
            """.utf8), "text/html")
        ]
    }

    override func tearDownWithError() throws {
        StaticURLProtocol.routes = [:]
        if let root { try? FileManager.default.removeItem(at: root) }
        database = nil
    }

    /// 造一本已在书架里的在线书：清单落盘 + Book 行。
    private func makeOnlineBook() throws -> Book {
        let manifest = OnlineManifest(
            bookId: "online-1",
            sourceId: "https://example.com",
            bookUrl: "https://example.com/book/1",
            title: "在线书",
            chapters: [
                OnlineChapter(name: "第零章", url: "https://example.com/c/0"),
                OnlineChapter(name: "第一章", url: "https://example.com/c/1"),
                OnlineChapter(name: "第二章", url: "https://example.com/c/2")
            ]
        )
        let relative = try library.save(manifest)
        let book = Book(
            id: "online-1",
            type: .novel,
            origin: .remote,
            title: "在线书",
            filePath: relative,
            sourceId: "https://example.com",
            sourceBookId: "https://example.com/book/1",
            chapterCount: 3
        )
        try BookRepository(db: database.writer).insert(book)
        return book
    }

    func testChaptersUseCachedBodiesOnly() throws {
        let book = try makeOnlineBook()
        try library.storeChapterText("已缓存", bookId: book.id, index: 1)

        let chapters = try service.chapters(for: book)

        XCTAssertEqual(chapters.map(\.title), ["第零章", "第一章", "第二章"])
        XCTAssertEqual(chapters[1].body, "已缓存")
        XCTAssertEqual(chapters[0].body, "", "未缓存的章不能凭空有内容")
    }

    func testBodyFetchesUsingSourceFromDatabase() async throws {
        let book = try makeOnlineBook()

        let text = try await service.body(for: book, index: 2)

        XCTAssertEqual(text, "第二章正文")
        XCTAssertEqual(library.chapterText(bookId: book.id, index: 2), "第二章正文")
    }

    func testBodyThrowsWhenSourceDeleted() async throws {
        let book = try makeOnlineBook()
        try sources.delete(id: "https://example.com")

        do {
            _ = try await service.body(for: book, index: 0)
            XCTFail("书源被删后应当明确报错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("书源"),
                          "错误要指向书源，实际：\(error.localizedDescription)")
        }
    }

    func testBodyFallsBackToCacheWhenNetworkFails() async throws {
        let book = try makeOnlineBook()
        try library.storeChapterText("离线也能看", bookId: book.id, index: 1)
        StaticURLProtocol.routes = [:]

        let text = try await service.body(for: book, index: 1)

        XCTAssertEqual(text, "离线也能看")
    }

    func testDownloadAllSkipsCachedChapters() async throws {
        let book = try makeOnlineBook()
        try library.storeChapterText("已有", bookId: book.id, index: 0)

        let downloaded = try await service.downloadAll(for: book)

        XCTAssertEqual(downloaded, 2)
        XCTAssertEqual(library.cachedCount(bookId: book.id), 3)
    }

    func testRefreshTocReturnsAddedCount() async throws {
        let book = try makeOnlineBook()
        StaticURLProtocol.routes["/book/1/toc"] = (200, Data("""
        <div id="list"><dl>
          <dd><a href="/c/0">第零章</a></dd>
          <dd><a href="/c/1">第一章</a></dd>
          <dd><a href="/c/2">第二章</a></dd>
          <dd><a href="/c/3">第三章</a></dd>
        </dl></div>
        """.utf8), "text/html")

        let added = try await service.refreshToc(for: book)

        XCTAssertEqual(added, 1)
        XCTAssertEqual(try service.chapters(for: book).count, 4)
    }

    func testClearCacheRemovesBodies() throws {
        let book = try makeOnlineBook()
        try library.storeChapterText("正文", bookId: book.id, index: 0)

        service.clearCache(for: book)

        XCTAssertNil(service.cachedBody(for: book, index: 0))
        XCTAssertEqual(service.cacheUsage(for: book).chapterCount, 0)
    }
}
